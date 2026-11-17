"""Runs every tests/test_*.py unittest and ends with a RESULT line for test.sh."""
import sys
import unittest
import warnings
from pathlib import Path

here = Path(__file__).resolve().parent
sys.path.insert(0, str(here))
warnings.simplefilter("ignore", ResourceWarning)

suite = unittest.defaultTestLoader.discover(str(here), pattern="test_*.py", top_level_dir=str(here))
result = unittest.TextTestRunner(stream=sys.stderr, verbosity=1).run(suite)

failed_ids = {getattr(t, "test_case", t).id() for t, _ in result.failures + result.errors}
failed = len(failed_ids)
skipped = len(result.skipped)
passed = result.testsRun - failed - skipped
print(f"RESULT passed={passed} failed={failed} skipped={skipped}")
sys.exit(0 if result.wasSuccessful() else 1)
