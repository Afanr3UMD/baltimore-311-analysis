/*
 03_cleaning.sql
 Builds clean.service_requests (one row per request, typed and standardized)
 from staging.raw_311, and records every cleaning decision with the number of
 rows it affected in clean.cleaning_log.

 Most steps use this pattern:

   WITH changed AS (UPDATE ... RETURNING 1)
   INSERT INTO clean.cleaning_log (...) SELECT ..., count(*) FROM changed;

 The UPDATE makes the change, RETURNING hands back one row per changed row,
 and the INSERT counts them into the log, all in one statement. So the log is
 always exactly what the script did, not a separate estimate.

 Run from the project folder (about a minute):
   psql -d baltimore_311 -f sql/03_cleaning.sql
*/

\set ON_ERROR_STOP on

-- The published times are Baltimore local time with no time zone attached.
-- Working in UTC makes PostgreSQL read them exactly as written, with no
-- daylight-saving adjustments.
SET TIME ZONE 'UTC';

-- Let this session sort in memory (the default is 4 MB). The dedupe step sorts
-- all 3 million rows; in memory it is faster and avoids large temp files.
SET work_mem = '2GB';


-- ============================================================================
-- Setup: the log table and a safe date parser
-- ============================================================================

DROP TABLE IF EXISTS clean.cleaning_log;
CREATE TABLE clean.cleaning_log (
    step          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,  -- run order
    category      text   NOT NULL,
    issue         text   NOT NULL,
    decision      text   NOT NULL,
    rows_affected bigint NOT NULL
);

-- Dates arrive as text like '1/5/2024 3:58:07 PM'. This returns a timestamp,
-- or NULL if the text is not in that format (instead of stopping the script).
CREATE OR REPLACE FUNCTION clean.parse_311_time(s text) RETURNS timestamp
LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN s ~ '^\d{1,2}/\d{1,2}/\d{4} \d{1,2}:\d{2}:\d{2} (AM|PM)$'
        THEN to_timestamp(s, 'MM/DD/YYYY HH12:MI:SS AM')::timestamp
    END
$$;


-- ============================================================================
-- Part 1: checks on the raw data, and rows that are removed
-- ============================================================================

INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Starting point', 'Rows loaded from the three yearly files', 'None', count(*)
FROM staging.raw_311;

-- count(DISTINCT r) compares whole rows: every column must match.
INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Duplicates', 'Exact duplicate rows (every column identical)',
       'Keep one copy of each', count(*) - count(DISTINCT r)
FROM staging.raw_311 r;

INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Duplicates', 'Same request number appearing more than once',
       'Keep the version with the latest status date', count(*) - count(DISTINCT servicerequestnum)
FROM staging.raw_311;

INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Dates', 'Created date missing or not a valid date',
       'Remove: a request with no start time cannot be analyzed', count(*)
FROM staging.raw_311
WHERE clean.parse_311_time(createddate) IS NULL;

INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Dates', 'Created date outside the file''s own year',
       'Remove', count(*)
FROM staging.raw_311
WHERE extract(year FROM clean.parse_311_time(createddate)) <> source_year;

INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Test records', 'System test or placeholder records (types "TEST-St Light Out" and "Legacy Service Request")',
       'Remove: not real requests', count(*)
FROM staging.raw_311
WHERE srtype LIKE 'TEST-%' OR srtype = 'Legacy Service Request';

-- Counted here, before the build, because the build makes these fixes in passing.
INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Whitespace', 'Agency names padded with trailing spaces (e.g. "Transportation          ")',
       'Trim spaces', count(*)
FROM staging.raw_311
WHERE agency <> trim(agency);

INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Request types', 'Request type written with a long dash (–) instead of a hyphen (-)',
       'Replace with a hyphen', count(*)
FROM staging.raw_311
WHERE srtype LIKE '%–%';


-- ============================================================================
-- Part 2: build the clean table
-- ============================================================================

