"""Synthetic Python-export -> Native -> Python bridge; used by LabCaptureTests.

This script never executes Swift. The Native test invokes prepare, consumes the
actual exported ZIP contents, writes its Codable outputs, then invokes verify.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import shutil
import zipfile
from lab_capture import export_package, load_json, verify_package, verify_export


def prepare(root):
    root.mkdir(parents=True, exist_ok=False)
    fixture = Path(__file__).resolve().parents[1]/'tests/fixtures/lab-capture/synthetic-v1'
    exported = root/'python-export.zip'
    export_package(fixture, exported)
    verify_export(exported)
    (root/'native-input').mkdir()
    with zipfile.ZipFile(exported) as z:
        # Our own already verified fixed synthetic ZIP; write each file exclusively.
        for name in z.namelist():
            p = root/'native-input'/name; p.parent.mkdir(parents=True,exist_ok=True)
            with p.open('xb') as f:
                f.write(z.read(name))
    print(json.dumps({'status':'python_export_prepared','directory':str(root/'native-input')}))


def verify_native(root):
    native = root/'native-output'
    first = verify_package(native)
    # Test Native-generated JSONL bytes, not only a re-encoded manifest.
    m = load_json((native/'manifest.json').read_bytes())
    streams = [('native-frame.jsonl','camera'),('native-pump.jsonl','pump')]
    expanded = root/'native-wire-package'
    expanded.mkdir(exist_ok=False)
    for f in m['files']:
        shutil.copyfile(native/f['path'],expanded/f['path'])
    for name, stream in streams:
        data = (root/name).read_bytes()
        with (expanded/name).open('xb') as f:
            f.write(data)
        descriptor = copy.deepcopy(next(s for s in m['streams'] if s['id'] == stream))
        descriptor['id'] = 'native-' + stream
        m['streams'].append(descriptor)
        m['files'].append(dict(path=name,stream_id=descriptor['id'],bytes=len(data),sha256=hashlib.sha256(data).hexdigest()))
    (expanded/'manifest.json').write_text(json.dumps(m))
    result = verify_package(expanded)
    assert not result['unparsed_streams']
    assert first['capture_id'] == result['capture_id'] == 'synthetic-golden'
    print(json.dumps({'status':'cross_language_native_wire_verified','capture_id':first['capture_id'],
                      'manifest_sha256':first['manifest_sha256']}))


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['prepare','verify-native']);parser.add_argument('root')
    args=parser.parse_args()
    (prepare if args.action=='prepare' else verify_native)(Path(args.root))
