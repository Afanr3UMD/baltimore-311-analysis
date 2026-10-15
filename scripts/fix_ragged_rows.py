"""
Streams a 311 CSV to stdout with every row padded to the header's length.

The city's export leaves off the last two columns (x, y) on rows that have no
map location, and PostgreSQL's loader rejects rows with too few fields. This
only adds empty fields to the end of short rows; no values are changed.
sql/02_load.sql runs it via \\copy ... FROM PROGRAM, so no extra file is written.

Usage: python3 scripts/fix_ragged_rows.py data/raw/311_2023.csv
"""

import csv
import sys

csv.field_size_limit(10**8)

with open(sys.argv[1], newline="", encoding="utf-8-sig") as f:
    reader = csv.reader(f)
    writer = csv.writer(sys.stdout, lineterminator="\n")
    header = next(reader)
    writer.writerow(header)
    for row in reader:
        if len(row) < len(header):
            row += [""] * (len(header) - len(row))
        writer.writerow(row)
