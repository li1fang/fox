"""Personal vault sync core and durable reference peer, not the iOS adapter.

RPC uses the existing pinned SSH transport. No listener, native credentials,
original deletion, or implicit conflict resolution is installed by this module.
"""
import contextlib
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import sqlite3
import sys
import tempfile
import time
import uuid

from archive import Archive, identifier, require, header


def encoded(value):
    return json.dumps(value,ensure_ascii=False,sort_keys=True,allow_nan=False)


def hashed(value):
    require(isinstance(value,str) and len(value)<=256,'Invalid credential')
    return hashlib.sha256(value.encode()).hexdigest()


def photo_item(photo):
    require(isinstance(photo,dict),'Invalid photo')
    identifier(photo.get('id'))
    digest=photo.get('sha256');size=photo.get('byteCount')
    require(isinstance(digest,str) and re.fullmatch('[0-9a-f]{64}',digest),'Invalid digest')
    require(type(size) is int and 0<size<=25*1024**2,'Invalid photo size')
    require(photo.get('mimeType') in ('image/jpeg','image/png','image/heic'),'Invalid photo MIME')
    name=photo.get('relativePath')
    require(isinstance(name,str) and 0<len(name)<=512 and '\\' not in name,'Invalid photo path')
    path=PurePosixPath(name)
    require(not path.is_absolute() and '..' not in path.parts and '.'!=name,'Unsafe photo path')
    return dict(schema='fox.archive.item.v1',id='photo-'+digest,record_id='photo-'+digest,
                kind='original',role='sync-photo',source='paired-device',tags=['sync-photo'],note='',
                sha256=digest,size=size,filename=digest+'.bin',occurred_at=None,derived_from=[])


def validate(op):
    require(isinstance(op,dict) and set(op)=={'op_id','record_id','base','deleted','payload'},'Invalid operation')
    for name in ('op_id','record_id'):identifier(op[name])
    require(op['record_id']==op['record_id'].lower(),'Record key must be canonical lowercase')
    if op['base'] is not None:identifier(op['base'])
    require(type(op['deleted']) is bool,'Invalid tombstone')
    # Reserve the maximum accepted credential length, not just the inner payload.
    header(dict(action='push',token='x'*256,operation=op))
    if op['deleted']:
        require(op['payload'] is None,'Tombstone must not replace original content')
        return []
    p=op['payload']
    require(isinstance(p,dict) and p.get('schemaVersion')==1,'Unsupported payload')
    require(isinstance(p.get('id'),str) and p['id'].lower()==op['record_id'].lower(),'Record ID mismatch')
    require(type(p.get('revision')) is int and p['revision']>0,'Invalid source revision')
    require(p.get('note') is None or isinstance(p.get('note'),str),'Invalid note')
    photos=p.get('photos');require(isinstance(photos,list) and len(photos)<=20,'Invalid photos')
    require((p.get('note') or '').strip() or photos,'Empty record')
    for photo in photos:photo_item(photo)
    require(len({p['id'].lower() for p in photos})==len(photos),'Duplicate photo ID')
    return photos


class Database:
    def __init__(self,root,kind):
        self.root=Path(root).absolute()
        require(not any(p.is_symlink() for p in (self.root,*self.root.parents)),'Symlink store')
        self.root.mkdir(parents=True,mode=0o700,exist_ok=True)
        self.path=self.root/'sync.sqlite'
        require(not self.path.is_symlink(),'Symlink database')
        self.kind=kind
        with self.db() as db:
            version=db.execute('PRAGMA user_version').fetchone()[0]
            tables=db.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
            require(version==1 or (version==0 and not tables),'Unknown database')
            if version==1:
                require(('meta',) in tables,'Unrelated database')
                identity=db.execute("SELECT value FROM meta WHERE key='kind'").fetchone()
                require(identity and identity[0]==kind,'Wrong store type')
            db.execute('CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)')
            db.execute('INSERT OR IGNORE INTO meta VALUES(?,?)',('kind',kind))
            require(db.execute("SELECT value FROM meta WHERE key='kind'").fetchone()[0]==kind,'Wrong store type')
            db.execute('PRAGMA user_version=1')

    @contextlib.contextmanager
    def db(self):
        require(not any(Path(str(self.path)+suffix).is_symlink() for suffix in ('','-wal','-shm','-journal')),'Symlink database')
        db=sqlite3.connect(self.path,timeout=20)
        try:
            require(db.execute('PRAGMA user_version').fetchone()[0] in (0,1),'Unknown database version')
            db.execute('PRAGMA synchronous=FULL');db.execute('BEGIN IMMEDIATE')
            yield db
            db.commit()
        except BaseException:
            db.rollback();raise
        finally:db.close()


