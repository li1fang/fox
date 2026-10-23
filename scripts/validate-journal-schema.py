"""Validate an actual Swift-generated synthetic backup against the public schemas."""
import copy
import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker

assert "date-time" in FormatChecker.checkers, "Install scripts/journal-schema-requirements.txt; date-time validation must not be silently skipped"
from referencing import Registry, Resource


def reject_constant(value):
    raise ValueError(f"Nonfinite JSON number: {value}")


root = Path(__file__).resolve().parent.parent
schemas = [json.loads((root / "schemas" / name).read_text()) for name in
           ("capture-record.schema.json", "journal-backup.schema.json")]
for schema in schemas:
    Draft202012Validator.check_schema(schema)
registry = Registry().with_resources((s["$id"], Resource.from_contents(s)) for s in schemas)
validator = Draft202012Validator(schemas[1], registry=registry, format_checker=FormatChecker())
backup = json.loads(Path(sys.argv[1]).read_text(), parse_constant=reject_constant)
validator.validate(backup)

invalid = []
case = copy.deepcopy(backup)
case["unexpected"] = True
invalid.append(case)
for mutation in ("domain", "empty", "uuid", "audio", "path", "user_provider"):
    case = copy.deepcopy(backup)
    record = case["records"][0]["revisions"][0]
    if mutation == "domain":
        record["domain"] = "medical"
    elif mutation == "empty":
        record["note"], record["photos"] = "  ", []
    elif mutation == "uuid":
        record["id"] = "not-a-uuid"
    elif mutation == "audio":
        case["photos"][0]["mimeType"] = "audio/mpeg"
    elif mutation == "path":
        case["photos"][0]["relativePath"] = "../outside.png"
    elif mutation == "user_provider":
        record["source"]["provider"] = "unexpected"
    invalid.append(case)
for index, case in enumerate(invalid):
    if validator.is_valid(case):
        raise AssertionError(f"Negative schema fixture {index} was accepted")
print(json.dumps({"status": "journal_schema_validation_pass", "records": len(backup["records"]),
                  "revisions": sum(len(r["revisions"]) for r in backup["records"]),
                  "photos": len(backup["photos"]), "negativeCases": len(invalid)}))
