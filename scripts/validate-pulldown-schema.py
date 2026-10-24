"""Check native-generated M3 contracts and reject fabricated phase fields."""
import copy
import json
import sys
from pathlib import Path
from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource

assert "date-time" in FormatChecker.checkers, "Install scripts/journal-schema-requirements.txt; date-time validation must not be silently skipped"

root = Path(__file__).resolve().parent.parent
names = ["vision-trial", "pose-counter-configuration", "pose-runtime-policy", "pose-session-settings", "workout-visual-evidence"]
schemas = {name: json.loads((root / "schemas" / f"{name}.schema.json").read_text()) for name in names}
for schema in schemas.values():
    Draft202012Validator.check_schema(schema)
registry = Registry().with_resources((s["$id"], Resource.from_contents(s)) for s in schemas.values())
validators = {name: Draft202012Validator(schema, registry=registry, format_checker=FormatChecker()) for name, schema in schemas.items()}
folder = Path(sys.argv[1])
trial = json.loads((folder / "pulldown-trial.json").read_text())
workout = json.loads((folder / "pulldown-workout.json").read_text())
validators["vision-trial"].validate(trial)
validators["workout-visual-evidence"].validate(workout)
cases = []
for mutation in ["fake_zero", "fake_eccentric", "missing_basis", "wrong_exercise", "bad_link_type"]:
    value = copy.deepcopy(trial)
    rep = value["repetitions"][1]
    if mutation == "fake_zero":
        rep["lowerSeconds"] = 0
    elif mutation == "fake_eccentric":
        rep["eccentric"] = rep["precedingReturn"]["measurement"]
    elif mutation == "missing_basis":
        del rep["countingBasis"]
    elif mutation == "wrong_exercise":
        value["exercise"] = "curl"
    else:
        rep["precedingReturn"]["repetitionIndex"] = -1
    assert not validators["vision-trial"].is_valid(value), mutation
    cases.append(mutation)
for path in sys.argv[2:]:
    for case in json.loads(Path(path).read_text())["cases"]:
        validators["vision-trial"].validate(case["validatedReport"])
print(json.dumps({"status": "pulldown_schema_pass", "negativeCases": cases, "batchReports": len(sys.argv[2:])}))
