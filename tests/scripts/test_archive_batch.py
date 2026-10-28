import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
import json
from unittest.mock import patch
import os

sys.path.insert(0, str(Path(__file__).resolve().parents[2]/'scripts'))
import archive_batch as batch


class BatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def inventory(self):
        return batch.inventory([dict(path=str(self.root/'source'), label='trial', tags=['vision'])])

    def test_duplicates_keep_all_locations_and_groups(self):
        for name in ['a/video.mp4', 'b/video.mp4']:
            path = self.root/'source'/name
            path.parent.mkdir(parents=True)
            path.write_bytes(b'same')
        value = self.inventory()
        self.assertEqual(len(value['objects']), 1)
        self.assertEqual(len(value['objects'][0]['locations']), 2)
        self.assertEqual(len(value['groups']), 2)

    def test_missing_manifest_file_and_hash_mismatch_block_bundle(self):
        source = self.root/'source'
        source.mkdir()
        (source/'video.mp4').write_bytes(b'video')
        (source/'manifest.json').write_text(json.dumps(dict(schema='fox.vision_diagnostic_manifest.v1',
             files=[dict(path='missing.json',sha256='0'*64,bytes=3),dict(path='video.mp4',sha256='0'*64,bytes=5)])))
        value = self.inventory()
        self.assertEqual(len(value['issues']), 2)
        self.assertEqual(len(value['objects']), 0)

    def test_symlink_and_escape_are_not_read(self):
        source = self.root/'source'
        source.mkdir()
        (source/'link').symlink_to('/etc/passwd')
        (source/'manifest.json').write_text(json.dumps(dict(schema='fox.video_corpus.v1',asset='../outside',sha256='0'*64)))
        value = self.inventory()
        self.assertTrue(value['issues'])
        self.assertEqual(value['objects'], [])

    def test_changed_source_rejected_before_upload(self):
        source = self.root/'source'
        source.mkdir()
        (source/'sample').write_bytes(b'first')
        value = self.inventory()
        (source/'sample').write_bytes(b'other')
        with self.assertRaises(ValueError):
            batch.source_for(value['objects'][0])

    def test_missing_root_is_reported_not_empty_success(self):
        value = self.inventory()
        self.assertEqual(len(value['issues']), 1)

    def test_same_label_different_roots_keep_groups(self):
        roots=[]
        for name in ['one','two']:
            p=self.root/name
            p.mkdir()
            (p/'file').write_bytes(b'same')
            roots.append(dict(path=str(p),label='same',tags=[]))
        self.assertEqual(len(batch.inventory(roots)['groups']),2)

    def test_ancestor_symlink_rejected(self):
        (self.root/'real/child').mkdir(parents=True)
        (self.root/'real/child/file').write_bytes(b'private')
        (self.root/'alias').symlink_to(self.root/'real',target_is_directory=True)
        value=batch.inventory([dict(path=str(self.root/'alias/child'),label='alias',tags=[])])
        self.assertTrue(value['issues'])
        self.assertEqual(value['objects'],[])

    def test_walk_errors_are_visible(self):
        (self.root/'source').mkdir()
        def walk(root,followlinks=False,onerror=None):
            if onerror:
                onerror(PermissionError(13,'denied',str(root/'hidden')))
            return iter([])
        with patch.object(batch.os,'walk',side_effect=walk):
            self.assertTrue(self.inventory()['issues'])

    def plan(self):
        source=self.root/'source'
        source.mkdir(exist_ok=True)
        (source/'file').write_bytes(b'keep')
        plan=self.root/'plan.json'
        plan.write_text(json.dumps(self.inventory()))
        return plan,source/'file'

    def test_receipt_cannot_alias_original_or_plan(self):
        for target_kind in ['source','plan','hardlink','symlink']:
            with self.subTest(target=target_kind):
                plan,source=self.plan()
                target=source if target_kind=='source' else plan
                if target_kind in ('hardlink','symlink'):
                    target=self.root/target_kind
                    if target_kind=='hardlink': os.link(source,target)
                    else: target.symlink_to(source)
                before=source.read_bytes(),plan.read_bytes()
                with patch.object(batch.archive,'remote',return_value=[]):
                    with self.assertRaises(ValueError): batch.upload(plan,target,{})
                self.assertEqual((source.read_bytes(),plan.read_bytes()),before)

    def test_published_inventory_is_frozen(self):
        plan,source=self.plan()
        before=plan.read_bytes()
        published=[]
        def remote(config,request,source=None):
            if request['action']=='list':
                plan.write_text(json.dumps(dict(schema='fox.archive.inventory.v1',objects=[],groups=[],issues=[])))
                return []
            if request.get('item',{}).get('role')=='inventory': published.append(source.read())
            return {'verified':True}
        with patch.object(batch.archive,'remote',side_effect=remote):
            batch.upload(plan,self.root/'receipt',{})
        self.assertEqual(published,[before])


if __name__ == '__main__':
    unittest.main()
