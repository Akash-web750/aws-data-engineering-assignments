"""Build a deterministic Lambda zip from lambda/order_generator/.

Only top-level *.py files are packaged (flat layout: handler.py at the zip root).
Fixed timestamps and permissions mean the same sources always give the same
SHA-256, so the deploy script can tell whether the code actually changed.

Usage: python scripts/package_lambda.py [output_zip]

Used by infra/aws/deploy.ps1. Only the standard library is needed. The Lambda
code itself depends only on the standard library plus boto3, which the Lambda
runtime provides, so there are no dependencies to vendor into the zip.
"""

from __future__ import annotations

import base64
import hashlib
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "lambda" / "order_generator"
# build/ is git-ignored; the zip is a local artifact only.
DEFAULT_OUTPUT = ROOT / "build" / "order_generator.zip"
# A constant entry timestamp: zip headers embed file mtimes, which would otherwise
# change the archive hash on every checkout even when the code is identical.
FIXED_DATE = (2026, 1, 1, 0, 0, 0)


def build(output: Path = DEFAULT_OUTPUT) -> Path:
    """Write the zip and return its path."""
    # Sorted for a stable entry order (part of the byte-for-byte reproducibility).
    sources = sorted(SOURCE_DIR.glob("*.py"))
    if not any(p.name == "handler.py" for p in sources):
        raise SystemExit(f"handler.py not found in {SOURCE_DIR}")
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for path in sources:
            info = zipfile.ZipInfo(path.name, date_time=FIXED_DATE)
            # rw-r--r-- so the Lambda runtime can read the files, and identical
            # attributes on every build machine.
            info.external_attr = 0o644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            zf.writestr(info, path.read_bytes())
    return output


def code_sha256_b64(path: Path) -> str:
    """Same encoding as Lambda's CodeSha256."""
    # deploy.ps1 compares this value with get-function-configuration CodeSha256
    # and skips update-function-code when they match.
    return base64.b64encode(hashlib.sha256(path.read_bytes()).digest()).decode()


if __name__ == "__main__":
    out = build(Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUTPUT)
    with zipfile.ZipFile(out) as zf:
        names = zf.namelist()
    print(f"{out} ({out.stat().st_size} bytes) files={names} CodeSha256={code_sha256_b64(out)}")
