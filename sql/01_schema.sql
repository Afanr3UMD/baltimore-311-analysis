/*
 01_schema.sql
 Creates the tables the raw files are loaded into.

 Two schemas (folders inside the database):
   staging  the files exactly as downloaded, every column stored as text
   clean    cleaned, typed tables that the analysis runs on

 Why load everything as text first? If a column were typed as a date and one
 row held a bad value, the whole load would fail. Loading as text always
 succeeds, and the cleaning step then decides what to do with each bad value
 and records how many rows it affected.

 Run: psql -d baltimore_311 -f sql/01_schema.sql
*/

\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS clean;

-- One staging table for all three years. The 2025 file has four extra system
-- columns and no RowID, so those columns are simply empty for the other years.
-- UNLOGGED skips PostgreSQL's crash-recovery journal: loading is faster and
-- uses less disk, and staging data can always be reloaded from the CSVs.
DROP TABLE IF EXISTS staging.raw_311;
CREATE UNLOGGED TABLE staging.raw_311 (
    source_year       integer,   -- which yearly file the row came from
    rowid             text,      -- 2023 and 2024 only
    srrecordid        text,
    servicerequestnum text,
    srtype            text,
    methodreceived    text,
    createddate       text,
    srstatus          text,
    statusdate        text,
    duedate           text,
    closedate         text,
    agency            text,
    lastactivity      text,
    lastactivitydate  text,
    outcome           text,
    address           text,
    zipcode           text,
    neighborhood      text,
    councildistrict   text,
    policedistrict    text,
    policepost        text,
    latitude          text,
    longitude         text,
    geolocation       text,
    needssync         text,      -- 2025 only
    isdeleted         text,      -- 2025 only
    hashedrecord      text,      -- 2025 only
    esri_oid          text,      -- 2025 only
    x                 text,
    y                 text
);

-- 2020 Census population, already clean, so loaded straight into typed tables.
DROP TABLE IF EXISTS clean.neighborhood_population;
CREATE TABLE clean.neighborhood_population (
    neighborhood    text PRIMARY KEY,
    population_2020 integer NOT NULL
);

DROP TABLE IF EXISTS clean.council_district_population;
CREATE TABLE clean.council_district_population (
    council_district integer PRIMARY KEY,
    population_2020  integer NOT NULL
);
