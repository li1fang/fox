import hashlib
import importlib.util
import io
import os
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from types import SimpleNamespace

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/archive.py'
spec = importlib.util.spec_from_file_location('fox_archive', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / 'archive'

    def call(self, request, data=b'', ok=True):
        result = subprocess.run([sys.executable, str(SCRIPT), 'serve', str(self.root)],
                                input=json.dumps(request).encode()+b'\n'+data, capture_output=True)
        self.assertEqual(result.returncode == 0, ok, result.stderr.decode())
        return result.stdout

    def item(self, data=b'original', **changes):
        item = dict(id='asset-1', record_id='record-1', kind='original', role='video',
                    source='test', tags=['curl'], note='', sha256=hashlib.sha256(data).hexdigest(),
                    size=len(data), filename='sample.mov', schema='fox.archive.item.v1',
                    occurred_at=None, derived_from=[])
        item.update(changes)
        return item

    def put(self, data=b'original', **changes):
        return self.call(dict(action='put', item=self.item(data, **changes)), data)

    def test_roundtrip_filters_and_retry(self):
        self.put()
        self.put()
        items = json.loads(self.call(dict(action='list', tag='curl')))
        self.assertEqual(len(items), 1)
        self.assertEqual(self.call(dict(action='get', id='asset-1')), b'original')
        self.assertEqual(json.loads(self.call(dict(action='list', record_id='absent'))), [])
        self.assertEqual(json.loads(self.call(dict(action='verify', id='asset-1')))['verified'], True)

    def test_conflict_preserves_original(self):
        self.put()
        self.call(dict(action='put', item=self.item(note='changed')), b'original', ok=False)
        self.assertEqual(self.call(dict(action='get', id='asset-1')), b'original')

    def test_truncated_wrong_hash_extra_bytes_never_publish(self):
        for data in [b'orig', b'wrong!!!', b'original-extra']:
            self.call(dict(action='put', item=self.item()), data, ok=False)
        self.assertEqual(json.loads(self.call(dict(action='list'))), [])

    def test_path_and_unknown_schema_rejected(self):
        for changes in [dict(id='../escape'), dict(filename='../x'), dict(schema='v2'),
                        dict(kind='guess'), dict(size=-1), dict(extra='ignored')]:
            self.call(dict(action='put', item=self.item(**changes)), b'original', ok=False)

    def test_corruption_is_not_success_or_overwritten(self):
        self.put()
        blob = next((self.root / 'originals').glob('*/*'))
        blob.write_bytes(b'corrupt')
        self.call(dict(action='get', id='asset-1'), ok=False)
        self.call(dict(action='verify', id='asset-1'), ok=False)
        self.call(dict(action='put', item=self.item()), b'original', ok=False)
        self.assertEqual(blob.read_bytes(), b'corrupt')

    def test_same_bytes_keep_distinct_events_and_derived_provenance(self):
        self.put()
        self.put(id='asset-2', record_id='record-2')
        self.put(b'analysis', id='analysis-1', kind='derived', role='ocr', derived_from=['asset-1'])
        self.assertEqual(len(json.loads(self.call(dict(action='list')))), 3)
        self.assertEqual(len(list((self.root / 'originals').glob('*/*'))), 2)
        self.call(dict(action='put', item=self.item(id='bad-derived', kind='derived', derived_from=['missing'])), b'original', ok=False)

    def test_interrupted_process_does_not_publish(self):
        process = subprocess.Popen([sys.executable, str(SCRIPT), 'serve', str(self.root)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        process.stdin.write(json.dumps(dict(action='put', item=self.item())).encode()+b'\nori')
        process.stdin.flush()
        deadline = time.monotonic()+5
        while not list((self.root/'staging').glob('*')) and time.monotonic() < deadline:
            time.sleep(0.01)
        staged = list((self.root/'staging').glob('*'))
        process.kill()
        process.communicate()
        self.assertTrue(staged, 'Must interrupt an actual staged transfer, not process startup')
        self.assertEqual(json.loads(self.call(dict(action='list'))), [])
        self.put()

    def test_symlink_store_rejected(self):
        self.root.mkdir()
        (self.root/'originals').symlink_to(Path(self.temp.name), target_is_directory=True)
        self.call(dict(action='list'), ok=False)

    def test_disk_full_and_publish_failure_leave_no_visible_item(self):
        archive = module.Archive(self.root)
        with patch.object(module.shutil, 'disk_usage', return_value=SimpleNamespace(free=0)):
            with self.assertRaisesRegex(ValueError, 'space'):
                archive.put(self.item(), io.BytesIO(b'original'))
        with patch.object(module.os, 'rename', side_effect=OSError('disk failure')):
            with self.assertRaises(OSError):
                archive.put(self.item(), io.BytesIO(b'original'))
        self.assertEqual(archive.query({}), [])
        self.assertEqual(list((self.root/'staging').iterdir()), [])

    def test_concurrent_identical_uploads_publish_one_entry(self):
        request = json.dumps(dict(action='put', item=self.item())).encode()+b'\noriginal'
        processes = [subprocess.Popen([sys.executable, str(SCRIPT), 'serve', str(self.root)],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(3)]
        for process in processes:
            process.stdin.write(request)
            process.stdin.close()
        for process in processes:
            self.assertEqual(process.wait(timeout=10), 0, process.stderr.read().decode())
            process.stdout.close()
            process.stderr.close()
        self.assertEqual(len(json.loads(self.call(dict(action='list')))), 1)

    def test_unknown_database_version_not_reset(self):
        self.put()
        import sqlite3
        with sqlite3.connect(self.root/'metadata/catalog.sqlite') as db:
            db.execute('PRAGMA user_version=99')
        self.call(dict(action='list'), ok=False)

    def test_client_never_overwrites_existing_destination(self):
        config = Path(self.temp.name)/'client.json'
        config.write_text(json.dumps(dict(host='unused', root='/unused', script='/unused')))
        target = Path(self.temp.name)/'keep'
        target.write_bytes(b'keep')
        result = subprocess.run([sys.executable, str(SCRIPT), '--config', str(config),
                                 'get', 'asset-1', str(target)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'Destination exists', result.stderr)
        self.assertEqual(target.read_bytes(), b'keep')

    def test_low_space_retry_verifies_without_new_staging(self):
        archive = module.Archive(self.root)
        archive.put(self.item(), io.BytesIO(b'original'))
        with patch.object(module.shutil, 'disk_usage', return_value=SimpleNamespace(free=0)):
            result = archive.put(self.item(), io.BytesIO(b'original'))
            self.assertEqual(result['status'], 'already_present')
            with self.assertRaises(ValueError):
                archive.put(self.item(), io.BytesIO(b'wrong!!!'))

    def test_utf8_metadata_budget(self):
        item = self.item(note='字'*8192, source='源'*8192, role='型'*8192)
        with self.assertRaisesRegex(ValueError, 'header'):
            module.validate(item)

    def test_remote_timeout_covers_blocked_stdin(self):
        fake = Path(self.temp.name)/'ssh'
        fake.write_text('#!'+sys.executable+'\nimport time\ntime.sleep(10)\n')
        fake.chmod(0o700)
        before = time.monotonic()
        with patch.dict(os.environ, PATH=str(fake.parent)+os.pathsep+os.environ['PATH']):
            with self.assertRaises((ValueError, BrokenPipeError)):
                module.remote(dict(host='test', script='/test', root='/test', timeout_seconds=0.2),
                              dict(action='put'), source=io.BytesIO(b'x'*8*1024**2))
        self.assertLess(time.monotonic()-before, 3)


    def test_published_object_without_commit_is_recoverable(self):
        import sqlite3
        original_connect = sqlite3.connect
        class FailingCommit(sqlite3.Connection):
            def commit(self):
                if self.in_transaction:
                    raise OSError('injected commit failure')
                super().commit()
        archive = module.Archive(self.root)
        with patch.object(module.sqlite3, 'connect', side_effect=lambda path: original_connect(path, factory=FailingCommit)):
            with self.assertRaises(OSError):
                archive.put(self.item(), io.BytesIO(b'original'))
        self.assertEqual(archive.query({}), [])
        self.assertTrue(archive.blob(self.item()).exists())
        archive.put(self.item(), io.BytesIO(b'original'))
        self.assertEqual(len(archive.query({})), 1)


if __name__ == '__main__':
    unittest.main()
