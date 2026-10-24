"""Validate bundled descriptions and optional private run manifests without modifying either."""
import copy
import json
from pathlib import Path
import sys
from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "apps/ipad/FoxTrainingCore/Sources/FoxTrainingCore/Resources"
schemas = [json.loads((ROOT / "schemas" / name).read_text()) for name in
           ["motion-strategy.schema.json", "vision-run.schema.json"]]
for schema in schemas:
    Draft202012Validator.check_schema(schema)
registry = Registry().with_resources((s["$id"], Resource.from_contents(s)) for s in schemas)
validator = Draft202012Validator(schemas[0], registry=registry)
strategies = []
for file in sorted(RESOURCES.glob("motion-strategy-*.json")):
    value = json.loads(file.read_text())
    validator.validate(value)
    parameters = value["parameters"]
    config = json.loads((RESOURCES / parameters["configuration"]).read_text())
    assert parameters["profile"] in config
    assert (RESOURCES / parameters["runtime"]).is_file()
    for test in value["contractTests"]:
        suite, _, method = test.partition("/")
        source = ROOT / "apps/ipad/FoxTrainingCore/Tests/FoxTrainingCoreTests" / (suite + ".swift")
        assert source.is_file(), test
        assert not method or "func " + method + "(" in source.read_text(), test
    strategies.append(value)
assert {s["exercise"] for s in strategies} == {"curl", "lateralRaise", "latPulldown"}
for key, value in [("version", 99), ("schema", "future"), ("threshold", 99)]:
    invalid = copy.deepcopy(strategies[0]); invalid[key] = value
    assert not validator.is_valid(invalid)
invalid = copy.deepcopy(next(s for s in strategies if s["exercise"] == "latPulldown"))
invalid["counting"]["commit"] = "completed_cycle"
assert not validator.is_valid(invalid)
run_validator = Draft202012Validator(schemas[1], registry=registry, format_checker=FormatChecker())
count = 0
for folder in sys.argv[1:]:
    for file in Path(folder).glob("*/run.json"):
        run_validator.validate(json.loads(file.read_text())); count += 1
print(json.dumps({"strategies": len(strategies), "negativeCases": 4, "runs": count}))
