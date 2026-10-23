import copy
import json
from pathlib import Path
import unittest
from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[2]


class WorkflowSchemaTests(unittest.TestCase):
    def test_all_public_schemas_are_valid(self):
        paths = list((ROOT / "schemas").glob("*.schema.json"))
        self.assertGreater(len(paths), 10)
        for path in paths:
            with self.subTest(schema=path.name):
                Draft202012Validator.check_schema(json.loads(path.read_text()))

    def test_task_contract_rejects_missing_unknown_or_empty_acceptance(self):
        schema = json.loads((ROOT / "schemas/development-task.schema.json").read_text())
        task = json.loads((ROOT / "docs/development/task-contract.example.json").read_text())
        validator = Draft202012Validator(schema)
        validator.validate(task)
        for field in ["outcome", "acceptance", "stopConditions", "humanUnknowns"]:
            value = copy.deepcopy(task)
            del value[field]
            self.assertFalse(validator.is_valid(value), field)
        value = {**task, "acceptance": []}
        self.assertFalse(validator.is_valid(value))
        self.assertFalse(validator.is_valid({**task, "automaticDeviceInstall": True}))


if __name__ == "__main__":
    unittest.main()