DROP TABLE IF EXISTS clean.service_requests;
CREATE TABLE clean.service_requests (
    request_id       text PRIMARY KEY,      -- e.g. '24-00000007'
    source_year      integer   NOT NULL,
    sr_type          text      NOT NULL,    -- full type as published, e.g. 'TRM-Pickup Pothole'
    division_code    text      NOT NULL,    -- part before the first dash, e.g. 'TRM'
    request_type     text      NOT NULL,    -- part after the first dash, e.g. 'Pickup Pothole'
    agency           text,
    method_received  text,
    status_raw       text      NOT NULL,    -- status as published, kept for auditing
    status           text      NOT NULL,    -- New / Open / Pending / Hold / Closed
    is_duplicate     boolean   NOT NULL,    -- city marked it as a repeat of another request
    is_transferred   boolean   NOT NULL,    -- closed because it was handed to another request
    is_call_center   boolean   NOT NULL,    -- handled by the 311 call center itself (code ECC)
    is_proactive     boolean   NOT NULL,    -- work crews logged it themselves, not a resident
    created_at       timestamp NOT NULL,
    due_at           timestamp,
    closed_at        timestamp,
    date_issue       text,                  -- set when the dates don't make sense together
    neighborhood_raw text,                  -- as published, kept for auditing
    neighborhood     text,
    council_district integer,
    police_district  text,
    zip_code         text,
    latitude         numeric(9, 6),
    longitude        numeric(9, 6),

    -- Generated columns: PostgreSQL calculates these from the columns above
    -- and keeps them up to date, so they can never disagree with the dates.
    resolution_hours numeric GENERATED ALWAYS AS (
        CASE WHEN status = 'Closed' AND closed_at >= created_at
             THEN round(extract(epoch FROM closed_at - created_at) / 3600, 2) END
    ) STORED,
    resolution_days numeric GENERATED ALWAYS AS (
        CASE WHEN status = 'Closed' AND closed_at >= created_at
             THEN round(extract(epoch FROM closed_at - created_at) / 86400, 2) END
    ) STORED,
    -- TRUE for requests whose resolution time is meaningful: closed with valid
    -- dates, a real field request, and not closed as a duplicate or transfer.
    in_resolution_analysis boolean GENERATED ALWAYS AS (
        COALESCE(status = 'Closed' AND closed_at >= created_at, false)
        AND NOT is_duplicate AND NOT is_transferred
        AND NOT is_call_center AND NOT is_proactive
    ) STORED,
    -- Why a neighborhood is missing. The box is the outermost latitude and
    -- longitude of every request that has a city neighborhood (from profiling),
    -- so a point outside it is outside Baltimore City.
    location_status text GENERATED ALWAYS AS (
        CASE
            WHEN neighborhood IS NOT NULL THEN 'City neighborhood'
            WHEN latitude IS NULL         THEN 'No location given'
            WHEN latitude NOT BETWEEN 39.1992 AND 39.3720
              OR longitude NOT BETWEEN -76.7113 AND -76.5297 THEN 'Outside city limits'
            ELSE 'Inside city, neighborhood missing'
        END
    ) STORED
);

INSERT INTO clean.service_requests (
    request_id, source_year, sr_type, division_code, request_type, agency,
    method_received, status_raw, status, is_duplicate, is_transferred,
    is_call_center, is_proactive, created_at, due_at, closed_at,
    neighborhood_raw, neighborhood, council_district, police_district,
    zip_code, latitude, longitude
)
WITH deduped AS (
    -- DISTINCT ON keeps the first row per request number, using the ORDER BY:
    -- the one with the latest status date.
    SELECT DISTINCT ON (trim(servicerequestnum)) *
    FROM staging.raw_311
    ORDER BY trim(servicerequestnum), clean.parse_311_time(statusdate) DESC NULLS LAST
),
typed AS (
    SELECT
        d.*,
        replace(trim(d.srtype), '–', '-')        AS sr_type_fixed,
        clean.parse_311_time(d.createddate)      AS created_ts
    FROM deduped d
)
SELECT
    trim(servicerequestnum),
    source_year,
    sr_type_fixed,
    split_part(sr_type_fixed, '-', 1),
    trim(substr(sr_type_fixed, strpos(sr_type_fixed, '-') + 1)),
    NULLIF(trim(agency), ''),
    NULLIF(trim(methodreceived), ''),
    trim(srstatus),
    -- 'Closed (Transferred)', 'Closed(Duplicate) (Duplicate)' etc. all become
    -- 'Closed': keep the text before the first bracket.
    trim(split_part(srstatus, '(', 1)),
    srstatus ILIKE '%duplicate%',
    srstatus ILIKE '%transferred%',
    split_part(sr_type_fixed, '-', 1) = 'ECC',
    sr_type_fixed ILIKE '%proactive%',
    created_ts,
    clean.parse_311_time(duedate),
    clean.parse_311_time(closedate),
    NULLIF(trim(neighborhood), ''),
    NULLIF(trim(neighborhood), ''),
    NULLIF(trim(councildistrict), '')::integer,
    NULLIF(trim(policedistrict), ''),
    NULLIF(trim(zipcode), ''),
    NULLIF(trim(latitude), '')::numeric(9, 6),
    NULLIF(trim(longitude), '')::numeric(9, 6)
