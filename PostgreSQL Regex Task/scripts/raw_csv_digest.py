#!/usr/bin/env python3
"""
Independent digest of data/raw_access_logs.csv (Python standard library only; no database access).

Step 3B-1 uses it to prove that log_regex.raw_access_logs holds exactly the Step 1 RAW LOGS.
The same digest is recomputed inside PostgreSQL by log_regex.raw_access_logs_digest():

    per row : "<log_id>:<hex SHA-256 of the UTF-8 bytes of raw_log>"   or "<log_id>:NULL" for SQL NULL
    dataset : hex SHA-256 of the per-row lines joined with LF, ordered by log_id

CSV convention (Step 1): raw_log is always double-quoted; an unquoted empty value is SQL NULL.

Usage:
    python scripts/raw_csv_digest.py            # readable summary
    python scripts/raw_csv_digest.py --json     # machine-readable (used by sql/run_step3b1_setup.ps1)
"""

import argparse
import csv
import hashlib
import io
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CSV = ROOT / "data" / "raw_access_logs.csv"
NBSP = "\u00a0"


def row_line(log_id, raw_log):
    if raw_log is None:
        return f"{log_id}:NULL"
    return f"{log_id}:{hashlib.sha256(raw_log.encode('utf-8')).hexdigest()}"


def summarise(csv_path):
    data = csv_path.read_bytes()
    text = data.decode("utf-8")
    null_ids = {int(x) for x in re.findall(r"(?m)^(\d+),$", text)}

    reader = csv.reader(io.StringIO(text, newline=""))
    header = next(reader)
    rows = []
    for log_id, raw_log in reader:
        log_id = int(log_id)
        rows.append((log_id, None if log_id in null_ids else raw_log))
    rows.sort(key=lambda r: r[0])

    ids = [log_id for log_id, _ in rows]
    present = [raw for _, raw in rows if raw is not None]
    return {
        "file": csv_path.name,
        "file_sha256": hashlib.sha256(data).hexdigest(),
        "header": header,
        "row_count": len(rows),
        "distinct_log_ids": len(set(ids)),
        "min_log_id": min(ids),
        "max_log_id": max(ids),
        "log_ids_contiguous_from_1": ids == list(range(1, len(ids) + 1)),
        "null_log_ids": sorted(null_ids),
        "empty_string_log_ids": [log_id for log_id, raw in rows if raw == ""],
        "whitespace_only_rows": sum(1 for raw in present if raw and not raw.strip()),
        "rows_containing_lf": sum("\n" in raw for raw in present),
        "rows_containing_cr": sum("\r" in raw for raw in present),
        "rows_containing_tab": sum("\t" in raw for raw in present),
        "rows_containing_nbsp": sum(NBSP in raw for raw in present),
        "rows_containing_non_ascii": sum(not raw.isascii() for raw in present),
        "max_char_length": max(len(raw) for raw in present),
        "total_char_length": sum(len(raw) for raw in present),
        "total_utf8_octets": sum(len(raw.encode("utf-8")) for raw in present),
        "dataset_digest": hashlib.sha256("\n".join(row_line(i, r) for i, r in rows).encode("utf-8")).hexdigest(),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--csv", type=Path, default=DEFAULT_CSV)
    parser.add_argument("--json", action="store_true", help="print JSON instead of a readable summary")
    args = parser.parse_args()
    summary = summarise(args.csv)
    if args.json:
        print(json.dumps(summary))
    else:
        for key, value in summary.items():
            print(f"{key:<28} {value}")


if __name__ == "__main__":
    main()
