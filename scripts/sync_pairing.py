"""Issue one short-lived native pairing file over the existing pinned SSH channel."""
import base64
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time
from urllib.parse import urlsplit


def descriptor(network,certificate,invite,now=None):
    url=urlsplit(network['endpoint'])
    if (url.scheme!='https' or not url.hostname or url.username or url.password or url.query or url.fragment
            or url.path!='/v1/rpc' or hashlib.sha256(certificate).hexdigest()!=network['certificate_sha256']
            or invite.get('vault')!=network['vault'] or not isinstance(invite.get('code'),str)
            or not 1<=len(invite['code'])<=256 or invite.get('expires_in')!=300):
        raise ValueError('Invalid pairing identity')
    return dict(schema='fox.pairing.v1',endpoint=network['endpoint'],vault=network['vault'],
                certificate=base64.b64encode(certificate).decode(),code=invite['code'],
                expiresAt=((time.time() if now is None else now)+300)*1000)


def write_invitation(output,admin,network,issue=None):
    output=Path(output)
    # Reserve the destination before consuming an invite. Never replace another file.
    fd=os.open(output,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    try:
        with os.fdopen(fd,'w') as target:
            if admin.get('vault')!=network.get('vault'):raise ValueError('Vault mismatch')
            certificate=Path(network['certificate_path']).read_bytes()
            if issue is None:
                command=shlex.join(['python3',admin['script'],'invite',admin['root']])
                def issue():
                    result=subprocess.run(['ssh','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',admin['host'],command],
                                          capture_output=True,timeout=30,check=True)
                    return json.loads(result.stdout)
            # Validate trust metadata before asking the server for a credential.
            descriptor(network,certificate,dict(vault=network['vault'],code='validation',expires_in=300))
            value=descriptor(network,certificate,issue())
            json.dump(value,target,ensure_ascii=False,indent=2);target.flush();os.fsync(target.fileno())
    except BaseException:
        output.unlink();raise


if __name__=='__main__':
    try:
        if len(sys.argv)!=2:raise ValueError('Expected a new private output path')
        config=Path.home()/'.config/fox'
        write_invitation(sys.argv[1],json.loads((config/'sync.json').read_text()),json.loads((config/'sync-https.json').read_text()))
        print('pairing_file_ready (single use, expires in 5 minutes; share only with the intended device)')
    except Exception:
        print('Pairing file not created; check destination and private connection configuration.',file=sys.stderr);sys.exit(1)
