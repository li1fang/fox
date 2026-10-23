"""Run every classified Python file, including directories without __init__.py."""
import importlib.util
from pathlib import Path
import sys
import unittest


def load_suite(files):
    if not files or len(set(files)) != len(files):
        raise ValueError("Missing or duplicate Python test files")
    suite = unittest.TestSuite()
    for index, filename in enumerate(files):
        file = Path(filename).resolve(strict=True)
        spec = importlib.util.spec_from_file_location(f"fox_classified_test_{index}", file)
        if spec is None or spec.loader is None:
            raise ValueError(f"Cannot load Python tests: {file}")
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        cases = unittest.defaultTestLoader.loadTestsFromModule(module)
        if cases.countTestCases() == 0:
            raise ValueError(f"No tests in classified file: {file}")
        suite.addTests(cases)
    return suite


def main():
    result = unittest.TextTestRunner(verbosity=2).run(load_suite(sys.argv[1:]))
    return 0 if result.wasSuccessful() and result.testsRun > 0 and not (
        result.skipped or result.expectedFailures or result.unexpectedSuccesses
    ) else 1


if __name__ == "__main__":
    sys.exit(main())
