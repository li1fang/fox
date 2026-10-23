"""Draw raw signal timelines with missing spans, visual label windows and click times."""
import json
import sys
from pathlib import Path
from PIL import Image, ImageDraw

report = json.loads(Path(sys.argv[1]).read_text())
target = Path(sys.argv[2])
fields = sys.argv[3:]
if target.exists() or not fields:
    raise SystemExit("Expected new output and signal field names")
active = next(w for w in report["windows"] if w["id"] == "active")
rows = [row for row in report["series"] if active["start"] <= row["seconds"] < active["end"]]
image = Image.new("RGB", (1300, 240*len(fields)+70), "white")
draw = ImageDraw.Draw(image)
draw.text((20, 12), "Raw 10 Hz observations | peach = reviewed peak neighborhood | dashed = post-production click", fill="black")
draw.text((20, 32), "Gaps are not interpolated. Values are not exercise-form scores or repetition predictions.", fill="black")
for index, field in enumerate(fields):
    top, bottom = 80+index*240, 250+index*240
    valid = [r[field] for r in rows if r[field] is not None]
    low, high = (min(valid), max(valid)) if valid else (0, 1)
    margin = max(0.01, (high-low)*0.08)
    low -= margin
    high += margin
    x = lambda t: 80 + 1180*(t-active["start"])/(active["end"]-active["start"])
    y = lambda v: bottom-(v-low)/(high-low)*(bottom-top)
    for peak in report["peaks"]:
        draw.rectangle((x(peak["window"][0]), top, x(peak["window"][1]), bottom), fill="#ffe2c7")
        px = x(peak["clickSeconds"])
        for py in range(top, bottom, 8):
            draw.line((px, py, px, min(bottom, py+4)), fill="#af3249")
        draw.text((x(peak["window"][0])+2, top+3), peak["id"], fill="black")
    draw.text((80, top-20), field, fill="black")
    for level in range(5):
        v = low+(high-low)*level/4
        draw.line((80, y(v), 1260, y(v)), fill="#d5d5d5")
        draw.text((10, y(v)-5), f"{v:.3f}", fill="black")
    previous = None
    for row in rows:
        value = row[field]
        if value is None:
            draw.line((x(row["seconds"]), bottom+3, x(row["seconds"]), bottom+8), fill="#888888")
            previous = None
            continue
        current = (x(row["seconds"]), y(value))
        if previous:
            draw.line([previous, current], fill="#126c92", width=2)
        previous = current
    for i in range(9):
        t = active["start"]+(active["end"]-active["start"])*i/8
        draw.text((x(t)-10, bottom+12), f"{t:.1f}s", fill="black")
image.save(target)
print(target)