FROM typed
WHERE created_ts IS NOT NULL
  AND extract(year FROM created_ts) = source_year
  AND NOT (sr_type_fixed LIKE 'TEST-%' OR sr_type_fixed = 'Legacy Service Request');

INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Checkpoint', 'Rows in the clean table after removals', 'None', count(*)
FROM clean.service_requests;


-- ============================================================================
-- Part 3: standardize statuses and request types (counted from the result)
-- ============================================================================

INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Status', '12 different status spellings, e.g. "Closed(Duplicate)", "Closed(Duplicate) (Duplicate)", "Closed (Transferred)"',
       'Reduce to 5 statuses (New, Open, Pending, Hold, Closed); move "Duplicate" and "Transferred" into yes/no flags',
       count(*)
FROM clean.service_requests
WHERE status_raw <> status;

INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Status', 'Requests the city marked as duplicates of another request',
       'Flag (is_duplicate); keep for volume counts, leave out of resolution times', count(*)
FROM clean.service_requests
WHERE is_duplicate;

INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Status', 'Requests closed because they were transferred to another request',
       'Flag (is_transferred); leave out of resolution times, since closing measures the hand-off, not the fix', count(*)
FROM clean.service_requests
WHERE is_transferred;

-- Same issue name filed under more than one division code, e.g.
-- 'TR-Street Cut Issues' and 'TRM-Street Cut Issues'.
INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Request types',
       format('Same issue filed under different division codes (%s issue names, e.g. "TR-Street Cut Issues" and "TRM-Street Cut Issues")', count(DISTINCT request_type)),
       'Add request_type (issue name without the division code) and group by it', count(*)
FROM clean.service_requests
WHERE request_type IN (
    SELECT request_type FROM clean.service_requests
    GROUP BY request_type HAVING count(DISTINCT division_code) > 1
);


-- ============================================================================
-- Part 4: fixes applied with UPDATE (each logs its own row count)
-- ============================================================================

-- Missing agency: use the agency the city recorded most often for the same
-- request type. Types with no agency recorded anywhere stay missing.
WITH usual_agency AS (
    SELECT DISTINCT ON (sr_type) sr_type, agency
    FROM clean.service_requests
    WHERE agency IS NOT NULL
    GROUP BY sr_type, agency
    ORDER BY sr_type, count(*) DESC, agency   -- agency name breaks ties
),
changed AS (
    UPDATE clean.service_requests s
    SET agency = u.agency
    FROM usual_agency u
    WHERE s.sr_type = u.sr_type AND s.agency IS NULL
    RETURNING 1
)
INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Missing values', 'Agency missing (mostly "TRS-Parking Complaint" from 2024 on)',
       'Fill with the agency most often recorded for the same request type', count(*)
FROM changed;

INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Missing values', 'Agency still missing (types with no agency recorded anywhere)',
       'Leave missing', count(*)
FROM clean.service_requests
WHERE agency IS NULL;

-- Neighborhood capitalization, e.g. 'University Of Maryland' -> 'University of Maryland'
WITH changed AS (
    UPDATE clean.service_requests s
    SET neighborhood = p.neighborhood
    FROM clean.neighborhood_population p
    WHERE lower(s.neighborhood) = lower(p.neighborhood)
      AND s.neighborhood <> p.neighborhood
    RETURNING 1
)
INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Neighborhoods', 'Capitalization differs from the official list (e.g. "University Of Maryland")',
       'Use the official spelling', count(*)
FROM changed;

