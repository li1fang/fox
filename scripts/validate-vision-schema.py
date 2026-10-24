"""Validate Swift-generated R2 fixtures, frozen reports and negative wire cases."""
import copy
import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource

assert "date-time" in FormatChecker.checkers, "Install scripts/journal-schema-requirements.txt; date-time validation must not be silently skipped"

root = Path(__file__).resolve().parent.parent
names = ["vision-trial", "pose-counter-configuration", "pose-runtime-policy", "pose-session-settings", "workout-visual-evidence"]
schemas = [json.loads((root / "schemas" / f"{name}.schema.json").read_text()) for name in names]
for schema in schemas:
    Draft202012Validator.check_schema(schema)
registry = Registry().with_resources((s["$id"], Resource.from_contents(s)) for s in schemas)
validator = Draft202012Validator(schemas[0], registry=registry, format_checker=FormatChecker())
directory = Path(sys.argv[1])
paths = sorted(directory.glob("synthetic-*.json")) + sorted(directory.glob("candidate-*.json"))
assert len(list(directory.glob("synthetic-*.json"))) == 2, "Run Swift tests with FOX_R2_EVIDENCE_DIR first"
reports = [json.loads(path.read_text()) for path in paths]
for path in sys.argv[2:]:
    reports.extend(json.loads(Path(path).read_text())["trials"])
for report in reports:
    validator.validate(report)

measured = json.loads((directory / "synthetic-measured.json").read_text())
negative = []
for mutation in ["missing_phase", "missing_uncertainty", "gap_duration", "bad_grace", "missing_recovery", "unknown_field"]:
    case = copy.deepcopy(measured)
    rep = case["repetitions"][0]
    policy = case["counterDiagnostics"]["runtimePolicy"]
    if mutation == "missing_phase":
        del rep["eccentric"]
    elif mutation == "missing_uncertainty":
        del rep["eccentric"]["onsetUncertaintySeconds"]
    elif mutation == "gap_duration":
        rep["eccentric"]["status"] = "trackingGap"
    elif mutation == "bad_grace":
        policy["curlRecovery"]["wristOnlyGraceSeconds"] = 10
    elif mutation == "missing_recovery":
        del policy["curlRecovery"]
    else:
        rep["eccentric"]["score"] = 100
    assert not validator.is_valid(case), f"Accepted invalid case: {mutation}"
    negative.append(mutation)
reviewed = copy.deepcopy(measured)
reviewed["trialReview"] = {"schema": "fox.trial_review.v1", "recordedAt": "2026-10-23T00:00:00Z",
                          "information": "Available weights", "softwareIssue": "Late prompt", "trainingFeeling": "Tired"}
validator.validate(reviewed)
for mutation in ["empty_review", "empty_category", "long_category", "bad_review_date", "wrong_review_schema", "unrecognized_category"]:
    case = copy.deepcopy(reviewed)
    review = case["trialReview"]
    if mutation == "empty_review":
        for key in ["information", "softwareIssue", "trainingFeeling"]:
            del review[key]
    elif mutation == "empty_category": review["softwareIssue"] = ""
    elif mutation == "long_category": review["softwareIssue"] = "x" * 4001
    elif mutation == "bad_review_date": review["recordedAt"] = "unknown"
    elif mutation == "wrong_review_schema": review["schema"] = "other"
    else: review["diagnosis"] = "Do not convert feedback into diagnosis"
    assert not validator.is_valid(case), f"Accepted invalid case: {mutation}"
    negative.append(mutation)
print(json.dumps({"status": "vision_schema_pass", "reports": len(reports), "negativeCases": negative}))
