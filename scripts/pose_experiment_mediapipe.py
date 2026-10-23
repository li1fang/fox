"""Consume lossless full-frame PNGs; persist only poses and pixel hashes."""

import argparse
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import sys
import time


JOINTS = {
    0: "nose", 11: "leftShoulder", 12: "rightShoulder",
    13: "leftElbow", 14: "rightElbow", 15: "leftWrist", 16: "rightWrist",
    23: "leftHip", 24: "rightHip", 25: "leftKnee", 26: "rightKnee",
    27: "leftAnkle", 28: "rightAnkle",
}


def map_landmarks(values):
    if len(values) != 33:
        raise ValueError("Expected 33 MediaPipe landmarks")
    points = {}
    for index, name in JOINTS.items():
        value = values[index]
        scalars = [value.x, value.y, value.visibility, value.presence]
        if not all(v is not None and math.isfinite(v) for v in scalars):
            continue
        if not all(0 <= v <= 1 for v in scalars):
            continue
        points[name] = dict(joint=name, x=value.x, y=1 - value.y,
                            confidence=min(value.visibility, value.presence))
    for name, parents in [("neck", ("leftShoulder", "rightShoulder")),
                          ("root", ("leftHip", "rightHip"))]:
        if all(p in points for p in parents):
            a, b = (points[p] for p in parents)
            points[name] = dict(joint=name, x=(a["x"] + b["x"]) / 2,
                               y=(a["y"] + b["y"]) / 2,
                               confidence=min(a["confidence"], b["confidence"]))
    return list(points.values())


def main():
    import cv2
    import mediapipe as mp
    import numpy as np

    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    partial = args.output.with_suffix(args.output.suffix + ".partial")
    if args.output.exists() or partial.exists():
        raise ValueError("Output already exists; choose a new path")
    options = mp.tasks.vision.PoseLandmarkerOptions(
        base_options=mp.tasks.BaseOptions(model_asset_path=str(args.model),
                                         delegate=mp.tasks.BaseOptions.Delegate.CPU),
        running_mode=mp.tasks.vision.RunningMode.VIDEO,
        num_poses=4, min_pose_detection_confidence=0.5,
        min_pose_presence_confidence=0.5, min_tracking_confidence=0.5,
        output_segmentation_masks=False)
    header = json.loads(next(sys.stdin))
    if header.get("schema") != "fox.pose_comparison_stream.v1":
        raise ValueError("Wrong input schema")
    header.update(schema="fox.pose_comparison_cache.v1", mediapipeVersion=mp.__version__,
                  modelSHA256=hashlib.sha256(args.model.read_bytes()).hexdigest(),
                  opencvVersion=cv2.__version__, numPoses=4, delegate="CPU",
                  mapping="y=1-y; min(visibility,presence); no metric depth")
    previous_ms = -1
    count = 0
    with partial.open("x", encoding="utf-8") as output, mp.tasks.vision.PoseLandmarker.create_from_options(options) as model:
        output.write(json.dumps(header) + "\n")
        for line in sys.stdin:
            row = json.loads(line)
            encoded = base64.b64decode(row.pop("imagePNG"), validate=True)
            if hashlib.sha256(encoded).hexdigest() != row["imageSHA256"]:
                raise ValueError("Canonical frame digest mismatch")
            bgr = cv2.imdecode(np.frombuffer(encoded, dtype=np.uint8), cv2.IMREAD_COLOR)
            if bgr is None or bgr.shape[:2] != (row["height"], row["width"]):
                raise ValueError("Invalid decoded image dimensions")
            rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
            timestamp = round(row["seconds"] * 1000)
            if timestamp <= previous_ms:
                raise ValueError("Non-monotonic input timestamps")
            previous_ms = timestamp
            start = time.perf_counter()
            result = model.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb), timestamp)
            row["mediapipeMs"] = (time.perf_counter() - start) * 1000
            row["mediapipe"] = [map_landmarks(person) for person in result.pose_landmarks]
            output.write(json.dumps(row, allow_nan=False, separators=(",", ":")) + "\n")
            count += 1
            if count % 200 == 0:
                print(f"MediaPipe frames {count}", file=sys.stderr, flush=True)
        if count < 2:
            raise ValueError("Incomplete frame stream")
        output.flush()
        os.fsync(output.fileno())
    partial.rename(args.output)
    print(f"Completed {count} shared full frames", file=sys.stderr)


if __name__ == "__main__":
    main()
