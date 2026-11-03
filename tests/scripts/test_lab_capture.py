import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("lab_capture", Path(__file__).resolve().parents[2] / "scripts/lab_capture.py")
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)

class LabCaptureTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve() / "capture"
        self.root.mkdir()
        self.data = b'{"schema":"fox.lab_frame.v1","seq":0,"pts":{"value":"-4","timescale":30},"origin_pts":{"value":"-4","timescale":30},"video_seconds":0.0,"host_received_ns":"1000000000","state":"observed","reason":null}\n'
        (self.root / "frames.jsonl").write_bytes(self.data)
        self.manifest = {"schema":"fox.lab_capture.v1","capture_id":"synthetic-1","host_clock_id":"host-1","mode":"free_capture","action":None,"side":None,"strategy":None,"started_host_ns":"1000000000","ended_host_ns":"2000000000","utc_anchor":None,"streams":[{"id":"camera","kind":"camera_frames","state":"complete","reason":None,"record_schema":"fox.lab_frame.v1","source":{"producer":"synthetic","version":"1","clock_id":"host-1","device_alias":None,"coordinate_system":None,"unit":None}}],"files":[{"path":"frames.jsonl","bytes":len(self.data),"sha256":hashlib.sha256(self.data).hexdigest(),"stream_id":"camera"}]}
        self.write()
    def write(self):
        (self.root / "manifest.json").write_text(json.dumps(self.manifest))
    def control_event(self):
        return dict(schema="fox.pump_control_event.v1", synthetic=True, event_id="event-1", session_id="session-1",
                    host_clock_id="host-1", host_received_ns="500000000", utc="2026-11-03T00:00:00Z",
                    kind="configuration_requested", request_id="request-1", request_devices={"A": "00000000-0000-0000-0000-000000000001", "B": "00000000-0000-0000-0000-000000000002"}, configuration=dict(mode="standard", kg=2, reduction=0), packet_hex="54060201148f")
    def put_control(self, row):
        data=(json.dumps(row)+"\n").encode();(self.root/"frames.jsonl").write_bytes(data)
        self.manifest["streams"][0].update(kind="events",record_schema="fox.pump_control_event.v1")
        self.manifest["files"][0].update(bytes=len(data),sha256=hashlib.sha256(data).hexdigest());self.write()
    def test_control_before_video_is_context_not_a_shifted_motion_sample(self):
        row=self.control_event();self.put_control(row)
        self.assertEqual(lab.verify_package(self.root)["unparsed_streams"],[])
        target=Path(self.tmp.name).resolve()/"control.zip";lab.export_package(self.root,target)
        self.assertEqual(lab.verify_export(target)["unparsed_streams"],[])
        self.assertEqual(json.loads((self.root/"frames.jsonl").read_text())["host_received_ns"],"500000000")
    def test_control_context_rejects_wrong_clock_capture_packet_or_out_of_range_config(self):
        row=self.control_event()
        for change in [dict(host_clock_id="other"),dict(capture_id="other"),dict(packet_hex="00"),dict(configuration=dict(mode="standard",kg=21,reduction=0)),dict(request_devices={}),dict(request_devices={"A": row["request_devices"]["A"], "B": row["request_devices"]["A"]})]:
            with self.subTest(change=change):
                self.put_control(dict(row,**change))
                with self.assertRaises(ValueError):lab.verify_package(self.root)
    def test_shared_native_manifest_rejection_vectors(self):
        base = Path(__file__).resolve().parents[1] / "fixtures/lab-capture"
        valid = json.loads((base / "synthetic-v1/manifest.json").read_text())
        lab.validate_manifest(valid)
        valid["streams"][0]["record_schema"] = "fox.future_raw.v99"
        lab.validate_manifest(valid)
        vectors = json.loads((base / "invalid-manifests.json").read_text())
        for vector in vectors["cases"]:
            with self.subTest(vector=vector["id"]):
                with self.assertRaises(ValueError): lab.validate_manifest(vector["manifest"])
    def test_unknown_action_roundtrip_and_export_never_deletes(self):
        result = lab.verify_package(self.root)
        self.assertEqual(result["capture_id"], "synthetic-1")
        target = Path(self.tmp.name).resolve() / "export.zip"
        lab.export_package(self.root, target)
        self.assertEqual(lab.verify_export(target)["capture_id"], "synthetic-1")
        self.assertEqual((self.root / "frames.jsonl").read_bytes(), self.data)
        with self.assertRaises(ValueError): lab.export_package(self.root, target)
    def test_corrupt_unlisted_and_missing_files_rejected(self):
        for effect in ["corrupt", "extra", "missing"]:
            with self.subTest(effect=effect):
                (self.root / "frames.jsonl").write_bytes(self.data)
                if effect == "corrupt": (self.root / "frames.jsonl").write_bytes(b"bad")
                if effect == "extra": (self.root / "extra").write_text("hidden")
                if effect == "missing": (self.root / "frames.jsonl").unlink()
                with self.assertRaises(ValueError): lab.verify_package(self.root)
                (self.root / "extra").unlink(missing_ok=True)
    def test_traversal_symlink_and_duplicate_identity_rejected(self):
        for path in ["../escape", "/absolute", "a/../frames.jsonl", "a\\b"]:
            self.manifest["files"][0]["path"] = path; self.write()
            with self.assertRaises(ValueError): lab.verify_package(self.root)
        self.manifest["files"][0]["path"] = "frames.jsonl"; self.write()
        (self.root / "frames.jsonl").unlink(); (self.root / "frames.jsonl").symlink_to(Path(self.tmp.name)/"outside")
        with self.assertRaises(ValueError): lab.verify_package(self.root)
        (self.root / "frames.jsonl").unlink(); (self.root / "frames.jsonl").write_bytes(self.data)
        self.manifest["streams"].append(copy.deepcopy(self.manifest["streams"][0])); self.write()
        with self.assertRaises(ValueError): lab.verify_package(self.root)
    def test_failed_3d_does_not_invent_asset_or_fail_other_stream(self):
        stream = copy.deepcopy(self.manifest["streams"][0]); stream.update(id="pose3d",kind="pose3d",state="unavailable",reason="unsupported",record_schema="fox.lab_pose3d.v1")
        self.manifest["streams"].append(stream); self.write()
        self.assertEqual(lab.verify_package(self.root)["stream_states"]["pose3d"], "unavailable")
        stream["reason"] = None; self.write()
        with self.assertRaises(ValueError): lab.verify_package(self.root)
    def test_exact_pts_and_host_clock_are_not_utc(self):
        self.assertEqual(lab.video_seconds({"value":"9007199254740993","timescale":30},{"value":"9007199254740990","timescale":30}), 0.1)
        with self.assertRaises(ValueError): lab.video_seconds({"value":1,"timescale":30},{"value":"0","timescale":30})
        with self.assertRaises(ValueError): lab.video_seconds({"value":"1","timescale":0},{"value":"0","timescale":30})
        self.manifest["ended_host_ns"] = "999"; self.write()
        with self.assertRaises(ValueError): lab.verify_package(self.root)
    def test_row_nonfinite_wrong_time_and_out_of_order_rejected(self):
        row = json.loads(self.data)
        for mutate in [lambda r:r.update(video_seconds=9), lambda r:r.update(video_seconds=float("nan")), lambda r:r.update(host_received_ns="1")]:
            altered=copy.deepcopy(row); mutate(altered)
            data=(json.dumps(altered)+"\n").encode(); (self.root/"frames.jsonl").write_bytes(data)
            self.manifest["files"][0].update(bytes=len(data),sha256=hashlib.sha256(data).hexdigest()); self.write()
            with self.assertRaises(ValueError): lab.verify_package(self.root)
    def test_unknown_schema_and_formal_mode_without_strategy_rejected(self):
        for field,value in [("schema","future"),("mode","exercise_evaluation"),("host_clock_id","another-host")]:
            before=self.manifest[field]; self.manifest[field]=value; self.write()
            with self.assertRaises(ValueError): lab.verify_package(self.root)
            self.manifest[field]=before
    def test_pump_original_bytes_and_host_identity_are_independently_verified(self):
        import sys
        sys.path.insert(0, str(Path(__file__).resolve().parents[2]/"scripts"))
        import pump_telemetry
        event = pump_telemetry.Connection("synthetic-1","pump-A","connection-A","host-1").receive(bytes.fromhex("531503030000000000000000000000000000000092"),"1000000000")
        self.manifest["streams"][0].update(kind="pump_raw",record_schema="fox.lab_pump_events.v1")
        self.manifest["streams"][0]["source"]["device_alias"]="pump-A"
        def put(e):
            data=(json.dumps(e)+"\n").encode(); (self.root/"frames.jsonl").write_bytes(data)
            self.manifest["files"][0].update(bytes=len(data),sha256=hashlib.sha256(data).hexdigest());self.write()
        put(event)
        self.assertEqual(lab.verify_package(self.root)["unparsed_streams"],[])
        for edit in [lambda e:e.update(device_tick="4"), lambda e:e.update(device_alias="pump-B"),lambda e:e["decoded"]["fields"].update(force_n=99),lambda e:e.update(host_clock_id="other")]:
            bad=copy.deepcopy(event);edit(bad);put(bad)
            with self.assertRaises(ValueError):lab.verify_package(self.root)

    def test_stream_chunk_order_is_not_silently_invented(self):
        (self.root/"duplicate.jsonl").write_bytes(self.data)
        other=copy.deepcopy(self.manifest["files"][0]);other["path"]="duplicate.jsonl"
        self.manifest["files"].append(other);self.write()
        with self.assertRaises(ValueError):lab.verify_package(self.root)

    def test_zip_duplicate_and_traversal_entries_rejected(self):
        import zipfile
        import warnings
        for name in ["../escape", "manifest.json"]:
            target=Path(self.tmp.name).resolve()/"bad.zip"
            with zipfile.ZipFile(target,"w") as z:
                z.writestr("manifest.json",json.dumps(self.manifest))
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore",UserWarning)
                    z.writestr(name,b"extra")
            with self.assertRaises(ValueError):lab.verify_export(target)

    def test_opaque_vision3d_rows_keep_source_identity_without_semantic_promotion(self):
        stream = self.manifest["streams"][0]
        stream.update(kind="pose3d",record_schema="fox.pose3d_frame.v1")
        stream["source"].update(source_id="camera-source-1",coordinate_system="apple_vision_root_relative",unit="meters")
        row={"schema":"fox.pose3d_frame.v1","algorithm":"apple_vision_body_pose_3d", "context":{"streamID":"camera-source-1","segmentID":"segment-1","frameIndex":0,"pts":{"value":"9007199254740993","timescale":30,"epoch":"0"},"width":720,"height":1280,"orientation":1,"sourceMirrored":False},"requestedRevision":1,"actualRevision":1,"outcome":"noObservation","inferenceNanoseconds":4}
        raw=(json.dumps(row)+"\n").encode();(self.root/"frames.jsonl").write_bytes(raw)
        self.manifest["files"][0].update(bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest());self.write()
        result=lab.verify_package(self.root)
        self.assertEqual(result["unparsed_streams"],["camera"])
        self.assertFalse(result["formal_training_imported"])
        self.assertEqual((self.root/"frames.jsonl").read_bytes(),raw)

    def test_pts_epoch_is_preserved_and_cannot_normalize_across_epochs(self):
        a={"value":"9007199254740993","timescale":30,"epoch":"7"}
        b={"value":"9007199254740990","timescale":30,"epoch":"7"}
        self.assertEqual(lab.video_seconds(a,b),0.1)
        for epoch in ["8",None]:
            other=dict(b)
            if epoch is None:other.pop("epoch")
            else:other["epoch"]=epoch
            with self.assertRaises(ValueError):lab.video_seconds(a,other)

    def test_lexical_parent_alias_cannot_export_into_source_or_change_it(self):
        helper=self.root.parent/"helper"; helper.mkdir()
        alias=helper/".."/self.root.name
        linked=self.root.parent/"linked-capture";linked.symlink_to(self.root,target_is_directory=True)
        exports=self.root.parent/"exports";exports.mkdir()
        linked_exports=self.root.parent/"linked-exports";linked_exports.symlink_to(exports,target_is_directory=True)
        before={p.relative_to(self.root).as_posix():p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        for source,target in [(alias,self.root/"out.zip"),(self.root,helper/".."/self.root.name/"out.zip"),(linked,exports/"out.zip"),(self.root,linked_exports/"out.zip")]:
            with self.subTest(source=str(source),target=str(target)):
                try:
                    with self.assertRaises(ValueError):lab.export_package(source,target)
                    self.assertEqual({p.relative_to(self.root).as_posix():p.read_bytes() for p in self.root.rglob("*") if p.is_file()},before)
                    self.assertFalse((exports/"out.zip").exists())
                finally:
                    # Preserve the failed assertion, then restore only this synthetic fixture.
                    (self.root/"out.zip").unlink(missing_ok=True)

    def test_shared_native_invalid_frame_reason_vectors_are_rejected(self):
        fixture=Path(__file__).resolve().parents[1]/"fixtures/lab-capture/invalid-frame-reasons.json"
        vectors=json.loads(fixture.read_text())
        for vector in vectors["cases"]:
            with self.subTest(case=vector["id"]):
                row=json.loads(self.data);row.update(vector["updates"])
                data=(json.dumps(row)+"\n").encode();(self.root/"frames.jsonl").write_bytes(data)
                self.manifest["files"][0].update(bytes=len(data),sha256=hashlib.sha256(data).hexdigest());self.write()
                with self.assertRaises(ValueError):lab.verify_package(self.root)

    def test_interrupted_export_does_not_publish_destination(self):
        target=Path(self.tmp.name).resolve()/"export.zip"
        original=lab.verify_export
        try:
            lab.verify_export=lambda _: (_ for _ in ()).throw(ValueError("injected export verification failure"))
            with self.assertRaises(ValueError): lab.export_package(self.root,target)
        finally: lab.verify_export=original
        self.assertFalse(target.exists())
        self.assertEqual((self.root/"frames.jsonl").read_bytes(),self.data)

if __name__ == "__main__": unittest.main()