-- Old neighborhood names used in 2023. Each was matched to its current name
-- by finding the same street addresses in 2024-2025 and seeing which
-- neighborhood they were filed under (share of matching addresses in brackets).
WITH renames (old_name, new_name) AS (
    VALUES
        ('Glenham-Belhar',            'Hamilton'),                    -- 99.4% of 1,079 addresses
        ('New Southwest/Mount Clare', 'Mount Clare'),                 -- 99.3% of 681
        ('Parkview/Woodbrook',        'Auchentoroly-Parkwood'),       -- 99.8% of 533
        ('Butcher''s Hill',           'Butchers Hill'),               -- 99.5% of 406
        ('Burleith-Leighton',         'Parkway'),                     -- 100% of 180
        ('Wrenlane',                  'Wilson Park'),                 -- 100% of 123
        ('Lower Edmondson Village',   'Allendale'),                   -- 100% of 97
        ('Fairmont',                  'Fairmount'),                   -- 95.6% of 68
        ('Port Covington',            'Baltimore Peninsula'),         -- 78.1% of 32
        ('Perkins Homes',             'Perkins'),                     -- 92.9% of 14
        ('Stadium Area',              'Stadium/Entertainment Area')   -- 95.2% of 21
),
changed AS (
    UPDATE clean.service_requests s
    SET neighborhood = r.new_name
    FROM renames r
    WHERE s.neighborhood = r.old_name
    RETURNING 1
)
INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Neighborhoods', '11 older neighborhood names used in 2023 (e.g. "Port Covington", now "Baltimore Peninsula")',
       'Map to the current name, matched by finding the same addresses in 2024-2025', count(*)
FROM changed;

-- Anything still not on the official list is a street name typed into the
-- neighborhood field (e.g. 'N HOLLIDAY ST').
WITH changed AS (
    UPDATE clean.service_requests s
    SET neighborhood = NULL
    WHERE s.neighborhood IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM clean.neighborhood_population p WHERE p.neighborhood = s.neighborhood)
    RETURNING 1
)
INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Neighborhoods', 'Street names typed into the neighborhood field (e.g. "N HOLLIDAY ST"), all in 2023',
       'Set neighborhood to missing', count(*)
FROM changed;

-- Date problems. Status is treated as the source of truth for open/closed.
WITH changed AS (
    UPDATE clean.service_requests
    SET closed_at = NULL,
        date_issue = 'Close date on a request that is not closed'
    WHERE status <> 'Closed' AND closed_at IS NOT NULL
    RETURNING 1
)
INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Dates', 'Close date present but the status is not Closed (likely reopened)',
       'Remove the close date: the request is still open', count(*)
FROM changed;

WITH changed AS (
    UPDATE clean.service_requests
    SET date_issue = 'Closed with no close date'
    WHERE status = 'Closed' AND closed_at IS NULL
    RETURNING 1
)
INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Dates', 'Status is Closed but there is no close date',
       'Keep as closed; resolution time unknown', count(*)
FROM changed;

WITH changed AS (
    UPDATE clean.service_requests
    SET date_issue = 'Closed before created'
    WHERE closed_at < created_at
    RETURNING 1
)
INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Dates', 'Close date earlier than created date (mostly crews logging proactive work after finishing it)',
       'Keep the request; resolution time left blank', count(*)
FROM changed;


-- ============================================================================
-- Part 5: summary of flags and what is left for analysis
-- ============================================================================

INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Flags', 'Handled by the 311 call center itself (division code ECC: questions, lookups, escalations)',
       'Flag (is_call_center); keep for volume counts, leave out of resolution times and neighborhood comparisons', count(*)
FROM clean.service_requests
WHERE is_call_center;

INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Flags', 'Proactive work logged by city crews, not reported by residents (e.g. "SW-Rat Rubout Proactive")',
       'Flag (is_proactive); leave out of resolution times', count(*)
FROM clean.service_requests
WHERE is_proactive;

INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Missing values', 'Neighborhood missing: ' || location_status,
       CASE location_status
           WHEN 'No location given'   THEN 'Leave missing: no address or map point (mostly call-center questions)'
           WHEN 'Outside city limits' THEN 'Leave missing: map point is outside Baltimore City (e.g. county water service)'
           ELSE 'Leave missing'
       END,
       count(*)
FROM clean.service_requests
WHERE neighborhood IS NULL
GROUP BY location_status
ORDER BY count(*) DESC;

INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Final', 'Rows in clean.service_requests', 'None', count(*)
FROM clean.service_requests;

INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Final', 'Rows usable for resolution-time analysis (closed, valid dates, resident field requests, not duplicates or transfers)',
       'None', count(*)
FROM clean.service_requests
WHERE in_resolution_analysis;

-- Tidy up after the UPDATEs and refresh the statistics the query planner uses.
VACUUM ANALYZE clean.service_requests;

SELECT step, category, issue, rows_affected FROM clean.cleaning_log ORDER BY step;

-- Optional: the staging table is no longer needed once this has run. Emptying
-- it frees about 1.3 GB; sql/02_load.sql refills it in about 30 seconds.
-- TRUNCATE staging.raw_311;
