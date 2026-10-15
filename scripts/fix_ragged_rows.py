"""
Streams a 311 CSV to stdout with every row padded to the header's length.

The city's export leaves off the last two columns (x, y) on rows that have no
map location, and PostgreSQL's loader rejects rows with too few fields. This
only adds empty fields to the end of short rows; no values are changed.
sql/02_load.sql runs it via \\copy ... FROM PROGRAM, so no extra file is written.

Other cases: blank lines are skipped, rows longer than the header are passed
through unchanged so PostgreSQL rejects them loudly, and an empty file stops
with an error. Output is UTF-8 with CRLF line endings, which makes the csv
module quote any field that contains a line break.

Usage: python3 scripts/fix_ragged_rows.py data/raw/311_2023.csv
"""

import csv
import sys

csv.field_size_limit(10**8)
sys.stdout.reconfigure(encoding="utf-8", newline="")

with open(sys.argv[1], newline="", encoding="utf-8-sig") as f:
    reader = csv.reader(f)
    writer = csv.writer(sys.stdout, lineterminator="\r\n")
    header = next(reader, None)
    if header is None:
        sys.exit(f"{sys.argv[1]}: file is empty")
    writer.writerow(header)
    for row in reader:
        if not row:
            continue
        if len(row) < len(header):
            row += [""] * (len(header) - len(row))
        writer.writerow(row)