class Store(Database):
    def __init__(self,root):
        super().__init__(root,'server')
        self.archive=Archive(self.root/'attachments')
        with self.db() as db:
            for sql in (
                'CREATE TABLE IF NOT EXISTS invites(digest TEXT PRIMARY KEY, expires REAL NOT NULL, used INTEGER NOT NULL)',
                'CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY,name TEXT NOT NULL,digest TEXT UNIQUE NOT NULL,revoked INTEGER NOT NULL)',
                'CREATE TABLE IF NOT EXISTS operations(id TEXT PRIMARY KEY,device TEXT NOT NULL,operation TEXT NOT NULL,receipt TEXT NOT NULL)',
                'CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY AUTOINCREMENT,operation TEXT NOT NULL)',
                'CREATE TABLE IF NOT EXISTS heads(id TEXT PRIMARY KEY,operation TEXT NOT NULL)'):
                db.execute(sql)
            db.execute('INSERT OR IGNORE INTO meta VALUES(?,?)',('vault',str(uuid.uuid4())))
            self.vault=db.execute("SELECT value FROM meta WHERE key='vault'").fetchone()[0]

    def invite(self):
        code=secrets.token_urlsafe(32)
        with self.db() as db:db.execute('INSERT INTO invites VALUES(?,?,0)',(hashed(code),time.time()+300))
        return code

    def claim(self,code,name):
        require(isinstance(name,str) and 0<len(name)<=100,'Invalid device name')
        with self.db() as db:
            row=db.execute('SELECT expires,used FROM invites WHERE digest=?',(hashed(code),)).fetchone()
            require(row and row[0]>time.time() and not row[1],'Invalid or expired pairing')
            token=secrets.token_urlsafe(32);device=str(uuid.uuid4())
            db.execute('UPDATE invites SET used=1 WHERE digest=?',(hashed(code),))
            db.execute('INSERT INTO devices VALUES(?,?,?,0)',(device,name,hashed(token)))
        return dict(vault=self.vault,device=device,token=token)

    def revoke(self,device):
        with self.db() as db:
            require(db.execute('SELECT 1 FROM devices WHERE id=?',(device,)).fetchone(),'Unknown device')
            db.execute('UPDATE devices SET revoked=1 WHERE id=?',(device,))

    def auth(self,db,token):
        row=db.execute('SELECT id FROM devices WHERE digest=? AND revoked=0',(hashed(token),)).fetchone()
        require(row,'Unauthorized device');return row[0]

    def push(self,token,op):
        photos=validate(op);wire=encoded(op)
        with self.db() as db:
            device=self.auth(db,token)
            old=db.execute('SELECT device,operation,receipt FROM operations WHERE id=?',(op['op_id'],)).fetchone()
            if old:
                require(old[:2]==(device,wire),'Operation ID conflict')
                return json.loads(old[2])
            for photo in photos:self.archive.checked_blob(photo_item(photo))
            row=db.execute('SELECT operation FROM heads WHERE id=?',(op['record_id'],)).fetchone()
            current=json.loads(row[0]) if row else None
            if op['base']!=(current['op_id'] if current else None):
                receipt=dict(status='conflict',head=current)
            else:
                seq=db.execute('INSERT INTO events(operation) VALUES(?)',(wire,)).lastrowid
                db.execute('INSERT OR REPLACE INTO heads VALUES(?,?)',(op['record_id'],wire))
                receipt=dict(status='accepted',seq=seq,revision=op['op_id'])
            db.execute('INSERT INTO operations VALUES(?,?,?,?)',(op['op_id'],device,wire,encoded(receipt)))
        return receipt

    def events(self,token,cursor,limit=50):
        require(type(cursor) is int and cursor>=0 and type(limit) is int and 1<=limit<=50,'Invalid cursor/page')
        with self.db() as db:
            self.auth(db,token)
            latest=db.execute('SELECT COALESCE(MAX(seq),0) FROM events').fetchone()[0]
            require(cursor<=latest,'Cursor ahead of vault')
            rows=db.execute('SELECT seq,operation FROM events WHERE seq>? ORDER BY seq LIMIT ?',(cursor,limit)).fetchall()
        return dict(vault=self.vault,events=[dict(seq=n,operation=json.loads(op)) for n,op in rows],
                    cursor=rows[-1][0] if rows else cursor,more=bool(rows and rows[-1][0]<latest))

    def call(self,request,source=None,output=None):
        action=request.get('action')
        if action=='claim':return self.claim(request.get('code'),request.get('name'))
        token=request.get('token')
        if action=='push':return self.push(token,request['operation'])
        if action=='pull':return self.events(token,request['cursor'],request.get('limit',50))
        require(action in ('put-photo','get-photo'),'Unknown action')
        item=photo_item(request['photo'])
        # Keep revocation and this bounded blob operation serialized.
        with self.db() as db:
            self.auth(db,token)
            if action=='put-photo':return self.archive.put(item,source)
            path=self.archive.checked_blob(item)
            require(output is not None,'Missing output')
            with path.open('rb') as f:
                while chunk:=f.read(1024**2):output.write(chunk)


