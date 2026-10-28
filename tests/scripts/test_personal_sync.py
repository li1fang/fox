import hashlib
import io
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2]/'scripts'))
from personal_sync import Store, Replica
from archive import header


def payload(record='record', note='original', photos=None):
    return dict(schemaVersion=1,id=record,revision=1,recordedAt=1,updatedAt=1,
                timeZoneIdentifier='UTC',note=note,photos=photos or [],labels=[],source={'kind':'manual'})


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name).resolve()
        self.server=Store(self.root/'server')
        self.a=self.peer('a');self.b=self.peer('b')

    def peer(self,name):
        pairing=self.server.claim(self.server.invite(),name)
        return Replica(self.root/name,pairing['vault'],pairing['token'])

    def sync(self,peer,call=None): peer.sync(call or self.server.call)

    def photo(self):
        data=b'synthetic-photo'
        p=dict(id='photo',mimeType='image/jpeg',relativePath='attachments/photo.jpg',
               byteCount=len(data),sha256=hashlib.sha256(data).hexdigest())
        self.a.attach(p,io.BytesIO(data));return p,data

    def test_two_offline_peers_restart(self):
        self.a.enqueue('a-record',payload('a-record'))
        self.b.enqueue('b-record',payload('b-record'))
        self.sync(self.a);self.sync(self.b)
        self.a=Replica(self.root/'a',self.a.vault,self.a.token);self.sync(self.a)
        self.assertEqual(self.a.records(),self.b.records());self.assertEqual(len(self.a.records()),2)

    def test_photo_and_history_preserved(self):
        p,data=self.photo();self.a.enqueue('record',payload(photos=[p]));self.sync(self.a);self.sync(self.b)
        self.assertEqual(self.b.photo_bytes(p),data)
        self.a.enqueue('record',payload(note='edited'));self.sync(self.a);self.sync(self.b)
        self.assertEqual(self.b.photo_bytes(p),data)
        self.assertEqual(len(self.server.events(self.a.token,0)['events']),2)

    def test_lost_ack_retry(self):
        self.a.enqueue('record',payload())
        def lost(req,**kw):
            result=self.server.call(req,**kw)
            if req['action']=='push': raise ConnectionError('lost acknowledgement')
            return result
        with self.assertRaises(ConnectionError):self.sync(self.a,lost)
        self.sync(self.a);self.assertEqual(len(self.server.events(self.a.token,0)['events']),1)
        self.assertEqual(self.a.pending(),[])

    def test_concurrent_edits_keep_conflict(self):
        self.a.enqueue('record',payload());self.sync(self.a);self.sync(self.b)
        self.a.enqueue('record',payload(note='left'));self.b.enqueue('record',payload(note='right'))
        self.sync(self.a);self.sync(self.b)
        self.assertEqual(self.b.records()['record']['payload']['note'],'left')
        self.assertEqual(self.b.conflicts()[0]['operation']['payload']['note'],'right')
        self.assertEqual(len(self.server.events(self.a.token,0)['events']),2)

    def test_delete_does_not_resurrect_or_remove_history(self):
        self.a.enqueue('record',payload());self.sync(self.a);self.sync(self.b)
        self.a.enqueue('record',None);self.b.enqueue('record',payload(note='offline'))
        self.sync(self.a);self.sync(self.b)
        self.assertTrue(self.b.records()['record']['deleted']);self.assertEqual(len(self.b.conflicts()),1)
        self.b.enqueue('record',payload(note='explicit restore'));self.sync(self.b)
        self.assertEqual(len(self.server.events(self.b.token,0)['events']),3)

    def test_missing_attachment_no_commit(self):
        p,_=self.photo()
        op=dict(op_id='op',record_id='record',base=None,deleted=False,payload=payload(photos=[p]))
        with self.assertRaises(ValueError):self.server.push(self.a.token,op)
        self.assertEqual(self.server.events(self.a.token,0)['events'],[])

    def test_corrupt_upload_and_download(self):
        p,_=self.photo()
        with self.assertRaises(ValueError):self.server.call(dict(action='put-photo',token=self.a.token,photo=p),source=io.BytesIO(b'bad'))
        self.a.enqueue('record',payload(photos=[p]));self.sync(self.a)
        def corrupt(req,**kw):
            if req['action']=='get-photo':kw['output'].write(b'bad');return None
            return self.server.call(req,**kw)
        with self.assertRaises(ValueError):self.sync(self.b,corrupt)
        self.assertEqual(self.b.cursor(),0);self.assertEqual(self.b.records(),{})
        self.sync(self.b);self.assertEqual(len(self.b.records()),1)

    def test_pairing_once_expired_and_revoked(self):
        code=self.server.invite();claimed=self.server.claim(code,'once')
        with self.assertRaises(ValueError):self.server.claim(code,'again')
        code=self.server.invite()
        with patch('personal_sync.time.time',return_value=10**12):
            with self.assertRaises(ValueError):self.server.claim(code,'late')
        self.server.revoke(claimed['device'])
        with self.assertRaises(ValueError):self.server.events(claimed['token'],0)
        with self.assertRaises(ValueError):self.server.events('wrong',0)

    def test_operation_id_collision(self):
        op=dict(op_id='same',record_id='record',base=None,deleted=False,payload=payload())
        receipt=self.server.push(self.a.token,op)
        self.assertEqual(self.server.push(self.a.token,op),receipt)
        op['payload']['note']='different'
        with self.assertRaises(ValueError):self.server.push(self.a.token,op)

    def test_pending_survives_pull_and_page(self):
        for i in range(4):self.a.enqueue('r'+str(i),payload('r'+str(i)))
        self.sync(self.a);self.b.enqueue('local',payload('local'))
        self.b.pull(self.server.call,limit=1)
        self.assertEqual(len(self.b.pending()),1);self.assertEqual(len(self.b.records()),4)

    def test_unknown_db_and_wrong_vault(self):
        with self.assertRaises(ValueError):Replica(self.root/'a','other',self.a.token)
        with sqlite3.connect(self.root/'server'/'sync.sqlite') as db:db.execute('PRAGMA user_version=999')
        with self.assertRaises(ValueError):Store(self.root/'server')

    def test_bad_payload_path_and_cursor(self):
        p,_=self.photo();p['relativePath']='../secret'
        with self.assertRaises(ValueError):self.a.enqueue('record',payload(photos=[p]))
        with self.assertRaises(ValueError):self.server.events(self.a.token,-1)
        with self.assertRaises(ValueError):self.a.enqueue('different',payload())

    def test_rpc_process_restart_and_interrupted_upload(self):
        script=Path(__file__).resolve().parents[2]/'scripts/personal_sync.py'
        p,_=self.photo()
        req=dict(action='put-photo',token=self.a.token,photo=p)
        process=subprocess.run([sys.executable,str(script),'serve',str(self.root/'server')],
            input=json.dumps(req).encode()+b'\n'+b'cut',capture_output=True)
        self.assertNotEqual(process.returncode,0)
        self.a.enqueue('record',payload(photos=[p]));self.sync(self.a)
        req=dict(action='pull',token=self.b.token,cursor=0)
        process=subprocess.run([sys.executable,str(script),'serve',str(self.root/'server')],
            input=json.dumps(req).encode()+b'\n',capture_output=True)
        self.assertEqual(process.returncode,0,process.stderr)
        self.assertEqual(len(json.loads(process.stdout)['events']),1)

    def test_simultaneous_writers_only_one_head(self):
        script=Path(__file__).resolve().parents[2]/'scripts/personal_sync.py'
        processes=[]
        for peer,note in [(self.a,'a'),(self.b,'b')]:
            op=dict(op_id=note,record_id='record',base=None,deleted=False,payload=payload(note=note))
            process=subprocess.Popen([sys.executable,str(script),'serve',str(self.root/'server')],
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            process.stdin.write(json.dumps(dict(action='push',token=peer.token,operation=op)).encode()+b'\n')
            process.stdin.close();process.stdin=None;processes.append(process)
        results=[]
        for process in processes:
            stdout,stderr=process.communicate(timeout=10)
            self.assertEqual(process.returncode,0,stderr);results.append(json.loads(stdout)['status'])
        self.assertEqual(sorted(results),['accepted','conflict'])

    def test_process_termination_rolls_back_transaction(self):
        code='import sqlite3,os,sys; d=sqlite3.connect(sys.argv[1]); d.execute("BEGIN IMMEDIATE"); d.execute("INSERT INTO heads VALUES(?,?)",("partial","{}")); os._exit(9)'
        result=subprocess.run([sys.executable,'-c',code,str(self.root/'server'/'sync.sqlite')])
        self.assertEqual(result.returncode,9)
        with self.server.db() as db:self.assertEqual(db.execute('SELECT COUNT(*) FROM heads').fetchone()[0],0)
        self.a.enqueue('record',payload());self.sync(self.a)

    def test_reject_case_variant_record_keys(self):
        with self.assertRaises(ValueError):self.a.enqueue('RECORD',payload('RECORD'))

    def test_remote_vault_and_invalid_page_do_not_advance(self):
        self.a.enqueue('record',payload());self.sync(self.a)
        def wrong(req,**kwargs):
            result=self.server.call(req,**kwargs)
            if req['action']=='pull':result['vault']='other'
            return result
        with self.assertRaises(ValueError):self.b.pull(wrong)
        self.assertEqual(self.b.cursor(),0)

    def test_two_devices_cannot_share_operation_identity(self):
        op=dict(op_id='same',record_id='record',base=None,deleted=False,payload=payload())
        self.server.push(self.a.token,op)
        with self.assertRaises(ValueError):self.server.push(self.b.token,op)

    def test_unrelated_version_one_database_not_adopted(self):
        other=self.root/'unrelated';other.mkdir()
        with sqlite3.connect(other/'sync.sqlite') as db:
            db.execute('CREATE TABLE unrelated(value TEXT)');db.execute('PRAGMA user_version=1')
        with self.assertRaises(ValueError):Store(other)
        with sqlite3.connect(other/'sync.sqlite') as db:
            self.assertEqual(db.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall(),[('unrelated',)])

    def test_wire_envelope_limit_before_queue(self):
        op=dict(op_id='x'*36,record_id='record',base=None,deleted=False,payload=payload())
        op['payload']['note']='x'*(65520-len(header(op))+len('original'))
        self.assertLess(len(header(op)),65536)
        with self.assertRaises(ValueError):header(dict(action='push',token=self.a.token,operation=op))
        with self.assertRaises(ValueError):self.a.enqueue('record',op['payload'])
        self.assertEqual(self.a.pending(),[])


if __name__=='__main__':unittest.main()
