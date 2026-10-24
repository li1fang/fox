import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
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


class WorkflowPythonRunnerTests(unittest.TestCase):
    def run_fixtures(self, cases):
        with tempfile.TemporaryDirectory(prefix="fox-python-runner-") as directory:
            files = []
            for name, source in cases.items():
                file = Path(directory) / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text(source)
                files.append(str(file))
            return subprocess.run([sys.executable, str(ROOT / "scripts/run-python-tests.py"), *files],
                                  capture_output=True, text=True, timeout=10)

    def test_nested_file_without_package_cannot_hide_a_failure(self):
        result = self.run_fixtures({"test_good.py": "import unittest\nclass Good(unittest.TestCase):\n def test_ok(self): pass\n",
                                   "nested/test_bad.py": "import unittest\nclass Bad(unittest.TestCase):\n def test_bad(self): self.fail('nested failure')\n"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("nested failure", result.stderr)
        self.assertIn("Ran 2 tests", result.stderr)

    def test_empty_file_cannot_borrow_another_files_pass(self):
        result = self.run_fixtures({"test_empty.py": "", "test_good.py": "import unittest\nclass Good(unittest.TestCase):\n def test_ok(self): pass\n"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No tests", result.stderr)

    def test_nested_passing_file_is_actually_executed(self):
        result = self.run_fixtures({"nested/test_good.py": "import unittest\nclass Good(unittest.TestCase):\n def test_ok(self): pass\n"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Ran 1 test", result.stderr)

    def test_expected_failure_is_not_accepted_as_a_pass(self):
        result = self.run_fixtures({"test_expected.py": "import unittest\nclass Expected(unittest.TestCase):\n @unittest.expectedFailure\n def test_expected(self): self.fail('expected')\n"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected failure", result.stderr)


if __name__ == "__main__":
    unittest.main()
