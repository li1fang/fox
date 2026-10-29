import hashlib
import io
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from types import SimpleNamespace

SCRIPTS = Path(__file__).resolve().parents[2] / 'scripts'
sys.path.insert(0, str(SCRIPTS))
import training_store
from training_store import TrainingStore, serve, synthetic_session, synthetic_stream
from archive import Archive


class TrainingStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / 'library'
        self.store = TrainingStore(self.root)
        self.session = synthetic_session('test-capture')
        self.store.create(self.session)

    def ingest(self, kind='controller_6dof', ticks=(0, 1000, 2000, 3000), **changes):
        descriptor, data = synthetic_stream(self.session, kind, ticks)
        descriptor.update(changes)
        return self.store.ingest(descriptor, io.BytesIO(data))

    def rows(self, **kwargs):
        return self.store.timeline(self.session['id'], **kwargs)['samples']

    def test_half_open_capture_time_not_arrival_and_precision(self):
        result = self.ingest()
        self.assertEqual((result['accepted'], result['outside']), (2, 2))
        rows = self.rows()
        self.assertEqual([r['captured_us'] for r in rows], [self.session['start_us'], self.session['start_us'] + 1000000])
        self.assertTrue(all(r['received_us'] > self.session['end_us'] for r in rows))
        self.assertEqual([r['tick'] for r in rows], ['1000', '2000'])
        desc, data = synthetic_stream(self.session, 'resistance', (1000, 2000))
        huge = 18446744073709550000
        desc['clock']['origin_tick'] = str(huge)
        records = [json.loads(line) for line in data.splitlines()]
        for row in records:
            row['tick'] = str(huge + int(row['tick']))
        self.put_rows(desc, records)
        self.assertEqual([r['captured_us'] for r in self.rows() if r['stream_id'] == desc['id']], [self.session['start_us'], self.session['start_us'] + 1000000])

    def put_rows(self, desc, rows, **kwargs):
        data = b''.join(json.dumps(row).encode() + b'\n' for row in rows)
        desc.update(size=len(data), sha256=hashlib.sha256(data).hexdigest())
        return self.store.ingest(desc, io.BytesIO(data), **kwargs)

    def test_ambiguous_boundary_is_not_false_precision(self):
        desc, data = synthetic_stream(self.session, 'resistance', (1000, 1500, 2999))
        desc['clock']['uncertainty_us'] = 2000
        result = self.store.ingest(desc, io.BytesIO(data))
        self.assertEqual((result['accepted'], result['ambiguous']), (1, 2))

    def test_uncertainty_overlap_from_outside_is_ambiguous_not_outside(self):
        desc, data = synthetic_stream(self.session, 'resistance', (999, 3000))
        desc['clock']['uncertainty_us'] = 2000
        result = self.store.ingest(desc, io.BytesIO(data))
        self.assertEqual((result['accepted'], result['ambiguous'], result['outside']), (0, 2, 0))

    def test_committed_retry_needs_no_new_stream_space(self):
        self.ingest()
        with patch('training_store.shutil.disk_usage', return_value=SimpleNamespace(free=1)):
            self.assertEqual(self.ingest()['status'], 'already_present')
            with self.assertRaisesRegex(ValueError, 'disk'):
                self.ingest('resistance')
        self.assertEqual(len(self.rows()), 2)

    def test_idempotency_conflict_and_session_preservation(self):
        first = self.ingest()
        self.assertEqual(self.ingest()['status'], 'already_present')
        with self.assertRaisesRegex(ValueError, 'conflict'):
            self.ingest(source='another-producer')
        with self.assertRaisesRegex(ValueError, 'conflict'):
            self.store.create(dict(self.session, end_us=self.session['end_us'] + 1))
        self.assertEqual(len(self.rows()), first['accepted'])

    def test_invalid_or_interrupted_stream_rolls_back(self):
        desc, data = synthetic_stream(self.session, 'resistance', (1000, 2000))
        for body in (data[:-3], data + b'x', data.replace(b'1000', b'1001', 1)):
            with self.assertRaises(ValueError):
                self.store.ingest(desc, io.BytesIO(body))
            self.assertEqual(self.rows(), [])
        rows = [json.loads(line) for line in data.splitlines()]
        rows[-1]['values']['force_n'] = 'not-a-number'
        with self.assertRaises(ValueError):
            self.put_rows(desc, rows)
        self.assertEqual(self.store.describe(self.session['id'])['streams'], [])
        self.store.ingest(dict(desc, size=len(data), sha256=hashlib.sha256(data).hexdigest()), io.BytesIO(data))
        self.assertEqual(len(self.rows()), 2)

    def test_whitelist_drops_unrelated_values_not_source_time(self):
        desc, data = synthetic_stream(self.session, 'resistance', (1000,))
        rows = [json.loads(data)]
        rows[0]['values']['gps'] = 'private-unrelated-value'
        result = self.put_rows(desc, rows)
        self.assertEqual(result['dropped_fields'], 1)
        self.assertNotIn('gps', self.rows()[0]['values'])
        self.assertNotIn(b'private-unrelated-value', (self.root/'metadata/training.sqlite').read_bytes())
        rows[0]['capture_at'] = 123
        desc['id'] += '-bad'
        with self.assertRaises(ValueError):
            self.put_rows(desc, rows)

    def test_lost_tracking_does_not_inherit_pose(self):
        desc, data = synthetic_stream(self.session, 'controller_6dof', (1000, 2000))
        rows = [json.loads(line) for line in data.splitlines()]
        rows[1]['values'] = {'tracking': 'lost'}
        self.put_rows(desc, rows)
        self.assertEqual(self.rows()[1]['values'], {'tracking': 'lost'})

    def test_clock_reset_unknown_units_and_nan_rejected(self):
        for mutation in ('clock', 'kind', 'nan', 'reset', 'quaternion'):
            desc, data = synthetic_stream(self.session, 'controller_6dof', (1000, 2000))
            rows = [json.loads(line) for line in data.splitlines()]
            if mutation == 'clock': desc['clock']['ticks_per_second'] = 0
            if mutation == 'kind': desc['kind'] = 'gps'
            if mutation == 'nan': rows[-1]['values']['position_m'][0] = float('nan')
            if mutation == 'reset': rows[-1]['tick'] = '0'
            if mutation == 'quaternion': rows[-1]['values']['orientation_xyzw'] = [0, 0, 0, 0]
            with self.assertRaises(ValueError):
                self.put_rows(desc, rows)
            self.assertEqual(self.rows(), [])

    def depth_asset(self, id='depth-frame', data=b'\x01\x00'*4):
        item = dict(schema='fox.archive.item.v1', id=id, record_id=self.session['id'], kind='original', role='depth-frame', source='synthetic', tags=[], note='', sha256=hashlib.sha256(data).hexdigest(), size=len(data), filename='frame.bin', occurred_at=None, derived_from=[])
        Archive(self.root).put(item, io.BytesIO(data))
        return item

    def test_depth_bytes_verified_but_not_stored_in_sqlite(self):
        desc, data = synthetic_stream(self.session, 'depth', (1000,))
        with self.assertRaises(ValueError):
            self.store.ingest(desc, io.BytesIO(data))
        item = self.depth_asset()
        self.store.ingest(desc, io.BytesIO(data))
        self.assertEqual(self.rows()[0]['values']['asset_id'], item['id'])
        Archive(self.root).blob(item).write_bytes(b'corrupt!')
        desc['id'] += '-corrupt'
        with self.assertRaises(ValueError):
            self.store.ingest(desc, io.BytesIO(data))

    def test_stable_pagination_ties_and_evidence_links(self):
        self.ingest()
        self.ingest('resistance')
        page, seen = self.store.timeline(self.session['id'], limit=1), []
        while True:
            seen += page['samples']
            if page['next'] is None: break
            page = self.store.timeline(self.session['id'], limit=1, after=page['next'])
        self.assertEqual(len(seen), 4)
        self.assertEqual(len({(r['stream_id'], r['seq']) for r in seen}), 4)
        self.depth_asset()
        link = dict(id='link-1', session_id=self.session['id'], archive_id='depth-frame', role='reference', offset_us=None)
        self.store.link(link)
        self.store.link(link)
        self.assertEqual(len(self.store.describe(self.session['id'])['links']), 1)
        self.assertIsNone(self.store.describe(self.session['id'])['links'][0]['offset_us'])
        with self.assertRaises(ValueError): self.store.link(dict(link, archive_id='missing'))

    def test_reserve_only_creates_draft_not_database_session(self):
        first = self.store.reserve('next-capture')
        marker = Path(first['directory'])/'controller_6dof'/'original.bin'
        marker.write_bytes(b'original')
        self.store.reserve('next-capture')
        self.assertEqual(marker.read_bytes(), b'original')
        self.assertEqual(self.store.sessions(), [self.session])
        with self.assertRaises(ValueError): self.store.reserve('../outside')
        draft = json.loads((Path(first['directory'])/'capture-draft.json').read_text())
        with self.assertRaises(ValueError): self.store.create(draft)

    def test_unknown_database_and_symlink_fail_closed(self):
        with sqlite3.connect(self.root/'metadata/training.sqlite') as db:
            db.execute('PRAGMA user_version=99')
        with self.assertRaises(ValueError): self.store.sessions()
        link = Path(self.temp.name)/'alias'
        link.symlink_to(self.root)
        with self.assertRaises(ValueError): TrainingStore(link)

    def test_rpc_roundtrip_is_same_contract(self):
        request = dict(action='describe', id=self.session['id'])
        result = subprocess.run([sys.executable, str(SCRIPTS/'training_store.py'), 'serve', str(self.root)], input=json.dumps(request).encode()+b'\n', capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(json.loads(result.stdout)['session'], self.session)

    def test_killed_import_rolls_back_and_retry_succeeds(self):
        desc, data = synthetic_stream(self.session, 'resistance', (1000, 2000))
        p = subprocess.Popen([sys.executable, str(SCRIPTS/'training_store.py'), 'serve', str(self.root)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            p.stdin.write(json.dumps(dict(action='ingest', descriptor=desc)).encode()+b'\n'+data.splitlines(keepends=True)[0])
            p.stdin.flush()
            deadline = time.monotonic() + 5
            while not (self.root/'metadata/training.sqlite-journal').exists() and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertTrue((self.root/'metadata/training.sqlite-journal').exists(), 'Must kill a real open transaction')
        finally:
            p.kill()
            p.communicate()
        self.assertEqual(self.rows(), [])
        self.assertEqual(self.store.describe(self.session['id'])['streams'], [])
        self.store.ingest(desc, io.BytesIO(data))
        self.assertEqual(len(self.rows()), 2)

    def test_low_space_and_wrong_depth_dimensions_never_publish(self):
        with patch('training_store.shutil.disk_usage', return_value=SimpleNamespace(free=1)):
            with self.assertRaisesRegex(ValueError, 'disk'):
                self.ingest()
        self.depth_asset(data=b'\x00\x00')
        with self.assertRaisesRegex(ValueError, 'dimensions'):
            self.ingest('depth')
        self.assertEqual(self.rows(), [])

    def test_adjacent_windows_and_same_bytes_keep_distinct_capture_identity(self):
        self.ingest()
        second = dict(self.session, id='next-capture', start_us=self.session['end_us'], end_us=self.session['end_us']+1000000)
        self.store.create(second)
        desc, data = synthetic_stream(second, 'resistance')
        self.store.ingest(desc, io.BytesIO(data))
        self.assertEqual(len(self.store.timeline(second['id'])['samples']), 1)
        self.assertEqual(self.store.timeline(second['id'])['samples'][0]['captured_us'], self.session['end_us'])
        self.assertEqual(len(self.rows()), 2)

    def test_paging_detects_late_stream_and_demands_restart(self):
        self.ingest()
        page = self.store.timeline(self.session['id'], limit=1)
        self.ingest('resistance')
        with self.assertRaisesRegex(ValueError, 'changed'):
            self.store.timeline(self.session['id'], after=page['next'])

    def test_stream_reopen_and_schema_shape_match_examples(self):
        self.ingest()
        self.assertEqual(TrainingStore(self.root).timeline(self.session['id']), self.store.timeline(self.session['id']))
        schema = json.loads((SCRIPTS.parent/'schemas/training-sensor.schema.json').read_text())['$defs']
        desc, data = synthetic_stream(self.session, 'controller_6dof')
        for definition, value in [('capture', self.session), ('stream', desc), ('sample', json.loads(data.splitlines()[0]))]:
            self.assertEqual(set(schema[definition]['required']), set(value))
        for changes in (dict(start_us=True), dict(end_us=self.session['start_us']), dict(data_class='unknown'), dict(schema='draft')):
            with self.assertRaises(ValueError): self.store.create(dict(self.session, **changes))

    def test_smoke_drives_all_three_streams_and_verified_asset_readback(self):
        self.depth_asset(id='existing-original')
        archive_reads, damage = 0, None
        def transport(config, req, source=None, output=None):
            nonlocal archive_reads
            if config['kind'] == 'archive':
                if req['action'] == 'put': return self.store.archive.put(req['item'], source)
                if req['action'] == 'list':
                    archive_reads += 1
                    items = self.store.archive.query(req)
                    if archive_reads % 2 == 0 and damage:
                        if damage == 'missing': return [i for i in items if i['id'] != 'existing-original']
                        next(i for i in items if i['id'] == 'existing-original')['note'] = 'changed'
                    return items
                item = self.store.archive.query(req)[0]
                self.assertIsInstance(output.fileno(), int, 'SSH stdout needs a real file descriptor')
                output.write(self.store.archive.checked_blob(item).read_bytes())
                return
            if req['action'] == 'create': return self.store.create(req['session'])
            if req['action'] == 'ingest': return self.store.ingest(req['descriptor'], source)
            if req['action'] == 'link': return self.store.link(req['link'])
            if req['action'] == 'describe': return self.store.describe(req['id'])
            if req['action'] == 'timeline': return self.store.timeline(req['id'])
            self.fail('Unexpected smoke RPC')
        with patch('training_store.remote', side_effect=transport):
            receipt = training_store.smoke({'kind':'training'}, {'kind':'archive'}, 'synthetic-smoke')
        self.assertEqual(receipt['status'], 'synthetic_storage_passed')
        self.assertEqual(receipt['accepted_samples'], 6)
        self.assertTrue(receipt['asset_readback_verified'])
        self.assertFalse(receipt['real_format_verified'])
        self.assertEqual(receipt['prior_archive_items_preserved'], 1)
        for damage in ('missing', 'changed'):
            with patch('training_store.remote', side_effect=transport):
                with self.assertRaisesRegex(ValueError, 'metadata changed'):
                    training_store.smoke({'kind':'training'}, {'kind':'archive'}, 'synthetic-smoke')


if __name__ == '__main__':
    unittest.main()
