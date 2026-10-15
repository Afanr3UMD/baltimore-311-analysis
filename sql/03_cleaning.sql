/*
 03_cleaning.sql
 Builds clean.service_requests (one row per request, typed and standardized)
 from staging.raw_311, and records every cleaning decision with the number of
 rows it affected in clean.cleaning_log. No number in the log is typed in by
 hand: the script counts every one of them. The counts come from three places:

   Part 1     counts on the raw staging table, just before the clean table is
              built (the build makes those removals and fixes in a single pass)
   Parts 3, 5 counts on the finished table (statuses, flags, summaries; Part 4
              also has two of these)
   Part 4     fixes made with UPDATE. Each one logs its own count in the same
              statement that makes the change:

             WITH changed AS (UPDATE ... RETURNING 1)
             INSERT INTO clean.cleaning_log (...) SELECT ..., count(*) FROM changed;

           RETURNING hands back one row per changed row, and the INSERT
           counts them, so the logged number is exactly what changed.

 Run from the project folder, after sql/02_load.sql (about 5 minutes):
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

-- Stop before dropping anything if the staging table is empty (it can be
-- emptied to save disk; see the end of this file). Without this check the
-- script would replace the clean table with an empty one.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM staging.raw_311) THEN
        RAISE EXCEPTION 'staging.raw_311 is empty: run sql/02_load.sql first';
    END IF;
END $$;


-- ============================================================================
-- Setup: the log table and a date parser
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
-- or NULL if the text is empty or not in that shape. Text in the right shape
-- but impossible (e.g. 2/30/2023) raises an error and stops the script on
-- purpose. SET TimeZone pins the function to UTC so it gives the same answer
-- in any session.
CREATE OR REPLACE FUNCTION clean.parse_311_time(s text) RETURNS timestamp
LANGUAGE sql STABLE SET TimeZone = 'UTC' AS $$
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

-- A repeated request number also catches exact duplicate rows, since a copied
-- row repeats its request number. (A whole-row comparison would not work here:
-- each file gives every row its own internal row id.)
INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Duplicates', 'Same request number appearing more than once (this also catches exact duplicate rows)',
       'Keep the version with the latest status date', count(*) - count(DISTINCT trim(servicerequestnum))
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

-- Same test as the build's WHERE clause below.
INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Test records', 'System test or placeholder records (types "TEST-St Light Out" and "Legacy Service Request")',
       'Remove: not real requests', count(*)
FROM staging.raw_311
WHERE replace(trim(srtype), '–', '-') LIKE 'TEST-%'
   OR replace(trim(srtype), '–', '-') = 'Legacy Service Request';

-- The next two are fixed by the build in passing, so they are counted here,
-- on the rows the build keeps.
INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Whitespace', 'Agency names padded with trailing spaces (e.g. "Transportation          ")',
       'Trim spaces', count(*)
FROM staging.raw_311
WHERE agency <> trim(agency)
  AND NOT (replace(trim(srtype), '–', '-') LIKE 'TEST-%'
           OR replace(trim(srtype), '–', '-') = 'Legacy Service Request');

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
    sr_type          text      NOT NULL,    -- full type as published, e.g. 'TRM-Potholes'
    division_code    text      NOT NULL,    -- part before the first dash, e.g. 'TRM'
    request_type     text      NOT NULL,    -- part after the first dash, e.g. 'Potholes'
    agency_raw       text,                  -- as published (trimmed), kept for auditing
    agency           text,
    method_received  text,
    status_raw       text      NOT NULL,    -- status as published, kept for auditing
    status           text      NOT NULL,    -- New / Open / Pending / Hold / Closed
    outcome          text,                  -- how the city closed it, e.g. 'Work could not be completed'
    is_duplicate     boolean   NOT NULL,    -- city marked it as a repeat of another request
    is_transferred   boolean   NOT NULL,    -- closed because it was handed to another request
    is_referred_out  boolean   NOT NULL,    -- closed because the work was referred to another agency
    is_call_center   boolean   NOT NULL,    -- filed under the 311 call center's division code (ECC)
    is_crew_logged   boolean   NOT NULL,    -- work city crews logged themselves, not a resident report
    is_scheduled     boolean   NOT NULL,    -- a booked pickup or event date, not a problem report
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

    -- About a third of close times are stored without seconds (e.g. 3:58:00).
    -- A request closed in the same minute it was created can therefore look a
    -- few seconds early; those count as closed in 0 time, not as bad dates.
    resolution_hours numeric GENERATED ALWAYS AS (
        CASE WHEN status = 'Closed' AND closed_at >= date_trunc('minute', created_at)
             THEN round(greatest(extract(epoch FROM closed_at - created_at), 0) / 3600, 2) END
    ) STORED,
    resolution_days numeric GENERATED ALWAYS AS (
        CASE WHEN status = 'Closed' AND closed_at >= date_trunc('minute', created_at)
             THEN round(greatest(extract(epoch FROM closed_at - created_at), 0) / 86400, 2) END
    ) STORED,
    -- Requests created from 2025-03-31 to 2025-05-31: the city's 2025 file is
    -- missing most of them (see data_cleaning_log.md).
    in_2025_data_gap boolean GENERATED ALWAYS AS (
        created_at >= timestamp '2025-03-31' AND created_at < timestamp '2025-06-01'
    ) STORED,
    -- TRUE for requests whose time to close is a fair measure of the city's
    -- response: closed with valid dates, a field request, not a duplicate,
    -- transfer or referral, not crew-logged or a booked appointment, and not
    -- in the 2025 data gap.
    in_resolution_analysis boolean GENERATED ALWAYS AS (
        COALESCE(status = 'Closed' AND closed_at >= date_trunc('minute', created_at), false)
        AND NOT is_duplicate AND NOT is_transferred AND NOT is_referred_out
        AND NOT is_call_center AND NOT is_crew_logged AND NOT is_scheduled
        AND NOT (created_at >= timestamp '2025-03-31' AND created_at < timestamp '2025-06-01')
    ) STORED,
    -- Why a neighborhood is missing. A council district means the point is in
    -- the city. The box is the outermost latitude and longitude of every
    -- request that has a city neighborhood, so a point outside it is outside
    -- Baltimore City. The box is a rectangle, though, so a point inside it can
    -- still be county land near its corners.
    location_status text GENERATED ALWAYS AS (
        CASE
            WHEN neighborhood IS NOT NULL     THEN 'City neighborhood'
            WHEN latitude IS NULL             THEN 'No map point'
            WHEN council_district IS NOT NULL THEN 'In the city, neighborhood missing'
            WHEN latitude NOT BETWEEN 39.1992 AND 39.3720
              OR longitude NOT BETWEEN -76.7113 AND -76.5297 THEN 'Outside city limits'
            ELSE 'Inside the box, no neighborhood or district'
        END
    ) STORED
);

INSERT INTO clean.service_requests (
    request_id, source_year, sr_type, division_code, request_type, agency_raw, agency,
    method_received, status_raw, status, outcome, is_duplicate, is_transferred,
    is_referred_out, is_call_center, is_crew_logged, is_scheduled, created_at,
    due_at, closed_at, neighborhood_raw, neighborhood, council_district,
    police_district, zip_code, latitude, longitude
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
    NULLIF(trim(agency), ''),
    NULLIF(trim(methodreceived), ''),
    trim(srstatus),
    -- 'Closed (Transferred)', 'Closed(Duplicate) (Duplicate)' etc. all become
    -- 'Closed': keep the text before the first bracket.
    trim(split_part(srstatus, '(', 1)),
    NULLIF(trim(outcome), ''),
    srstatus ILIKE '%duplicate%',
    srstatus ILIKE '%transferred%',
    COALESCE(trim(outcome) = 'Work referred to another agency (NOT BY SR TRANSFER)', false),
    split_part(sr_type_fixed, '-', 1) = 'ECC',
    -- Crews log these after doing the work: the "Proactive" types, and pothole
    -- repairs crews fill on the spot (100% entered internally, 93.8% closed within a minute).
    sr_type_fixed ILIKE '%proactive%' OR sr_type_fixed = 'TRM-Pickup Pothole',
    -- Booked dates: the due date is set to 11:59 PM on the chosen day, and most
    -- close on that day, so the time to close is the wait for the booking.
    sr_type_fixed IN ('SW-Bulk Scheduled-Weekday', 'SW-Bulk Scheduled-Saturday',
                      'SW-Appliance (White Goods)', 'SW-Appliance (Saturday White Goods)',
                      'SW-Appliance (Testing)', 'SW-Leaf Collection Scheduling',
                      'SW-Community Pitch-In'),
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
-- Part 3: statuses and request types (counted on the finished table)
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
SELECT 'Status', 'Requests closed because they were transferred to another request (which carries on the work)',
       'Flag (is_transferred); leave out of resolution times, since closing measures the hand-off, not the fix', count(*)
FROM clean.service_requests
WHERE is_transferred;

INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Status', 'Closed with the outcome "Work referred to another agency (NOT BY SR TRANSFER)"',
       'Flag (is_referred_out); leave out of resolution times, same reason as transfers', count(*)
FROM clean.service_requests
WHERE is_referred_out;

-- Issue names that appear under more than one division code. Some are the
-- same work moving between Transportation divisions ('TR-Street Cut Issues'
-- and 'TRM-Street Cut Issues'); others are a call-center version next to a
-- field version ('ECC-Grass Mowing', 'TRM-Grass Mowing') or catch-alls such as
-- 'Other'. sr_type keeps the division when it matters.
INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Request types',
       format('%s issue names appear under more than one division code (e.g. "TR-Street Cut Issues" and "TRM-Street Cut Issues"; also call-center versions and catch-alls like "Other")', count(DISTINCT request_type)),
       'Add request_type (the name without the division code); keep sr_type for when the division matters', count(*)
FROM clean.service_requests
WHERE request_type IN (
    SELECT request_type FROM clean.service_requests
    GROUP BY request_type HAVING count(DISTINCT division_code) > 1
);


-- ============================================================================
-- Part 4: fixes applied with UPDATE (each logs its own row count)
-- ============================================================================

-- Missing agency: fill it only when one agency accounts for at least 90% of
-- the same request type's recorded rows. agency_raw keeps the blank.
WITH agency_counts AS (
    SELECT sr_type, agency, count(*) AS n,
           sum(count(*)) OVER (PARTITION BY sr_type) AS type_total
    FROM clean.service_requests
    WHERE agency IS NOT NULL
    GROUP BY sr_type, agency
),
usual_agency AS (
    -- At most one agency can reach 90%, so this is one row per type.
    SELECT sr_type, agency FROM agency_counts WHERE n >= 0.9 * type_total
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
       'Fill with the agency recorded on at least 90% of the same request type', count(*)
FROM changed;

-- Field requests tagged with the call center's agency code (ECC): use the
-- agency most often recorded for the same division code instead.
WITH usual_field_agency AS (
    SELECT DISTINCT ON (division_code) division_code, agency
    FROM clean.service_requests
    WHERE agency IS NOT NULL AND agency <> 'ECC' AND NOT is_call_center
    GROUP BY division_code, agency
    ORDER BY division_code, count(*) DESC, agency   -- agency name breaks ties
),
changed AS (
    UPDATE clean.service_requests s
    SET agency = u.agency
    FROM usual_field_agency u
    WHERE s.division_code = u.division_code AND s.agency = 'ECC' AND NOT s.is_call_center
    RETURNING 1
)
INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Agency', 'Field requests tagged with the call center''s agency code "ECC" (mostly parking requests)',
       'Use the agency most often recorded for the same division code', count(*)
FROM changed;

INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Missing values', 'Agency still missing (no agency recorded, or no single agency on 90% of the type''s rows)',
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

-- Old neighborhood names used in 2023. For each one, take the street
-- addresses filed under it in 2023, look up the neighborhood each address was
-- most often filed under in 2024-2025, and use the most common answer. The
-- evidence is kept in clean.neighborhood_renames.
DROP TABLE IF EXISTS clean.neighborhood_renames;
CREATE TABLE clean.neighborhood_renames AS
WITH old_names (old_name) AS (
    VALUES ('Glenham-Belhar'), ('New Southwest/Mount Clare'), ('Parkview/Woodbrook'),
           ('Butcher''s Hill'), ('Burleith-Leighton'), ('Wrenlane'),
           ('Lower Edmondson Village'), ('Fairmont'), ('Port Covington'),
           ('Perkins Homes'), ('Stadium Area')
),
later_name AS (
    -- One row per address: its most common 2024-2025 neighborhood.
    SELECT DISTINCT ON (address) address, neighborhood
    FROM (
        SELECT upper(trim(address)) AS address, trim(neighborhood) AS neighborhood, count(*) AS n
        FROM staging.raw_311
        WHERE source_year IN (2024, 2025) AND address IS NOT NULL AND neighborhood IS NOT NULL
        GROUP BY 1, 2
    ) t
    ORDER BY address, n DESC, neighborhood
),
old_address AS (
    SELECT DISTINCT trim(r.neighborhood) AS old_name, upper(trim(r.address)) AS address
    FROM staging.raw_311 r
    JOIN old_names o ON o.old_name = trim(r.neighborhood)
    WHERE r.source_year = 2023 AND r.address IS NOT NULL
),
votes AS (
    SELECT o.old_name, l.neighborhood AS new_name, count(*) AS addresses
    FROM old_address o
    JOIN later_name l USING (address)
    GROUP BY 1, 2
)
SELECT DISTINCT ON (old_name)
       old_name,
       new_name,
       addresses AS addresses_matching,
       sum(addresses) OVER (PARTITION BY old_name) AS addresses_seen_later,
       round(100.0 * addresses / sum(addresses) OVER (PARTITION BY old_name), 1) AS pct_matching
FROM votes
ORDER BY old_name, addresses DESC, new_name;

-- Every old name must map to a name on the official list.
DO $$
BEGIN
    IF (SELECT count(*) FROM clean.neighborhood_renames r
        JOIN clean.neighborhood_population p ON p.neighborhood = r.new_name) <> 11 THEN
        RAISE EXCEPTION 'neighborhood_renames does not map all 11 old names to official names';
    END IF;
END $$;

WITH changed AS (
    UPDATE clean.service_requests s
    SET neighborhood = r.new_name
    FROM clean.neighborhood_renames r
    WHERE s.neighborhood = r.old_name
    RETURNING 1
)
INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Neighborhoods', '11 older neighborhood names used in 2023 (e.g. "Port Covington", now "Baltimore Peninsula")',
       'Map to the current name, matched by finding the same addresses in 2024-2025 (evidence in clean.neighborhood_renames)', count(*)
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

-- Police districts: some 2023 rows are in capitals ('CENTRAL').
WITH changed AS (
    UPDATE clean.service_requests
    SET police_district = initcap(police_district)
    WHERE police_district <> initcap(police_district)
    RETURNING 1
)
INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Police districts', 'Police district written in capitals (e.g. "CENTRAL" next to "Central")',
       'Use the standard capitalization', count(*)
FROM changed;

-- ZIP codes that are not five digits: place names ('Franklin') or two ZIPs.
WITH changed AS (
    UPDATE clean.service_requests
    SET zip_code = NULL
    WHERE zip_code !~ '^\d{5}$'
    RETURNING 1
)
INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Location', 'ZIP code is a place name (e.g. "Franklin") or two ZIP codes, all in 2023',
       'Set ZIP code to missing', count(*)
FROM changed;

-- Due dates: on types with no service target the city's export shifts the
-- due date back by the UTC offset (exactly 5 hours in winter, 4 in summer),
-- so it lands before the request was created.
WITH changed AS (
    UPDATE clean.service_requests
    SET due_at = NULL
    WHERE due_at < created_at
    RETURNING 1
)
INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Dates', 'Due date earlier than created date (shifted by the UTC offset on types with no service target, mostly call-center)',
       'Remove the due date: it is a time-zone error in the export, not a real deadline', count(*)
FROM changed;

-- Close dates. Status is treated as the final word on open/closed.
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

-- Not a change, just a count: the generated columns already treat these as
-- closed in 0 time.
INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Dates', 'Close time stored without seconds and in the same minute the request was created, so it looks a few seconds early',
       'Treat as closed in under a minute (resolution time 0)', count(*)
FROM clean.service_requests
WHERE closed_at < created_at AND closed_at >= date_trunc('minute', created_at);

WITH changed AS (
    UPDATE clean.service_requests
    SET date_issue = 'Closed before created'
    WHERE closed_at < date_trunc('minute', created_at)
    RETURNING 1
)
INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Dates', 'Close date earlier than the minute the request was created',
       'Keep the request; resolution time left blank', count(*)
FROM changed;


-- ============================================================================
-- Part 5: summary of flags and what is left for analysis
-- ============================================================================

INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Flags', 'Filed under the 311 call center''s division code ECC: mostly questions and lookups answered on the call; escalations and complaints are passed to departments',
       'Flag (is_call_center); keep for volume counts, leave out of resolution times and neighborhood comparisons', count(*)
FROM clean.service_requests
WHERE is_call_center;

INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Flags', 'Work logged by city crews after doing it, not reported by residents (the "Proactive" types and "TRM-Pickup Pothole")',
       'Flag (is_crew_logged); leave out of resolution times', count(*)
FROM clean.service_requests
WHERE is_crew_logged;

INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Flags', 'Booked pickups and events (bulk trash, appliances, leaf collection, Community Pitch-In): the time to close is the wait for the booked date',
       'Flag (is_scheduled); leave out of resolution times', count(*)
FROM clean.service_requests
WHERE is_scheduled;

INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Flags', 'Created 2025-03-31 to 2025-05-31, when the city''s 2025 file is missing most requests',
       'Flag (in_2025_data_gap); leave out of resolution times and mark the gap in monthly charts', count(*)
FROM clean.service_requests
WHERE in_2025_data_gap;

INSERT INTO clean.cleaning_log (category, issue, decision, rows_affected)
SELECT 'Missing values', 'Neighborhood missing: ' || location_status,
       CASE location_status
           WHEN 'No map point'        THEN 'Leave missing: no map point (mostly call-center questions)'
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
SELECT 'Final', 'Rows usable for resolution-time analysis (closed with valid dates; field requests that are not call-center, crew-logged, booked, duplicates, transfers or referrals; outside the 2025 gap)',
       'None', count(*)
FROM clean.service_requests
WHERE in_resolution_analysis;

-- Tidy up after the UPDATEs and refresh the statistics the query planner uses.
VACUUM ANALYZE clean.service_requests;

SELECT step, category, issue, rows_affected FROM clean.cleaning_log ORDER BY step;

-- Optional: empty the staging table to free about 1.3 GB. After that, re-run
-- sql/02_load.sql (about 30 seconds) before running this script again; the
-- check at the top stops it otherwise.
-- TRUNCATE staging.raw_311;
