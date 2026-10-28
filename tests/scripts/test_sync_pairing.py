import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('sync_pairing',Path(__file__).resolve().parents[2]/'scripts/sync_pairing.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class PairingTests(unittest.TestCase):
    def test_descriptor_binds_invitation_to_vault_endpoint_and_certificate(self):
        cert=b'synthetic certificate'
        network=dict(endpoint='https://example.test:8443/v1/rpc',vault='vault',certificate_sha256=hashlib.sha256(cert).hexdigest())
        value=module.descriptor(network,cert,dict(vault='vault',code='once',expires_in=300),now=1000)
        self.assertEqual(value['expiresAt'],1300000)
        self.assertEqual(value['schema'],'fox.pairing.v1')
        for changed in [dict(network,endpoint='http://example.test/v1/rpc'),dict(network,vault='other'),dict(network,certificate_sha256='wrong')]:
            with self.assertRaises(ValueError):module.descriptor(changed,cert,dict(vault='vault',code='once',expires_in=300))

    def test_existing_file_is_never_replaced_or_invite_issued(self):
        with tempfile.TemporaryDirectory() as tmp:
            output=Path(tmp)/'pair.json';output.write_text('original')
            with self.assertRaises(FileExistsError):
                module.write_invitation(output,{}, {},issue=lambda: self.fail('must not issue'))
            self.assertEqual(output.read_text(),'original')

    def test_written_pairing_file_is_private_and_failure_retains_no_secret(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cert=root/'cert';cert.write_bytes(b'cert')
            network=dict(endpoint='https://example.test/v1/rpc',vault='vault',certificate_path=str(cert),certificate_sha256=hashlib.sha256(b'cert').hexdigest())
            out=root/'pair.json'
            module.write_invitation(out,dict(vault='vault'),network,issue=lambda:dict(vault='vault',code='secret',expires_in=300))
            self.assertEqual(out.stat().st_mode&0o777,0o600)
            self.assertEqual(json.loads(out.read_text())['code'],'secret')
            bad=root/'bad.json'
            with self.assertRaises(ValueError):
                module.write_invitation(bad,dict(vault='vault'),network,issue=lambda:dict(vault='wrong',code='secret',expires_in=300))
            self.assertFalse(bad.exists())

if __name__=='__main__':unittest.main()
