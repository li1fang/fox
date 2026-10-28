import asyncio
import io
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'scripts'))
from personal_sync import Store
from sync_https import Gateway


class GatewayTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.store=Store(Path(self.temp.name).resolve()/'vault')
        self.app=Gateway(self.store)
        self.pair=self.store.claim(self.store.invite(),'test')

    async def call(self,request=None,body=None,scheme='https',path='/v1/rpc',headers=None):
        events=[];messages=[dict(type='http.request',body=body if body is not None else json.dumps(request).encode()+b'\n',more_body=False)]
        async def receive():return messages.pop(0) if messages else dict(type='http.disconnect')
        async def send(message):events.append(message)
        await self.app(dict(type='http',scheme=scheme,path=path,method='POST',headers=headers or [],client=('127.0.0.1',10)),receive,send)
        return events[0]['status'],b''.join(e.get('body',b'') for e in events[1:])

    async def test_authenticated_pull_and_claim(self):
        status,body=await self.call(dict(action='pull',token=self.pair['token'],cursor=0))
        self.assertEqual(status,200);self.assertEqual(json.loads(body)['vault'],self.pair['vault'])
        code=self.store.invite()
        status,body=await self.call(dict(action='claim',code=code,name='second'))
        self.assertEqual(status,200);self.assertIn('token',json.loads(body))

    async def test_reject_plaintext_and_cross_origin(self):
        self.assertEqual((await self.call({},scheme='http'))[0],400)
        self.assertEqual((await self.call({},headers=[(b'origin',b'https://other.example')]))[0],403)

    async def test_unauthorized_revoked_and_unknown_action(self):
        self.assertEqual((await self.call(dict(action='pull',token='bad',cursor=0)))[0],401)
        self.store.revoke(self.pair['device'])
        self.assertEqual((await self.call(dict(action='pull',token=self.pair['token'],cursor=0)))[0],401)
        self.assertEqual((await self.call(dict(action='invite')))[0],400)

    async def test_size_and_malformed_body(self):
        self.assertEqual((await self.call(body=b'x'*65537))[0],413)
        self.assertEqual((await self.call(body=b'{}'))[0],400)
        self.assertEqual((await self.call(body=b'[]\n'))[0],400)
        self.assertEqual((await self.call(dict(action='pull',token=self.pair['token'],cursor=0),body=json.dumps(dict(action='pull',token=self.pair['token'],cursor=0)).encode()+b'\nextra'))[0],400)

    async def test_claim_rate_limit(self):
        results=[(await self.call(dict(action='claim',code='wrong',name='test')))[0] for _ in range(11)]
        self.assertEqual(results[-1],429)

    async def test_blob_integrity_and_no_error_disclosure(self):
        import hashlib
        data=b'synthetic'
        p=dict(id='p',mimeType='image/jpeg',relativePath='attachments/p.jpg',byteCount=len(data),sha256=hashlib.sha256(data).hexdigest())
        req=dict(action='put-photo',token=self.pair['token'],photo=p)
        status,body=await self.call(body=json.dumps(req).encode()+b'\n'+data)
        self.assertEqual(status,200)
        status,body=await self.call(dict(action='get-photo',token=self.pair['token'],photo=p))
        self.assertEqual(status,200);self.assertEqual(body,data)
        status,body=await self.call(body=json.dumps(req).encode()+b'\n'+b'cut')
        self.assertEqual(status,400);self.assertNotIn(self.pair['token'].encode(),body)
        self.assertNotIn(str(self.store.root).encode(),body)

    async def test_cancel_keeps_worker_files_and_slot_until_done(self):
        entered=threading.Event();release=threading.Event();observed=[]
        original=self.store.call
        def slow(request,source=None,output=None):
            entered.set();release.wait(3)
            observed.append((source.closed,output.closed));output.write(b'ok')
            return original(request,source=source,output=output)
        self.store.call=slow
        task=asyncio.create_task(self.call(dict(action='pull',token=self.pair['token'],cursor=0)))
        try:
            for _ in range(100):
                if entered.is_set():break
                await asyncio.sleep(.01)
            self.assertTrue(entered.is_set());task.cancel();await asyncio.sleep(.02)
            self.assertFalse(task.done());self.assertEqual(self.app.gate._value,7)
        finally:
            release.set()
            try:await task
            except asyncio.CancelledError:pass
        self.assertEqual(observed,[(False,False)]);self.assertEqual(self.app.gate._value,8)


if __name__=='__main__':unittest.main()
