"""Render local diagnostic contact sheets; never changes source videos or labels."""
import argparse
import io
import json
import subprocess
from pathlib import Path
from PIL import Image, ImageDraw

parser = argparse.ArgumentParser()
parser.add_argument("video")
parser.add_argument("output")
parser.add_argument("--times", required=True, help="Comma-separated seconds, one row per time")
parser.add_argument("--offsets", default="-1,-0.5,0,0.5,1")
parser.add_argument("--cache")
parser.add_argument("--title", default="Visual review / candidates, not ground truth")
args = parser.parse_args()
if Path(args.output).exists():
    raise SystemExit("Refusing to overwrite review image")
times = [float(t) for t in args.times.split(",")]
offsets = [float(t) for t in args.offsets.split(",")]
rows = []
if args.cache:
    rows = [json.loads(line) for line in Path(args.cache).read_text().splitlines()][1:]
width, height, label = 320, 180, 24
canvas = Image.new("RGB", (width * len(offsets), 30 + (height + label) * len(times)), "#121717")
draw = ImageDraw.Draw(canvas)
draw.text((10, 9), args.title, fill="white")
links = [("neck", "root")]
for side in ["left", "right"]:
    links += [(side + a, side + b) for a, b in [("Shoulder", "Elbow"), ("Elbow", "Wrist"), ("Shoulder", "Hip"), ("Hip", "Knee"), ("Knee", "Ankle")]]
for r, time in enumerate(times):
    for c, offset in enumerate(offsets):
        requested = max(0, time + offset)
        frame = min(rows, key=lambda row: abs(row["seconds"] - requested)) if rows else None
        seconds = frame["seconds"] if frame else requested
        result = subprocess.run(["ffmpeg", "-v", "error", "-ss", str(seconds), "-i", args.video,
            "-map", "0:v:0", "-frames:v", "1", "-vf", f"scale={width}:{height}", "-f", "image2pipe", "-vcodec", "png", "pipe:1"], check=True, capture_output=True)
        tile = Image.open(io.BytesIO(result.stdout)).convert("RGB")
        td = ImageDraw.Draw(tile)
        if frame:
            for index, person in enumerate(frame["people"]):
                points = {p["joint"]: p for p in person if p["confidence"] >= 0.3}
                xy = lambda p: (p["x"] * width, (1-p["y"]) * height)
                for a, b in links:
                    if a in points and b in points:
                        color = "#35f2e1" if index else ("#59fa64" if a.startswith("left") else "#ffb647")
                        td.line([xy(points[a]), xy(points[b])], fill=color, width=2)
                for point in points.values():
                    x, y = xy(point)
                    td.ellipse((x-2, y-2, x+2, y+2), fill="#ffffff")
        x, y = c * width, 30 + r * (height + label)
        canvas.paste(tile, (x, y))
        draw.text((x+5, y+height+5), f"{seconds:.2f}s" + (f"  people={len(frame['people'])}" if frame else ""), fill="white")
canvas.save(args.output)
print(args.output)
