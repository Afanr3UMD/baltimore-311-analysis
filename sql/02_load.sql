/*
 02_load.sql
 Loads the downloaded CSVs into the staging tables.

 \copy is a psql command: it reads a file on your computer and streams it into
 a table. File paths are relative, so run this from the project folder:

   cd 311Resume
   psql -d baltimore_311 -f sql/02_load.sql

 Download the files first (see data/README.md). Safe to re-run: it empties the
 tables first, so running it twice never doubles the data.

 The city's export leaves off the last two columns (x, y) on rows with no map
 location (about 30% of rows), and \copy rejects rows with too few fields. So
 each 311 file is streamed through scripts/fix_ragged_rows.py, which adds the
 missing empty fields and changes nothing else. The population files load directly.
*/

\set ON_ERROR_STOP on

\echo 'Loading 311 data (about 30 seconds)...'

TRUNCATE staging.raw_311, clean.neighborhood_population, clean.council_district_population;

-- source_year is not in the files, so set it as the column's default before
-- each load and every row from that file gets the right year.
ALTER TABLE staging.raw_311 ALTER COLUMN source_year SET DEFAULT 2023;
\copy staging.raw_311 (rowid, srrecordid, servicerequestnum, srtype, methodreceived, createddate, srstatus, statusdate, duedate, closedate, agency, lastactivity, lastactivitydate, outcome, address, zipcode, neighborhood, councildistrict, policedistrict, policepost, latitude, longitude, geolocation, x, y) FROM PROGRAM 'python3 -I scripts/fix_ragged_rows.py data/raw/311_2023.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

ALTER TABLE staging.raw_311 ALTER COLUMN source_year SET DEFAULT 2024;
\copy staging.raw_311 (rowid, srrecordid, servicerequestnum, srtype, methodreceived, createddate, srstatus, statusdate, duedate, closedate, agency, lastactivity, lastactivitydate, outcome, address, zipcode, neighborhood, councildistrict, policedistrict, policepost, latitude, longitude, geolocation, x, y) FROM PROGRAM 'python3 -I scripts/fix_ragged_rows.py data/raw/311_2024.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

-- 2025 has no RowID and four extra system columns.
ALTER TABLE staging.raw_311 ALTER COLUMN source_year SET DEFAULT 2025;
\copy staging.raw_311 (srrecordid, servicerequestnum, srtype, methodreceived, createddate, srstatus, statusdate, duedate, closedate, agency, lastactivity, lastactivitydate, outcome, address, zipcode, neighborhood, councildistrict, policedistrict, policepost, latitude, longitude, geolocation, needssync, isdeleted, hashedrecord, esri_oid, x, y) FROM PROGRAM 'python3 -I scripts/fix_ragged_rows.py data/raw/311_2025.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

ALTER TABLE staging.raw_311 ALTER COLUMN source_year DROP DEFAULT;

\copy clean.neighborhood_population FROM 'data/raw/population_neighborhoods_2020.csv' WITH (FORMAT csv, HEADER true)
\copy clean.council_district_population FROM 'data/raw/population_council_districts_2020.csv' WITH (FORMAT csv, HEADER true)

-- Check: rows per file should be 1,025,029 / 1,081,868 / 931,324.
SELECT source_year, count(*) AS rows_loaded
FROM staging.raw_311
GROUP BY source_year
ORDER BY source_year;
