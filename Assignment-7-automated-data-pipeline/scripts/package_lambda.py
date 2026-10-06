"""Build a deterministic Lambda zip from lambda/order_generator/.

Only top-level *.py files are packaged (flat layout: handler.py at the zip root).
Fixed timestamps and permissions mean the same sources always give the same
SHA-256, so the deploy script can tell whether the code actually changed.

Usage: python scripts/package_lambda.py [output_zip]
"""

from __future__ import annotations

import base64
import hashlib
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "lambda" / "order_generator"
DEFAULT_OUTPUT = ROOT / "build" / "order_generator.zip"
FIXED_DATE = (2026, 1, 1, 0, 0, 0)


def build(output: Path = DEFAULT_OUTPUT) -> Path:
    sources = sorted(SOURCE_DIR.glob("*.py"))
    if not any(p.name == "handler.py" for p in sources):
        raise SystemExit(f"handler.py not found in {SOURCE_DIR}")
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for path in sources:
            info = zipfile.ZipInfo(path.name, date_time=FIXED_DATE)
            info.external_attr = 0o644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            zf.writestr(info, path.read_bytes())
    return output


def code_sha256_b64(path: Path) -> str:
    """Same encoding as Lambda's CodeSha256."""
    return base64.b64encode(hashlib.sha256(path.read_bytes()).digest()).decode()


if __name__ == "__main__":
    out = build(Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUTPUT)
    with zipfile.ZipFile(out) as zf:
        names = zf.namelist()
    print(f"{out} ({out.stat().st_size} bytes) files={names} CodeSha256={code_sha256_b64(out)}")
