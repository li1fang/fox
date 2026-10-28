"""Explicit synthetic-only two-peer smoke against a new remote vault directory."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import shlex
import subprocess
import uuid

from archive import remote, require
from personal_sync import Replica


def run(config,out):
    out.mkdir(parents=True,exist_ok=False)
    def admin(*args):
        cmd=shlex.join(['python3',config['script'],*args])
        result=subprocess.run(['ssh','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=8',config['host'],cmd],
                              capture_output=True,timeout=30,check=True)
        return json.loads(result.stdout)
    # Never smoke against a live vault: create an exclusive fresh child root.
    config=dict(config,root=config['root']+'/synthetic-'+str(uuid.uuid4()))
    def call(request,**kwargs):return remote(config,request,**kwargs)
    def peer(name):
        invitation=admin('invite',config['root'])
        pairing=call(dict(action='claim',code=invitation['code'],name=name))
        return Replica(out/name,pairing['vault'],pairing['token']),pairing
    a,pa=peer('synthetic-a');b,pb=peer('synthetic-b')
    data=b'Fox synthetic attachment; not a real photograph'
    photo=dict(id='synthetic-photo',mimeType='image/jpeg',relativePath='attachments/example.jpg',
               byteCount=len(data),sha256=hashlib.sha256(data).hexdigest())
    a.attach(photo,io.BytesIO(data))
    def payload(note,photos=None):
        return dict(schemaVersion=1,id='synthetic-record',revision=1,recordedAt=1,updatedAt=1,
                    timeZoneIdentifier='UTC',note=note,photos=photos or [],labels=[],source={'kind':'manual'})
    a.enqueue('synthetic-record',payload('offline',[photo]))
    a.sync(call);b.sync(call)
    require(a.records()==b.records() and b.photo_bytes(photo)==data,'Initial roundtrip failed')
    a.enqueue('synthetic-record',payload('left',[photo]));b.enqueue('synthetic-record',payload('right',[photo]))
    a.sync(call);b.sync(call)
    require(len(b.conflicts())==1 and b.conflicts()[0]['operation']['payload']['note']=='right','Lost conflict')
    a.enqueue('synthetic-record',None);a.sync(call);b.sync(call)
    require(b.records()['synthetic-record']['deleted'] and b.photo_bytes(photo)==data,'Delete preservation failed')
    b=Replica(out/'synthetic-b',pb['vault'],pb['token']);b.sync(call)
    require(b.records()['synthetic-record']['deleted'] and len(b.conflicts())==1,'Restart failed')
    admin('revoke',config['root'],pb['device'])
    denied=False
    try:b.sync(call)
    except ValueError as e:
        require('Unauthorized device' in str(e),'Unexpected failure after revocation');denied=True
    require(denied,'Revocation failed')
    result=dict(status='synthetic_ssh_sync_passed',root=config['root'],vault=pa['vault'],
                peers=2,attachments_verified=1,events=3,conflicts_retained=1,revoked_denied=True,
                native_devices_used=False,originals_deleted=False,credentials_saved=False)
    (out/'receipt.json').write_text(json.dumps(result,indent=2))
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config',required=True,type=Path)
    parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args()
    print(json.dumps(run(json.loads(args.config.read_text()),args.output),indent=2))
