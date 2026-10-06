"""pytest configuration shared by all unit tests.

The tests run fully offline: no AWS or Snowflake access is needed. The handler
tests inject a stub S3 client and block creation of a real boto3 client.
"""

import sys
from pathlib import Path

# The Lambda package is deployed flat (handler.py at the zip root), so tests import it the same way.
LAMBDA_DIR = Path(__file__).resolve().parents[2] / "lambda" / "order_generator"
sys.path.insert(0, str(LAMBDA_DIR))
# Also make the test helpers (dq_reference.py) importable by module name.
sys.path.insert(0, str(Path(__file__).resolve().parent))