class Replica(Database):
    """Executable reference client. Its private store is not the iOS Journal DB."""
    def __init__(self,root,vault,token):
        super().__init__(root,'replica')
        self.vault=vault;self.token=token
        self.archive=Archive(self.root/'attachments')
        with self.db() as db:
            db.execute('INSERT OR IGNORE INTO meta VALUES(?,?)',('vault',vault))
            require(db.execute("SELECT value FROM meta WHERE key='vault'").fetchone()[0]==vault,'Wrong vault')
            db.execute('INSERT OR IGNORE INTO meta VALUES(?,?)',('cursor','0'))
            db.execute('CREATE TABLE IF NOT EXISTS mirror(id TEXT PRIMARY KEY,operation TEXT NOT NULL)')
            db.execute('CREATE TABLE IF NOT EXISTS outbox(id TEXT PRIMARY KEY,operation TEXT NOT NULL,state TEXT NOT NULL,receipt TEXT)')

    def attach(self,photo,source):return self.archive.put(photo_item(photo),source)

    def photo_bytes(self,photo):return self.archive.checked_blob(photo_item(photo)).read_bytes()

    def records(self):
        with self.db() as db:return {id:json.loads(op) for id,op in db.execute('SELECT id,operation FROM mirror')}

    def cursor(self):
        with self.db() as db:return int(db.execute("SELECT value FROM meta WHERE key='cursor'").fetchone()[0])

    def pending(self):
        with self.db() as db:return [json.loads(r[0]) for r in db.execute("SELECT operation FROM outbox WHERE state='pending' ORDER BY rowid")]

    def conflicts(self):
        with self.db() as db:return [dict(operation=json.loads(op),receipt=json.loads(r)) for op,r in db.execute("SELECT operation,receipt FROM outbox WHERE state='conflict'")]

    def enqueue(self,record_id,payload):
        identifier(record_id)
        with self.db() as db:
            pending=[json.loads(r[0]) for r in db.execute("SELECT operation FROM outbox WHERE state='pending'")]
            require(not any(op['record_id']==record_id for op in pending),'Unsent edit exists; preserve it before editing again')
            row=db.execute('SELECT operation FROM mirror WHERE id=?',(record_id,)).fetchone()
            op=dict(op_id=str(uuid.uuid4()),record_id=record_id,base=json.loads(row[0])['op_id'] if row else None,
                    deleted=payload is None,payload=payload)
            for photo in validate(op):self.archive.checked_blob(photo_item(photo))
            db.execute('INSERT INTO outbox VALUES(?,?,?,NULL)',(op['op_id'],encoded(op),'pending'))
        return op

    def pull(self,call,limit=50):
        while True:
            cursor=self.cursor()
            result=call(dict(action='pull',token=self.token,cursor=cursor,limit=limit))
            require(result['vault']==self.vault,'Wrong remote vault')
            events=result['events'];last=cursor
            for event in events:
                require(type(event['seq']) is int and event['seq']==last+1,'Noncontiguous events')
                last=event['seq']
                for photo in validate(event['operation']):
                    item=photo_item(photo)
                    try:self.archive.checked_blob(item)
                    except ValueError:
                        with tempfile.TemporaryFile() as f:
                            call(dict(action='get-photo',token=self.token,photo=photo),output=f)
                            f.seek(0);self.attach(photo,f)
            require(result['cursor']==last and (events or not result['more']),'Invalid page cursor')
            # Cursor and mirror advance together, only after all photo bytes verify.
            with self.db() as db:
                require(int(db.execute("SELECT value FROM meta WHERE key='cursor'").fetchone()[0])==cursor,'Concurrent pull')
                for event in events:
                    op=event['operation']
                    db.execute('INSERT OR REPLACE INTO mirror VALUES(?,?)',(op['record_id'],encoded(op)))
                db.execute("UPDATE meta SET value=? WHERE key='cursor'",(str(last),))
            if not result['more']:return

    def sync(self,call):
        for op in self.pending():
            for photo in validate(op):
                with self.archive.checked_blob(photo_item(photo)).open('rb') as f:
                    call(dict(action='put-photo',token=self.token,photo=photo),source=f)
            receipt=call(dict(action='push',token=self.token,operation=op))
            require(receipt.get('status') in ('accepted','conflict'),'Invalid receipt')
            if receipt['status']=='accepted':require(receipt.get('revision')==op['op_id'],'Wrong acknowledgement')
            with self.db() as db:
                db.execute('UPDATE outbox SET state=?,receipt=? WHERE id=?',
                           (receipt['status'],encoded(receipt),op['op_id']))
        self.pull(call)


def main():
    os.umask(0o077)
    require(len(sys.argv)>=3,'Usage: personal_sync.py init|serve|invite|revoke ROOT [device]')
    action,root=sys.argv[1:3];store=Store(root)
    if action=='init':result=dict(vault=store.vault,initialized=True)
    elif action=='invite':result=dict(vault=store.vault,code=store.invite(),expires_in=300)
    elif action=='revoke':
        require(len(sys.argv)==4,'Device required');store.revoke(sys.argv[3]);result=dict(revoked=True)
    else:
        require(action=='serve','Unknown command')
        line=sys.stdin.buffer.readline(65537)
        require(len(line)<=65536 and line.endswith(b'\n'),'Invalid header')
        request=json.loads(line)
        result=store.call(request,source=sys.stdin.buffer,output=sys.stdout.buffer)
        if request.get('action')=='get-photo':return
    print(encoded(result))


if __name__=='__main__':
    try:main()
    except Exception as error:
        print(str(error),file=sys.stderr);sys.exit(1)
