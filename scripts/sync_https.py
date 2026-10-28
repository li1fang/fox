"""Bounded HTTPS adapter for the personal vault. Never exposes admin commands."""
import asyncio
from collections import deque
import json
import os
from pathlib import Path
import tempfile
import time

from personal_sync import Store, photo_item


class Rejected(Exception):
    def __init__(self,status):self.status=status


async def joined_thread(function,*args,**kwargs):
    worker=asyncio.create_task(asyncio.to_thread(function,*args,**kwargs))
    try:return await asyncio.shield(worker)
    except asyncio.CancelledError:
        # Cancelling an await cannot terminate its thread. Keep owners alive.
        while not worker.done():
            try:await asyncio.shield(worker)
            except asyncio.CancelledError:continue
            except Exception:break
        if worker.done() and not worker.cancelled():worker.exception()
        raise


class Gateway:
    def __init__(self,store):
        self.store=store
        self.claims=deque(maxlen=10)
        self.gate=asyncio.Semaphore(8)

    async def __call__(self,scope,receive,send):
        if scope['type']=='lifespan':
            while True:
                message=await receive()
                if message['type']=='lifespan.startup':await send({'type':'lifespan.startup.complete'})
                elif message['type']=='lifespan.shutdown':
                    await send({'type':'lifespan.shutdown.complete'});return
        if scope['type']!='http':return
        try:
            if scope.get('scheme')!='https':raise Rejected(400)
            if scope.get('path')!='/v1/rpc':raise Rejected(404)
            if scope.get('method')!='POST':raise Rejected(405)
            headers=dict(scope.get('headers',[]))
            if b'origin' in headers:raise Rejected(403)
            if b'content-encoding' in headers:raise Rejected(415)
            async with self.gate:
                with tempfile.TemporaryFile() as body,tempfile.TemporaryFile() as output:
                    request=await asyncio.wait_for(self.read(receive,body),timeout=60)
                    body.seek(0)
                    result=await joined_thread(self.store.call,request,source=body,output=output)
                    if request['action']=='get-photo':
                        output.seek(0)
                        await self.start(send,200,b'application/octet-stream')
                        while chunk:=output.read(1024**2):
                            await send(dict(type='http.response.body',body=chunk,more_body=True))
                        await send(dict(type='http.response.body',body=b''));return
            await self.start(send,200,b'application/json')
            await send(dict(type='http.response.body',body=json.dumps(result,allow_nan=False).encode()))
            return
        except Rejected as e:status=e.status
        except (ValueError,KeyError,TypeError,UnicodeError):status=400
        except asyncio.TimeoutError:status=408
        except Exception:status=500
        # Never reflect tokens, record content, filesystem paths, or internal errors.
        await self.start(send,status,b'application/json')
        await send(dict(type='http.response.body',body=json.dumps({'error':'request_failed','status':status}).encode()))

    async def start(self,send,status,content_type):
        await send(dict(type='http.response.start',status=status,headers=[
            (b'content-type',content_type),(b'cache-control',b'no-store'),(b'x-content-type-options',b'nosniff')]))

    async def read(self,receive,body):
        prefix=bytearray();request=None;size=0;maximum=0
        while True:
            message=await asyncio.wait_for(receive(),timeout=10)
            if message['type']!='http.request':raise Rejected(400)
            chunk=message.get('body',b'')
            if request is None:
                prefix.extend(chunk)
                pos=prefix.find(b'\n')
                if pos<0:
                    if len(prefix)>65536:raise Rejected(413)
                    if not message.get('more_body'):raise Rejected(400)
                    continue
                if pos>=65536:raise Rejected(413)
                request=json.loads(bytes(prefix[:pos]))
                if not isinstance(request,dict):raise Rejected(400)
                action=request.get('action')
                if action not in ('claim','push','pull','put-photo','get-photo'):raise Rejected(400)
                if action=='claim':
                    now=time.monotonic()
                    while self.claims and self.claims[0]<now-60:self.claims.popleft()
                    if len(self.claims)>=10:raise Rejected(429)
                    self.claims.append(now)
                else:
                    try:
                        def authenticate():
                            with self.store.db() as db:return self.store.auth(db,request.get('token'))
                        await joined_thread(authenticate)
                    except ValueError:raise Rejected(401)
                if action=='put-photo':maximum=photo_item(request['photo'])['size']
                chunk=bytes(prefix[pos+1:]);prefix.clear()
            size+=len(chunk)
            if size>maximum:raise Rejected(400)
            body.write(chunk)
            if not message.get('more_body'):
                if size!=maximum:raise Rejected(400)
                return request


def app():
    """Uvicorn factory; secrets are file paths/environment, never request logs."""
    os.umask(0o077)
    root=Path(os.environ['FOX_SYNC_ROOT'])
    if not root.is_absolute():raise ValueError('Absolute vault path required')
    return Gateway(Store(root))
