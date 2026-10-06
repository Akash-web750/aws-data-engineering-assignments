import sys
from pathlib import Path

# The Lambda package is deployed flat (handler.py at the zip root), so tests import it the same way.
LAMBDA_DIR = Path(__file__).resolve().parents[2] / "lambda" / "order_generator"
sys.path.insert(0, str(LAMBDA_DIR))
sys.path.insert(0, str(Path(__file__).resolve().parent))
