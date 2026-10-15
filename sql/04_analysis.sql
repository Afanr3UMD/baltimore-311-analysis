/*
 04_analysis.sql
 Answers the six business questions. Each question builds one or more small
 result tables in the "analysis" schema; sql/05_export.sql saves them as CSVs
 for Tableau.

 Terms used throughout (all built from the flags in clean.service_requests):
   resident field requests   not call-center, not crew-logged, not a duplicate
                             (used to count demand)
   resolved requests used    in_resolution_analysis: closed with valid dates;
   for timing                not call-center, crew-logged, booked, a duplicate,
                             a transfer or a referral; outside the 2025 gap
                             (used for every time-to-close figure)
   comparable months         every month except April and May. The city's 2025
                             file is missing most requests from 2025-03-31 to
                             2025-05-31, so year-over-year counts leave April
                             and May out of every year.
   median                    PERCENTILE_CONT(0.5): the middle value, used
                             instead of the average because a few very slow
                             requests pull the average far up

 Run from the project folder, after sql/03_cleaning.sql:
   psql -d baltimore_311 -f sql/04_analysis.sql
*/

\set ON_ERROR_STOP on

-- Medians and rankings sort a lot of rows; let them sort in memory.
SET work_mem = '256MB';

CREATE SCHEMA IF NOT EXISTS analysis;

-- ============================================================================
-- Question 1: Most common request types, and how volume changed by month and year
-- ============================================================================

/*
 1a. analysis.q1_top_request_types
 Question: Which problems do residents report most, and how is each changing?
 How it works:
   1. resident_requests: keeps resident field requests (not call-center, not
      crew-logged, not a duplicate) and marks each as comparable month or not.
   2. type_year_counts: requests per type and year, comparable and full-year.
   3. type_year_spine: every type x every year 2023-2025, with 0 where a type
      had none (so LAG never skips a year), plus the type's 3-year total.
   4. with_previous_year: LAG fetches last year's comparable-month count.
   5. eligible, ranked: apply the size cutoffs, then RANK within each year.
   6. Final SELECT: top 10 per year, with the change from last year.
 Why:
   - Comparable months = every month except April and May, in every year: the
     city's 2025 file is missing most of April-May 2025. Ranks and changes use
     them so each year covers the same 10 months. Spring-heavy types lose
     more, so ranks can differ slightly from a 12-month ranking.
   - Call-center requests are left out so 'ECC-Grass Mowing' does not merge
     with the field type; crew work and duplicates are not new resident reports.
   - Cutoffs: 500+ requests over all of 2023-2025 to be ranked, and 100+ in a
     year's comparable months to rank that year. pct_change is blank when
     last year's count is under 100 (too small a base).
 Techniques: CTE, CASE, COUNT(*) FILTER, generate_series, CROSS JOIN, LEFT JOIN,
   SUM() OVER, LAG(), RANK()
*/
DROP TABLE IF EXISTS analysis.q1_top_request_types;
CREATE TABLE analysis.q1_top_request_types AS
WITH resident_requests AS (
    SELECT
        request_type,
        extract(year FROM created_at)::integer AS year,
        CASE WHEN extract(month FROM created_at) IN (4, 5) THEN false
             ELSE true
        END AS is_comparable_month
    FROM clean.service_requests
    WHERE NOT is_call_center
      AND NOT is_crew_logged
      AND NOT is_duplicate
),
type_year_counts AS (
    SELECT
        request_type,
        year,
        count(*) FILTER (WHERE is_comparable_month) AS requests_comparable_months,
        count(*)                                    AS requests_full_year
    FROM resident_requests
    GROUP BY request_type, year
),
type_year_spine AS (
    SELECT
        t.request_type,
        y.year,
        COALESCE(c.requests_comparable_months, 0) AS requests_comparable_months,
        COALESCE(c.requests_full_year, 0)         AS requests_full_year,
        sum(COALESCE(c.requests_full_year, 0))
            OVER (PARTITION BY t.request_type)    AS requests_all_years
    FROM (SELECT DISTINCT request_type FROM resident_requests) t
    CROSS JOIN generate_series(2023, 2025) AS y(year)
    LEFT JOIN type_year_counts c
           ON c.request_type = t.request_type
          AND c.year = y.year
),
with_previous_year AS (
    SELECT
        *,
        LAG(requests_comparable_months) OVER (
            PARTITION BY request_type
            ORDER BY year
        ) AS previous_year_requests_comparable
    FROM type_year_spine
),
eligible AS (
    -- Filtered after LAG, so last year's count is kept even when the type
    -- was not ranked last year.
    SELECT *
    FROM with_previous_year
    WHERE requests_all_years >= 500
      AND requests_comparable_months >= 100
),
ranked AS (
    SELECT
        *,
        RANK() OVER (
            PARTITION BY year
            ORDER BY requests_comparable_months DESC
        ) AS rank
    FROM eligible
)
SELECT
    year,
    rank::integer AS rank,
    request_type,
    requests_comparable_months,
    requests_full_year,
    previous_year_requests_comparable,
    requests_comparable_months - previous_year_requests_comparable AS change,
    CASE
        WHEN previous_year_requests_comparable >= 100
        THEN round((100.0 * (requests_comparable_months - previous_year_requests_comparable)
                    / previous_year_requests_comparable)::numeric, 2)
    END AS pct_change,
    (year = 2025) AS includes_data_gap      -- full-year count misses April-May
FROM ranked
WHERE rank <= 10;


/*
 1b. analysis.q1_monthly_volume
 Question: How does volume rise and fall through the year, and is each month
   busier or quieter than a year earlier, in each of the three groups below?
 How it works:
   1. calendar: every month from January 2023 to December 2025.
   2. resident_requests, call_center_requests, crew_logged_requests: the three
      groups. all_groups stacks them and gives each request its month.
   3. monthly_counts: requests per month and group.
   4. month_group_spine: every month x every group, 0 where there were none,
      and data_gap set for April and May 2025.
   5. with_windows: a running total that restarts each January, and LAG(12).
   6. Final SELECT: percentage change from the same month last year.
 Why:
   - The spine has exactly one row per month and group, so 12 rows back is
     always the same month a year earlier.
   - Resident duplicates are left out; the other two groups are defined by
     their flag alone, so their duplicates stay in.
   - April and May 2025 keep their real, very low counts so the drop shows;
     their pct change is blank, as it would show a collapse that did not happen.
   - March 2025 is not flagged, but the city's gap starts on 31 March 2025, so
     every group's March 2025 count is slightly low.
 Techniques: CTE, generate_series, date_trunc, UNION ALL, CROSS JOIN, LEFT JOIN,
   CASE, SUM() OVER (running total), LAG(), NULLIF
*/
DROP TABLE IF EXISTS analysis.q1_monthly_volume;
CREATE TABLE analysis.q1_monthly_volume AS
WITH calendar AS (
    SELECT month::date AS month
    FROM generate_series(date '2023-01-01', date '2025-12-01', interval '1 month') AS g(month)
),
categories (category, category_order) AS (
    VALUES ('Resident field requests', 1),
           ('Call center', 2),
           ('Crew-logged work', 3)
),
resident_requests AS (
    SELECT created_at
    FROM clean.service_requests
    WHERE NOT is_call_center
      AND NOT is_crew_logged
      AND NOT is_duplicate
),
call_center_requests AS (
    SELECT created_at
    FROM clean.service_requests
    WHERE is_call_center
),
crew_logged_requests AS (
    SELECT created_at
    FROM clean.service_requests
    WHERE is_crew_logged
),
all_groups AS (
    SELECT 'Resident field requests' AS category, date_trunc('month', created_at)::date AS month
    FROM resident_requests
    UNION ALL
    SELECT 'Call center', date_trunc('month', created_at)::date
    FROM call_center_requests
    UNION ALL
    SELECT 'Crew-logged work', date_trunc('month', created_at)::date
    FROM crew_logged_requests
),
monthly_counts AS (
    SELECT category, month, count(*) AS requests
    FROM all_groups
    GROUP BY category, month
),
month_group_spine AS (
    SELECT
        cal.month,
        extract(year FROM cal.month)::integer AS year,
        cat.category,
        cat.category_order,
        COALESCE(mc.requests, 0) AS requests,
        CASE WHEN cal.month IN (date '2025-04-01', date '2025-05-01') THEN true
             ELSE false
        END AS data_gap
    FROM calendar cal
    CROSS JOIN categories cat
    LEFT JOIN monthly_counts mc
           ON mc.month = cal.month
          AND mc.category = cat.category
),
with_windows AS (
    SELECT
        *,
        sum(requests) OVER (
            PARTITION BY category, year
            ORDER BY month
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS running_total_in_year,
        LAG(requests, 12) OVER (
            PARTITION BY category
            ORDER BY month
        ) AS same_month_last_year
    FROM month_group_spine
)
SELECT
    month,
    year,
    category,
    category_order,
    requests,
    running_total_in_year::bigint AS running_total_in_year,
    same_month_last_year,
    CASE
        WHEN data_gap THEN NULL
        ELSE round((100.0 * (requests - same_month_last_year)
                    / NULLIF(same_month_last_year, 0))::numeric, 2)
    END AS pct_change_vs_last_year,
    data_gap
FROM with_windows;

-- Check: 108 rows (36 months x 3 groups), each request counted exactly once.
DO $$
DECLARE
    n_rows      bigint;
    n_monthly   bigint;
    n_direct    bigint;
BEGIN
    SELECT count(*), sum(requests) INTO n_rows, n_monthly FROM analysis.q1_monthly_volume;
    SELECT count(*) INTO n_direct
    FROM clean.service_requests
    WHERE is_call_center OR is_crew_logged OR NOT is_duplicate;
    IF n_rows <> 108 OR n_monthly <> n_direct THEN
        RAISE EXCEPTION 'q1_monthly_volume check failed: % rows, % requests (expected 108 rows, % requests)',
            n_rows, n_monthly, n_direct;
    END IF;
END $$;


/*
 1c. analysis.q1_yearly_totals
 Question: Is total volume going up or down from year to year, for each of
   the three groups?
 How it works:
   1. yearly: adds up 1b's monthly table per year and group, over all 12
      months and over comparable months only (CASE drops April and May), and
      notes whether the year has a data-gap month.
   2. with_previous_year: LAG fetches the group's comparable-month total from
      the year before.
   3. Final SELECT: the change from last year, as a count and a percentage.
 Why:
   - Built from the monthly table, so yearly and monthly figures always agree.
   - Changes use comparable months, so 2025's missing April and May do not
     look like a fall in demand. The full-year total is for reference only.
   - Because the city's gap starts on 31 March 2025, 2025's comparable-month
     totals run slightly low in every group: any 2025 rise is a little
     understated and any 2025 fall a little overstated.
 Techniques: CTE, SUM(CASE), bool_or, LAG(), NULLIF
*/
DROP TABLE IF EXISTS analysis.q1_yearly_totals;
CREATE TABLE analysis.q1_yearly_totals AS
WITH yearly AS (
    SELECT
        year,
        category,
        category_order,
        sum(requests)::bigint AS requests_full_year,
        sum(CASE WHEN extract(month FROM month) IN (4, 5) THEN 0
                 ELSE requests
            END)::bigint AS requests_comparable_months,
        bool_or(data_gap) AS includes_data_gap
    FROM analysis.q1_monthly_volume
    GROUP BY year, category, category_order
),
with_previous_year AS (
    SELECT
        *,
        LAG(requests_comparable_months) OVER (
            PARTITION BY category
            ORDER BY year
        ) AS previous_year_requests_comparable
    FROM yearly
)
SELECT
    year,
    category,
    category_order,
    requests_full_year,
    requests_comparable_months,
    previous_year_requests_comparable,
    requests_comparable_months - previous_year_requests_comparable AS change,
    round((100.0 * (requests_comparable_months - previous_year_requests_comparable)
           / NULLIF(previous_year_requests_comparable, 0))::numeric, 2) AS pct_change,
    includes_data_gap
FROM with_previous_year;


-- ============================================================================
-- Question 2: Which request types take the longest to resolve (median, not just average)
-- ============================================================================

/*
 2a. analysis.q2_resolution_by_type
 Question: Which request types take the city longest to close, and for which
   does the average make the wait look worse than the typical (median) case?
 How it works:
   1. resolution_set: resolved requests used for timing (in_resolution_analysis:
      closed with valid dates; not call-center, crew-logged, booked, duplicate,
      transfer or referral; outside the 2025 gap, 2025-03-31 to 2025-05-31,
      which the city's 2025 file is mostly missing).
   2. open_set: resident field requests (not call-center, crew-logged or a
      duplicate), also not booked, transferred or in the 2025 gap; open ones stay.
   3. type_stats: for each type with 500+ resolved requests: main agency, count,
      median, average and 90th-percentile days, 7-day share, # of division codes.
   4. open_share: the % of each type's open_set requests not closed yet.
   5. Final SELECT: join them, rank slowest first by median, add avg/median ratio.
 Why:
   - Median, not average: a few very slow requests drag the average up.
   - 500-request cutoff: so a handful of unusual requests can't move a median.
   - Booked pickups/events are out: their time is the wait for the booked date.
   - pct_still_open: only closed requests have a time to close, so a type that
     often stays open looks faster than it is; this shows how much is missing.
   - division_code_count > 1 flags types filed under several division codes;
     their median can blend different units (sr_type keeps them apart).
 Techniques: CTE, PERCENTILE_CONT, mode(), CASE, FILTER, HAVING, LEFT JOIN, RANK()
*/

DROP TABLE IF EXISTS analysis.q2_resolution_by_type;
CREATE TABLE analysis.q2_resolution_by_type AS
WITH resolution_set AS (
    SELECT request_type, division_code, agency, resolution_days
    FROM clean.service_requests
    WHERE in_resolution_analysis
),
open_set AS (
    SELECT request_type, status
    FROM clean.service_requests
    WHERE NOT is_call_center
      AND NOT is_crew_logged
      AND NOT is_duplicate
      AND NOT is_scheduled
      AND NOT is_transferred
      AND NOT in_2025_data_gap
),
type_stats AS (
    SELECT
        request_type,
        -- mode() = most common value: the agency that handles most of this type
        mode() WITHIN GROUP (ORDER BY agency)                         AS main_agency,
        count(*)                                                      AS resolved_requests,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY resolution_days)  AS median_days,
        avg(resolution_days)                                          AS avg_days,
        -- 9 in 10 requests close within this many days
        percentile_cont(0.9) WITHIN GROUP (ORDER BY resolution_days)  AS p90_days,
        -- 1 if closed within 7 days (days are stored to 0.01, so 7.00 counts),
        -- else 0, so the average is the share closed within a week.
        avg(CASE WHEN resolution_days <= 7 THEN 1 ELSE 0 END)         AS share_within_7_days,
        count(DISTINCT division_code)                                 AS division_code_count
    FROM resolution_set
    GROUP BY request_type
    HAVING count(*) >= 500
),
open_share AS (
    SELECT
        request_type,
        -- Not closed = New, Open, Pending or Hold. For slow types, some of these
        -- are simply recent rather than stuck.
        100.0 * count(*) FILTER (WHERE status <> 'Closed') / count(*) AS pct_still_open
    FROM open_set
    GROUP BY request_type
)
SELECT
    -- Ranked on the rounded median the table shows: equal medians share a rank
    -- and the next number is skipped.
    RANK() OVER (ORDER BY round(t.median_days::numeric, 2) DESC)      AS rank_slowest,
    t.request_type,
    t.main_agency,
    t.resolved_requests,
    round(t.median_days::numeric, 2)                                  AS median_days,
    round(t.avg_days::numeric, 2)                                     AS avg_days,
    round(t.p90_days::numeric, 2)                                     AS p90_days,
    -- 1 = the average matches the typical request; 10 = ten times the typical
    -- wait. NULLIF turns a median of 0 into NULL instead of dividing by zero.
    round((t.avg_days / NULLIF(t.median_days::numeric, 0))::numeric, 2) AS avg_to_median_ratio,
    round((100 * t.share_within_7_days)::numeric, 2)                  AS pct_closed_within_7_days,
    round(o.pct_still_open::numeric, 2)                               AS pct_still_open,
    t.division_code_count::integer                                    AS division_code_count
FROM type_stats t
LEFT JOIN open_share o ON o.request_type = t.request_type
ORDER BY rank_slowest, t.request_type;


-- ============================================================================
-- Question 3: How resolution times and request rates differ by neighborhood and council district, per capita
-- ============================================================================

/*
 3a. analysis.q3_neighborhoods
 Question: Which neighborhoods make the most requests for their size, and which wait
   longest for them to be closed, even after allowing for the kinds of request?
 How it works:
   1. volume_set: resident field requests (not call-center, crew-logged or a duplicate).
   2. resolution_set: resolved requests used for timing (in_resolution_analysis: closed
      with valid dates; not call-center, crew-logged, booked, duplicate, transfer or
      referral; outside the 2025 gap).
   3. type_medians: the citywide median days to close each request type, 2023-2025.
   4. volume_by_neighborhood: each neighborhood's requests created in 2023-2024.
   5. speed_by_neighborhood: each neighborhood's resolved requests, their median days,
      and the share that closed faster than their own type's median.
   6. combined: the official neighborhood list and 2020 populations, plus steps 4-5.
   7. Final SELECT: applies the cutoffs and ranks the neighborhoods three ways.
 Why:
   - Rates use 2023-2024, the two complete years: 2025 is missing most of April-May.
   - Medians, not averages: a few requests left open for months inflate an average.
   - Type mix: an area that asks for slow types (say, one that usually takes weeks) has
     a slow median even if its crews are fast. pct_faster_than_type_median allows for
     that: about 50% = typical for its mix of requests; lower = slower than typical.
   - Cutoffs: 500 residents (smaller areas give extreme per-capita rates) and 100
     resolved requests (so every median rests on enough requests).
 Techniques: CTE, JOIN, LEFT JOIN, PERCENTILE_CONT, CASE, NULLIF, COALESCE, RANK()
*/
DROP TABLE IF EXISTS analysis.q3_neighborhoods;
CREATE TABLE analysis.q3_neighborhoods AS
WITH volume_set AS (
    SELECT neighborhood, created_at
    FROM clean.service_requests
    WHERE NOT is_call_center
      AND NOT is_crew_logged
      AND NOT is_duplicate
),
resolution_set AS (
    SELECT request_type, neighborhood, resolution_days
    FROM clean.service_requests
    WHERE in_resolution_analysis
),
type_medians AS (
    -- One yardstick for 3a and 3b. If speed changes from year to year, an area's
    -- year mix can nudge its share, so read close ranks as near-ties.
    SELECT
        request_type,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY resolution_days) AS type_median_days
    FROM resolution_set
    GROUP BY request_type
),
volume_by_neighborhood AS (
    SELECT
        neighborhood,
        count(*) AS requests_2023_2024
    FROM volume_set
    WHERE created_at >= DATE '2023-01-01'
      AND created_at <  DATE '2025-01-01'
      AND neighborhood IS NOT NULL
    GROUP BY neighborhood
),
speed_by_neighborhood AS (
    -- All three years: resolution_set already leaves out the 2025 gap.
    SELECT
        r.neighborhood,
        count(*) AS resolved_requests,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY r.resolution_days) AS median_days,
        -- 1 if strictly faster than the type's median (a tie is not faster), else 0;
        -- the average of those 1s and 0s is the share.
        100.0 * avg(CASE WHEN r.resolution_days < t.type_median_days THEN 1 ELSE 0 END)
            AS pct_faster_than_type_median
    FROM resolution_set r
    JOIN type_medians t ON t.request_type = r.request_type
    WHERE r.neighborhood IS NOT NULL
    GROUP BY r.neighborhood
),
combined AS (
    SELECT
        p.neighborhood,
        p.population_2020,
        round(COALESCE(v.requests_2023_2024, 0) / 2.0, 2) AS requests_per_year_2023_2024,
        -- NULLIF: a neighborhood with no residents gives NULL, not a divide-by-zero.
        round(COALESCE(v.requests_2023_2024, 0) / 2.0
              / NULLIF(p.population_2020, 0) * 1000, 2)   AS requests_per_1000_residents,
        COALESCE(s.resolved_requests, 0)                  AS resolved_requests,
        round(s.median_days::numeric, 2)                  AS median_days,
        round(s.pct_faster_than_type_median::numeric, 2)  AS pct_faster_than_type_median
    FROM clean.neighborhood_population p
    LEFT JOIN volume_by_neighborhood v ON v.neighborhood = p.neighborhood
    LEFT JOIN speed_by_neighborhood  s ON s.neighborhood = p.neighborhood
)
SELECT
    neighborhood,
    population_2020,
    requests_per_year_2023_2024,
    requests_per_1000_residents,
    resolved_requests,
    median_days,
    pct_faster_than_type_median,
    -- Rank 1 = most requests, slowest median, lowest share. Ranks use the rounded
    -- figures; RANK() gives equal values the same rank and skips the next one.
    RANK() OVER (ORDER BY requests_per_1000_residents DESC) AS rank_requests_per_1000,
    RANK() OVER (ORDER BY median_days DESC)                 AS rank_median_days,
    RANK() OVER (ORDER BY pct_faster_than_type_median ASC)  AS rank_pct_faster
FROM combined
WHERE population_2020 >= 500
  AND resolved_requests >= 100
ORDER BY rank_requests_per_1000, neighborhood;

-- Check: no missing or out-of-range values, cutoffs applied, every ranking starts at 1.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM analysis.q3_neighborhoods
        WHERE requests_per_1000_residents IS NULL
           OR median_days IS NULL
           OR pct_faster_than_type_median IS NULL
           OR pct_faster_than_type_median NOT BETWEEN 0 AND 100
           OR population_2020 < 500
           OR resolved_requests < 100
    ) THEN
        RAISE EXCEPTION 'analysis.q3_neighborhoods has a missing or out-of-range value';
    END IF;
    IF (SELECT min(rank_requests_per_1000) FROM analysis.q3_neighborhoods) <> 1
       OR (SELECT min(rank_median_days)    FROM analysis.q3_neighborhoods) <> 1
       OR (SELECT min(rank_pct_faster)     FROM analysis.q3_neighborhoods) <> 1 THEN
        RAISE EXCEPTION 'analysis.q3_neighborhoods ranks do not start at 1';
    END IF;
END $$;


/*
 3b. analysis.q3_council_districts_2025
 Question: Do the 14 council districts make requests at the same rate per resident,
   and get them closed at the same speed?
 How it works:
   1. volume_set, resolution_set, type_medians: the same as in 3a.
   2. volume_by_district: each district's 2025 resident field requests, leaving out
      the 2025 gap (2025-03-31 to 2025-05-31, when the city's file is missing most).
   3. speed_by_district: each district's 2025 resolved requests, their median days,
      and the share that closed faster than their own type's median.
   4. combined: the 14 districts and their populations, plus steps 2-3.
   5. Final SELECT: ranks the districts the same three ways as 3a.
 Why:
   - 2025 only: district lines were redrawn between the 2024 and 2025 files, and the
     population table matches the new map. Older years would divide old-map counts
     by new-map populations.
   - The rate covers the 303 days of 2025 outside the gap, not a full year: fair
     between districts (all lose the same days), but not comparable with 3a's rate.
   - The type medians span 2023-2025, so the citywide 2025 share need not be 50%:
     compare districts with each other, not with 50%.
   - No size cutoff: districts are drawn to hold similar numbers of residents.
 Techniques: CTE, JOIN, LEFT JOIN, PERCENTILE_CONT, CASE, NULLIF, COALESCE, RANK()
*/
DROP TABLE IF EXISTS analysis.q3_council_districts_2025;
CREATE TABLE analysis.q3_council_districts_2025 AS
WITH volume_set AS (
    SELECT council_district, created_at, in_2025_data_gap
    FROM clean.service_requests
    WHERE NOT is_call_center
      AND NOT is_crew_logged
      AND NOT is_duplicate
),
resolution_set AS (
    SELECT request_type, council_district, created_at, resolution_days
    FROM clean.service_requests
    WHERE in_resolution_analysis
),
type_medians AS (
    SELECT
        request_type,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY resolution_days) AS type_median_days
    FROM resolution_set
    GROUP BY request_type
),
volume_by_district AS (
    SELECT
        council_district,
        count(*) AS requests_2025_excl_gap
    FROM volume_set
    WHERE created_at >= DATE '2025-01-01'
      AND created_at <  DATE '2026-01-01'
      AND NOT in_2025_data_gap
      AND council_district IS NOT NULL
    GROUP BY council_district
),
speed_by_district AS (
    -- resolution_set already leaves out the 2025 gap.
    SELECT
        r.council_district,
        count(*) AS resolved_requests_2025,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY r.resolution_days) AS median_days,
        100.0 * avg(CASE WHEN r.resolution_days < t.type_median_days THEN 1 ELSE 0 END)
            AS pct_faster_than_type_median
    FROM resolution_set r
    JOIN type_medians t ON t.request_type = r.request_type
    WHERE r.created_at >= DATE '2025-01-01'
      AND r.created_at <  DATE '2026-01-01'
      AND r.council_district IS NOT NULL
    GROUP BY r.council_district
),
combined AS (
    SELECT
        p.council_district,
        p.population_2020,
        COALESCE(v.requests_2025_excl_gap, 0)              AS requests_2025_excl_gap,
        -- ::numeric: dividing two whole numbers would otherwise drop the fraction.
        round(COALESCE(v.requests_2025_excl_gap, 0)::numeric
              / NULLIF(p.population_2020, 0) * 1000, 2)    AS requests_per_1000_residents,
        COALESCE(s.resolved_requests_2025, 0)              AS resolved_requests_2025,
        round(s.median_days::numeric, 2)                   AS median_days,
        round(s.pct_faster_than_type_median::numeric, 2)   AS pct_faster_than_type_median
    FROM clean.council_district_population p
    LEFT JOIN volume_by_district v ON v.council_district = p.council_district
    LEFT JOIN speed_by_district  s ON s.council_district = p.council_district
)
SELECT
    council_district,
    population_2020,
    requests_2025_excl_gap,
    requests_per_1000_residents,
    resolved_requests_2025,
    median_days,
    pct_faster_than_type_median,
    RANK() OVER (ORDER BY requests_per_1000_residents DESC) AS rank_requests_per_1000,
    RANK() OVER (ORDER BY median_days DESC)                 AS rank_median_days,
    RANK() OVER (ORDER BY pct_faster_than_type_median ASC)  AS rank_pct_faster
FROM combined
ORDER BY council_district;

-- Check: all 14 districts present, with no missing or out-of-range values.
DO $$
BEGIN
    IF (SELECT count(*) FROM analysis.q3_council_districts_2025) <> 14 THEN
        RAISE EXCEPTION 'analysis.q3_council_districts_2025 should have 14 rows';
    END IF;
    IF EXISTS (
        SELECT 1 FROM analysis.q3_council_districts_2025
        WHERE requests_per_1000_residents IS NULL
           OR median_days IS NULL
           OR pct_faster_than_type_median IS NULL
           OR pct_faster_than_type_median NOT BETWEEN 0 AND 100
    ) THEN
        RAISE EXCEPTION 'analysis.q3_council_districts_2025 has a missing or out-of-range value';
    END IF;
END $$;


-- ============================================================================
-- Question 4: Seasonal patterns (e.g. potholes in winter and spring)
-- ============================================================================

/*
 4a. analysis.q4_seasonality
 Question: When in the year is each big request type (and potholes) busiest?
 How it works:
   1. calendar: the 36 months of 2023-2025, with April-May 2025 as the gap.
   2. volume_set: resident field requests (not call-center, not crew-logged,
      not a duplicate).
   3. type_totals, ranked_types, chosen_types: size the types on comparable
      months, apply the cutoffs, rank by size, keep ranks 1-10 plus Potholes.
   4. monthly_counts, type_months: count each type per month on the full
      calendar (CROSS JOIN + LEFT JOIN), so an empty month shows 0.
   5. by_calendar_month: drop the gap months, then average each calendar month
      (January, February, ...) over the years left: 3, or 2 for April and May.
   6. indexed: seasonal index = the month's average / the type's average month.
      1.00 = an average month, 1.50 = 50% busier, 0.50 = half as busy.
 Why:
   - Comparable months = every month except April and May, because the city's
     2025 file is missing most of April-May 2025. Types are sized on these
     months only, so the gap cannot change which types are chosen.
   - Cutoffs: 500+ comparable-month requests, 100+ in every year (each is shown).
   - Averages, not totals (April and May have one year fewer), and not medians
     (only 2-3 values). April-May still skip 2025, so 4b checks peaks by year.
 Techniques: CTE, generate_series, date_trunc, extract, to_char, CROSS JOIN,
   LEFT JOIN, COALESCE, FILTER, least(), CASE, AVG() OVER, RANK(), ROW_NUMBER()
*/

DROP TABLE IF EXISTS analysis.q4_seasonality;
CREATE TABLE analysis.q4_seasonality AS
WITH calendar AS (
    -- 31 March 2025 is mostly missing too (March runs a little low), but March
    -- is kept to match the comparable months the other sections use.
    SELECT
        month_start::date                                                AS month_start,
        month_start IN (timestamp '2025-04-01', timestamp '2025-05-01')  AS data_gap
    FROM generate_series(timestamp '2023-01-01', timestamp '2025-12-01', interval '1 month') AS month_start
),
volume_set AS (
    -- Booked pickups and transfers stay in: a resident really made each one.
    SELECT request_type, created_at
    FROM clean.service_requests
    WHERE NOT is_call_center
      AND NOT is_crew_logged
      AND NOT is_duplicate
),
type_totals AS (
    -- count() FILTER returns 0, never NULL, for a year with no requests. That
    -- matters because least() ignores NULLs.
    SELECT
        request_type,
        count(*) AS comparable_requests,
        least(
            count(*) FILTER (WHERE extract(year FROM created_at) = 2023),
            count(*) FILTER (WHERE extract(year FROM created_at) = 2024),
            count(*) FILTER (WHERE extract(year FROM created_at) = 2025)
        )        AS smallest_year_requests
    FROM volume_set
    WHERE extract(month FROM created_at) NOT IN (4, 5)
    GROUP BY request_type
),
ranked_types AS (
    SELECT
        request_type,
        rank() OVER (ORDER BY comparable_requests DESC) AS volume_rank
    FROM type_totals
    WHERE comparable_requests >= 500
      AND smallest_year_requests >= 100
),
chosen_types AS (
    SELECT request_type, volume_rank
    FROM ranked_types
    WHERE volume_rank <= 10
       OR request_type = 'Potholes'
),
monthly_counts AS (
    SELECT
        v.request_type,
        date_trunc('month', v.created_at)::date AS month_start,
        count(*)                                AS requests
    FROM volume_set v
    JOIN chosen_types c ON c.request_type = v.request_type
    GROUP BY v.request_type, date_trunc('month', v.created_at)::date
),
type_months AS (
    SELECT
        c.request_type,
        c.volume_rank,
        cal.month_start,
        cal.data_gap,
        COALESCE(m.requests, 0) AS requests
    FROM chosen_types c
    CROSS JOIN calendar cal
    LEFT JOIN monthly_counts m
           ON m.request_type = c.request_type
          AND m.month_start = cal.month_start
),
by_calendar_month AS (
    -- sum(CASE ...) gives one column per year. The 2025 column is empty for
    -- April and May, which WHERE NOT data_gap leaves out.
    SELECT
        request_type,
        volume_rank,
        extract(month FROM month_start)::integer                               AS calendar_month,
        to_char(month_start, 'FMMonth')                                        AS month_name,
        count(*)                                                               AS years_counted,
        sum(CASE WHEN extract(year FROM month_start) = 2023 THEN requests END) AS requests_2023,
        sum(CASE WHEN extract(year FROM month_start) = 2024 THEN requests END) AS requests_2024,
        sum(CASE WHEN extract(year FROM month_start) = 2025 THEN requests END) AS requests_2025,
        avg(requests)                                                          AS avg_monthly_requests
    FROM type_months
    WHERE NOT data_gap
    GROUP BY request_type, volume_rank, extract(month FROM month_start), to_char(month_start, 'FMMonth')
),
indexed AS (
    SELECT
        b.*,
        b.avg_monthly_requests
            / avg(b.avg_monthly_requests) OVER (PARTITION BY b.request_type) AS seasonal_index
    FROM by_calendar_month b
)
SELECT
    row_number() OVER (ORDER BY volume_rank, calendar_month)  AS sort_order,
    volume_rank::integer                                      AS volume_rank,
    request_type,
    calendar_month,
    month_name,
    years_counted::integer                                    AS years_counted,
    requests_2023::integer                                    AS requests_2023,
    requests_2024::integer                                    AS requests_2024,
    requests_2025::integer                                    AS requests_2025,
    round(avg_monthly_requests::numeric, 2)                   AS avg_monthly_requests,
    round(seasonal_index::numeric, 2)                         AS seasonal_index,
    -- Rank on the exact index, not the rounded one, so near-ties are not merged.
    rank() OVER (PARTITION BY request_type ORDER BY seasonal_index DESC) AS month_rank
FROM indexed
ORDER BY sort_order;


/*
 4b. analysis.q4_season_summary
 Question: For each chosen type, when is it busiest and quietest, how big is
   the swing, how does its year split by season, and does the peak repeat?
 How it works:
   1. monthly: read 4a, rebuild each month's exact average, mark each type's
      quietest rank, and put each month in a season (CASE).
   2. by_year: turn the three year columns into rows (CROSS JOIN LATERAL), then
      rank each year's months by requests (1 = that year's busiest).
   3. peak_check: count the years in which the overall peak month was that
      year's busiest, or in its top 3; list each year's busiest month.
   4. by_type: peak and quietest month(s), the peak-to-low ratio (busiest
      month's average / quietest month's), and each season's share of the year.
   5. Final SELECT: join the check, round, and rank types by the ratio.
 Why:
   - Seasons are meteorological (winter = December, January, February). Shares
     use monthly averages, so April and May weigh as much as the other months.
   - The ratio uses exact averages, not 4a's rounded index (NULLIF avoids / 0).
     It jumps when the quietest month is near 0; season shares are steadier.
   - A 3-year average can be pulled by one odd year, and April and May skip
     2025, so peak_check shows whether the peak repeats in each year.
 Techniques: CTE, CROSS JOIN LATERAL (VALUES), MAX() OVER, RANK() OVER, FILTER,
   count(DISTINCT), string_agg, CASE, NULLIF, JOIN, ROW_NUMBER(), round
*/

DROP TABLE IF EXISTS analysis.q4_season_summary;
CREATE TABLE analysis.q4_season_summary AS
WITH monthly AS (
    SELECT
        s.request_type,
        s.volume_rank,
        s.calendar_month,
        s.month_name,
        s.seasonal_index,
        s.month_rank,
        -- Exact average from the whole-number counts (4a's average is rounded).
        (COALESCE(s.requests_2023, 0) + COALESCE(s.requests_2024, 0) + COALESCE(s.requests_2025, 0))::numeric
            / s.years_counted                                  AS exact_avg,
        -- The worst month_rank; the month(s) holding it are the quietest.
        max(s.month_rank) OVER (PARTITION BY s.request_type)   AS lowest_rank,
        CASE
            WHEN s.calendar_month IN (12, 1, 2) THEN 'winter'
            WHEN s.calendar_month IN (3, 4, 5)  THEN 'spring'
            WHEN s.calendar_month IN (6, 7, 8)  THEN 'summer'
            ELSE 'fall'
        END                                                    AS season
    FROM analysis.q4_seasonality s
),
by_year AS (
    SELECT
        s.request_type,
        s.calendar_month,
        s.month_name,
        s.month_rank,
        y.year,
        rank() OVER (PARTITION BY s.request_type, y.year ORDER BY y.requests DESC) AS rank_in_year
    FROM analysis.q4_seasonality s
    CROSS JOIN LATERAL (
        VALUES (2023, s.requests_2023), (2024, s.requests_2024), (2025, s.requests_2025)
    ) AS y(year, requests)
    -- April and May 2025 have no count (left out in 4a), so they drop out here.
    WHERE y.requests IS NOT NULL
),
peak_check AS (
    -- With a tied peak, a year counts if any of the tied months qualifies.
    SELECT
        request_type,
        count(DISTINCT year) FILTER (WHERE month_rank = 1)                        AS peak_years_counted,
        count(DISTINCT year) FILTER (WHERE month_rank = 1 AND rank_in_year = 1)   AS peak_years_busiest,
        count(DISTINCT year) FILTER (WHERE month_rank = 1 AND rank_in_year <= 3)  AS peak_years_top3,
        string_agg(year || ' ' || month_name, ', ' ORDER BY year, calendar_month)
            FILTER (WHERE rank_in_year = 1)                                       AS busiest_month_by_year
    FROM by_year
    GROUP BY request_type
),
by_type AS (
    SELECT
        request_type,
        min(volume_rank)                                                                             AS volume_rank,
        string_agg(month_name, ', ' ORDER BY calendar_month) FILTER (WHERE month_rank = 1)           AS peak_month,
        max(seasonal_index)                                                                          AS peak_index,
        string_agg(month_name, ', ' ORDER BY calendar_month) FILTER (WHERE month_rank = lowest_rank) AS low_month,
        min(seasonal_index)                                                                          AS low_index,
        max(exact_avg) / NULLIF(min(exact_avg), 0)                                                   AS peak_to_low_ratio,
        sum(exact_avg)                                                                               AS avg_yearly_requests,
        sum(CASE WHEN season = 'winter' THEN exact_avg END) / sum(exact_avg)                         AS share_winter,
        sum(CASE WHEN season = 'spring' THEN exact_avg END) / sum(exact_avg)                         AS share_spring,
        sum(CASE WHEN season = 'summer' THEN exact_avg END) / sum(exact_avg)                         AS share_summer,
        sum(CASE WHEN season = 'fall'   THEN exact_avg END) / sum(exact_avg)                         AS share_fall
    FROM monthly
    GROUP BY request_type
)
SELECT
    -- Ranked on the ratio as shown (2 decimals), so equal ratios share a rank.
    row_number() OVER (ORDER BY round(t.peak_to_low_ratio::numeric, 2) DESC, t.request_type) AS sort_order,
    rank() OVER (ORDER BY round(t.peak_to_low_ratio::numeric, 2) DESC)                     AS seasonality_rank,
    t.volume_rank,
    t.request_type,
    t.peak_month,
    t.peak_index,
    t.low_month,
    t.low_index,
    round(t.peak_to_low_ratio::numeric, 2)    AS peak_to_low_ratio,
    p.peak_years_counted::integer             AS peak_years_counted,
    p.peak_years_busiest::integer             AS peak_years_busiest,
    p.peak_years_top3::integer                AS peak_years_top3,
    p.busiest_month_by_year,
    round(t.avg_yearly_requests::numeric, 2)  AS avg_yearly_requests,
    round((100 * t.share_winter)::numeric, 2) AS pct_winter,
    round((100 * t.share_spring)::numeric, 2) AS pct_spring,
    round((100 * t.share_summer)::numeric, 2) AS pct_summer,
    round((100 * t.share_fall)::numeric, 2)   AS pct_fall
FROM by_type t
JOIN peak_check p ON p.request_type = t.request_type
ORDER BY sort_order;


-- ============================================================================
-- Question 5: What share of requests are still open, or took unusually long (beyond the 90th percentile)
-- ============================================================================

/*
 5a. analysis.q5_open_and_long_by_year
 Question: Each year, what share of requests is still open, and is the share
   taking unusually long to close growing?
 How it works:
   1. open_set, open_by_year: resident field requests (not call-center, crew-logged
      or a duplicate) minus booked pickups, transfers and the 2025 gap (2025-03-31
      to 2025-05-31, mostly missing from the city's file); count those not Closed.
   2. resolution_set: resolved requests used for timing (in_resolution_analysis:
      closed with valid dates; not call-center, crew-logged, booked, duplicate,
      transfer or referral; outside the 2025 gap).
   3. baseline_2023: for each type with 100+ closed requests in 2023, its 2023
      90th percentile of days to close: where that type's slowest 10% began.
   4. labelled, long_by_year, combined: CASE labels a request Long if it took
      longer than its type's 2023 bar; then shares per year, change since 2023.
 Why:
   - Bar fixed at 2023 so the share can move (a bar redone yearly always gives
     about 10%). 2023 lands near 10% by definition: compare with 2023, not 10%.
   - One bar per type, so each request is judged against its own kind and a shift
     in the type mix cannot move the share; 100+ requests keep each bar stable.
   - Percentiles, not averages: a few very slow requests distort an average.
   - "Still open" is a snapshot from each year's last file update (2025 had the
     least time to close). 2025 counts cover about 10 months: compare shares.
 Techniques: CTE, PERCENTILE_CONT, HAVING, CASE, LEFT JOIN, FILTER, FIRST_VALUE()
*/

DROP TABLE IF EXISTS analysis.q5_open_and_long_by_year;
CREATE TABLE analysis.q5_open_and_long_by_year AS
WITH open_set AS (
    SELECT
        extract(year FROM created_at)::integer AS year,
        status
    FROM clean.service_requests
    WHERE NOT is_call_center
      AND NOT is_crew_logged
      AND NOT is_duplicate
      -- Booked pickups stay open until their date; transfers move to another number.
      AND NOT is_scheduled
      AND NOT is_transferred
      AND NOT in_2025_data_gap
),
open_by_year AS (
    SELECT
        year,
        count(*)                                   AS open_set_requests,
        count(*) FILTER (WHERE status <> 'Closed') AS still_open
    FROM open_set
    GROUP BY year
),
resolution_set AS (
    SELECT
        extract(year FROM created_at)::integer AS year,
        request_type,
        resolution_days
    FROM clean.service_requests
    WHERE in_resolution_analysis
),
baseline_2023 AS (
    -- Days have 2 decimals and percentile_cont steps in tenths of a gap, so the true
    -- bar has at most 3; round(..., 3) strips float error so the strict '>' is exact.
    SELECT
        request_type,
        round(percentile_cont(0.9) WITHIN GROUP (ORDER BY resolution_days)::numeric, 3)
                                                     AS p90_days_2023
    FROM resolution_set
    WHERE year = 2023
    GROUP BY request_type
    HAVING count(*) >= 100
),
labelled AS (
    -- LEFT JOIN keeps types with no 2023 bar (p90_days_2023 is NULL); they are
    -- counted in excluded_no_baseline and left out of pct_long.
    SELECT
        r.year,
        CASE
            WHEN b.p90_days_2023 IS NULL             THEN 'No 2023 baseline'
            WHEN r.resolution_days > b.p90_days_2023 THEN 'Long'
            ELSE 'Within the 2023 bar'
        END AS speed_group
    FROM resolution_set r
    LEFT JOIN baseline_2023 b ON b.request_type = r.request_type
),
long_by_year AS (
    SELECT
        year,
        count(*)                                                    AS resolved_requests,
        count(*) FILTER (WHERE speed_group = 'No 2023 baseline')    AS excluded_no_baseline,
        count(*) FILTER (WHERE speed_group <> 'No 2023 baseline')   AS resolved_with_baseline,
        count(*) FILTER (WHERE speed_group = 'Long')                AS long_requests
    FROM labelled
    GROUP BY year
),
combined AS (
    SELECT
        o.year,
        o.open_set_requests,
        o.still_open,
        100.0 * o.still_open / NULLIF(o.open_set_requests, 0)         AS pct_still_open,
        l.resolved_requests,
        l.excluded_no_baseline,
        l.resolved_with_baseline,
        l.long_requests,
        -- Closed requests only: one still open past its bar is not counted here.
        100.0 * l.long_requests / NULLIF(l.resolved_with_baseline, 0) AS pct_long
    FROM open_by_year o
    JOIN long_by_year l ON l.year = o.year
)
SELECT
    ROW_NUMBER() OVER (ORDER BY year)                    AS sort_order,
    year,
    open_set_requests,
    still_open,
    round(pct_still_open::numeric, 2)                    AS pct_still_open,
    resolved_requests,
    excluded_no_baseline,
    resolved_with_baseline,
    long_requests,
    round(pct_long::numeric, 2)                          AS pct_long,
    -- FIRST_VALUE is 2023's share (the first year). Using unrounded shares, this can
    -- differ by 0.01 from subtracting the two rounded pct_long values.
    round((pct_long - FIRST_VALUE(pct_long) OVER (ORDER BY year))::numeric, 2)
                                                         AS pct_long_points_vs_2023
FROM combined
ORDER BY year;


/*
 5b. analysis.q5_long_tail_by_type
 Question: Which request types make up the long tail (closed requests slower than
   the citywide 90th percentile)? Is it spread out, or do a few types dominate?
 How it works:
   1. resolution_set: resolved requests used for timing, 2023-2025 together.
   2. citywide_bar: one citywide 90th percentile of days to close, roughly where
      the slowest 10% of all these requests begin.
   3. by_type: per request type, its closed requests and how many took longer than it.
   4. grouped: CASE pools types with fewer than 500 closed requests into one
      "All other types" row; types_in_row says how many types each row holds.
   5. with_total: SUM() OVER () puts the total of long requests on every row.
   6. Final SELECT: each row's share of the long tail, a running total of those
      shares from the biggest down, and a RANK() of the types.
 Why:
   - One citywide bar, not one per type as in 5a: the question is where the
     city's slowest requests come from, not whether each type got slower.
   - A type needs 500+ closed requests over 2023-2025 for a row of its own.
     Pooling the rest (not dropping them) keeps every long request in the total.
   - The pooled row has no rank and sorts last, so the running total ends at 100%.
   - Ties: the running total breaks them by request_type so the order never
     changes; RANK gives tied types the same rank and then skips (1, 2, 2, 4).
 Techniques: CTE, PERCENTILE_CONT, CROSS JOIN, CASE, GROUP BY position, FILTER,
   SUM() OVER () (grand total), SUM() OVER (running total), RANK(), ROW_NUMBER()
*/

DROP TABLE IF EXISTS analysis.q5_long_tail_by_type;
CREATE TABLE analysis.q5_long_tail_by_type AS
WITH resolution_set AS (
    SELECT request_type, resolution_days
    FROM clean.service_requests
    WHERE in_resolution_analysis
),
citywide_bar AS (
    -- Rounded to 3 decimals so the strict '>' is exact (see 5a).
    SELECT round(percentile_cont(0.9) WITHIN GROUP (ORDER BY resolution_days)::numeric, 3)
               AS p90_days
    FROM resolution_set
),
by_type AS (
    -- citywide_bar is one row, so CROSS JOIN just attaches the bar to every request.
    SELECT
        r.request_type,
        count(*)                                              AS total_resolved,
        count(*) FILTER (WHERE r.resolution_days > c.p90_days) AS long_requests
    FROM resolution_set r
    CROSS JOIN citywide_bar c
    GROUP BY r.request_type
),
grouped AS (
    SELECT
        CASE WHEN total_resolved >= 500 THEN request_type
             ELSE 'All other types (fewer than 500 closed requests each)'
        END                        AS request_type,
        total_resolved < 500       AS is_pooled_row,
        count(*)                   AS types_in_row,
        sum(long_requests)         AS long_requests,
        sum(total_resolved)        AS total_resolved
    FROM by_type
    -- By position, so it groups on the CASE result: in PostgreSQL a plain
    -- GROUP BY request_type means the input column, and small types would not pool.
    GROUP BY 1, 2
),
with_total AS (
    SELECT
        g.*,
        sum(long_requests) OVER () AS all_long_requests
    FROM grouped g
)
SELECT
    -- The table keeps no row order, so read it with ORDER BY sort_order.
    ROW_NUMBER() OVER (ORDER BY is_pooled_row, long_requests DESC, request_type) AS sort_order,
    -- Rank the real types only; the pooled row gets no rank.
    CASE WHEN NOT is_pooled_row
         THEN RANK() OVER (PARTITION BY is_pooled_row ORDER BY long_requests DESC)
    END                                                          AS long_tail_rank,
    request_type,
    is_pooled_row,
    types_in_row,
    long_requests::bigint                                        AS long_requests,
    total_resolved::bigint                                       AS total_resolved,
    round(100.0 * long_requests / total_resolved, 2)             AS pct_of_type_long,
    round(100.0 * long_requests / all_long_requests, 2)          AS share_of_all_long,
    round(100.0 * sum(long_requests) OVER (
              ORDER BY is_pooled_row, long_requests DESC, request_type
              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
          ) / all_long_requests, 2)                              AS cumulative_share_of_all_long,
    (SELECT round(p90_days, 2) FROM citywide_bar)                AS citywide_p90_days
FROM with_total
ORDER BY sort_order;


-- ============================================================================
-- Question 6: Have resolution times improved or worsened over time
-- ============================================================================

/*
 6a. analysis.q6_monthly_trend
 Question: Month by month, is the city closing requests faster or slower?
 How it works:
   1. resolution_set: the resolved requests used for timing (closed with valid
      dates; not call-center, crew-logged, booked, a duplicate, a transfer or
      a referral; outside the 2025 gap).
   2. type_median: each request type's median days to close over 2023-2025.
   3. calendar, monthly, spine: per month created (all 36, kept by LEFT JOIN):
      median, 90th percentile, % within 7 days, % faster than the type median.
   4. volume_set, open_set, open_monthly: % still open among resident field
      requests (not call-center, crew-logged or a duplicate), leaving out
      booked pickups, transfers and the 2025 gap.
   5. Final SELECT: LAG(12) = the same month last year; 3-month moving average.
 Why:
   - Medians, not averages: a few requests that take months drag an average up.
   - Faster than its type's median: each request is judged against its own
     type, so it moves far less than a pooled median when the mix changes.
   - Still open: unclosed recent requests would make late 2025 look too fast.
   - 2025 gap: the city's 2025 file is missing most requests from 2025-03-31
     to 2025-05-31. The moving average is blank unless all 3 months have a
     median, so the line breaks across the gap instead of drawing through it.
 Techniques: CTE, generate_series, date_trunc, LEFT JOIN, PERCENTILE_CONT,
   FILTER, COALESCE, LAG(), AVG() OVER (moving average), CASE
*/
DROP TABLE IF EXISTS analysis.q6_monthly_trend;
CREATE TABLE analysis.q6_monthly_trend AS
WITH resolution_set AS (
    SELECT request_type, created_at, resolution_days
    FROM clean.service_requests
    WHERE in_resolution_analysis
),
type_median AS (
    SELECT request_type,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY resolution_days) AS type_median_days
    FROM resolution_set
    GROUP BY request_type
),
calendar AS (
    SELECT generate_series(date '2023-01-01', date '2025-12-01', interval '1 month')::date AS month
),
monthly AS (
    SELECT
        date_trunc('month', r.created_at)::date AS month,
        count(*) AS resolved_requests,
        round(percentile_cont(0.5) WITHIN GROUP (ORDER BY r.resolution_days)::numeric, 2) AS median_days,
        round(percentile_cont(0.9) WITHIN GROUP (ORDER BY r.resolution_days)::numeric, 2) AS p90_days,
        round(100.0 * count(*) FILTER (WHERE r.resolution_days <= 7) / count(*), 2) AS pct_closed_within_7_days,
        -- Strictly faster: taking exactly the type's median does not count.
        round(100.0 * count(*) FILTER (WHERE r.resolution_days < t.type_median_days) / count(*), 2)
            AS pct_faster_than_type_median
    FROM resolution_set r
    JOIN type_median t ON t.request_type = r.request_type
    GROUP BY date_trunc('month', r.created_at)::date
),
volume_set AS (
    SELECT created_at, status, is_scheduled, is_transferred, in_2025_data_gap
    FROM clean.service_requests
    WHERE NOT is_call_center AND NOT is_crew_logged AND NOT is_duplicate
),
open_set AS (
    SELECT created_at, status
    FROM volume_set
    WHERE NOT is_scheduled AND NOT is_transferred AND NOT in_2025_data_gap
),
open_monthly AS (
    SELECT
        date_trunc('month', created_at)::date AS month,
        round(100.0 * count(*) FILTER (WHERE status <> 'Closed') / count(*), 2) AS pct_still_open
    FROM open_set
    GROUP BY date_trunc('month', created_at)::date
),
spine AS (
    SELECT
        c.month,
        extract(year FROM c.month)::integer AS year,
        COALESCE(m.resolved_requests, 0) AS resolved_requests,
        m.median_days,
        m.p90_days,
        m.pct_closed_within_7_days,
        m.pct_faster_than_type_median,
        o.pct_still_open,
        -- April and May 2025: the city's file is missing most requests.
        (extract(year FROM c.month) = 2025 AND extract(month FROM c.month) IN (4, 5)) AS data_gap
    FROM calendar c
    LEFT JOIN monthly m ON m.month = c.month
    LEFT JOIN open_monthly o ON o.month = c.month
)
SELECT
    month,
    year,
    resolved_requests,
    median_days,
    p90_days,
    pct_closed_within_7_days,
    -- 12 rows back on a complete monthly calendar = the same month last year.
    lag(median_days, 12) OVER (ORDER BY month) AS median_days_same_month_last_year,
    median_days - lag(median_days, 12) OVER (ORDER BY month) AS change_vs_last_year,
    CASE WHEN count(median_days) OVER last_3_months = 3
         THEN round(avg(median_days) OVER last_3_months, 2)
    END AS moving_avg_3_month_median,
    pct_faster_than_type_median,
    pct_still_open,
    data_gap
FROM spine
WINDOW last_3_months AS (ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
ORDER BY month;


/*
 6b. analysis.q6_yearly_trend
 Question: Year by year, did the city close requests faster or slower, and is
   the change real or only a change in the kinds of request it received?
 How it works:
   1. resolution_set, type_median: as in 6a, plus the year and month created.
   2. yearly: per year, the median, average and 90th-percentile days, % closed
      within 7 days and % faster than their type's median; then the median and
      the 7-day share again on comparable months only.
   3. volume_set, open_set, open_share: per year, the count and share still
      open (the same requests as in 6a).
   4. Final SELECT: LAG() gives the change from the year before.
 Why:
   - Comparable months: every month except April and May, in every year,
     because the city's 2025 file is missing most of April-May 2025. All three
     years then cover the same 10 months, the fairer year-to-year comparison.
   - Median, average and 90th percentile side by side: the typical request,
     the pull of the slow tail, and how slow the slow end is.
   - % faster than type median is the type-mix check: a pooled median can move
     only because the mix of request types changed; this share moves far less.
   - Changes use the rounded figures shown, so they add up by hand; the 7-day
     change is in percentage points.
 Techniques: CTE, extract, JOIN, PERCENTILE_CONT with FILTER (comparable-months
   median), AVG(), LAG()
*/
DROP TABLE IF EXISTS analysis.q6_yearly_trend;
CREATE TABLE analysis.q6_yearly_trend AS
WITH resolution_set AS (
    SELECT request_type, resolution_days,
           extract(year FROM created_at)::integer AS year,
           extract(month FROM created_at)::integer AS month
    FROM clean.service_requests
    WHERE in_resolution_analysis
),
type_median AS (
    SELECT request_type,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY resolution_days) AS type_median_days
    FROM resolution_set
    GROUP BY request_type
),
yearly AS (
    SELECT
        r.year,
        count(*) AS resolved_requests,
        round(percentile_cont(0.5) WITHIN GROUP (ORDER BY r.resolution_days)::numeric, 2) AS median_days,
        round(avg(r.resolution_days), 2) AS avg_days,
        round(percentile_cont(0.9) WITHIN GROUP (ORDER BY r.resolution_days)::numeric, 2) AS p90_days,
        round(100.0 * count(*) FILTER (WHERE r.resolution_days <= 7) / count(*), 2) AS pct_closed_within_7_days,
        round(100.0 * count(*) FILTER (WHERE r.resolution_days < t.type_median_days) / count(*), 2)
            AS pct_faster_than_type_median,
        round((percentile_cont(0.5) WITHIN GROUP (ORDER BY r.resolution_days)
               FILTER (WHERE r.month NOT IN (4, 5)))::numeric, 2)
            AS median_days_comparable_months,
        round(100.0 * count(*) FILTER (WHERE r.resolution_days <= 7 AND r.month NOT IN (4, 5))
                    / count(*) FILTER (WHERE r.month NOT IN (4, 5)), 2)
            AS pct_within_7_days_comparable_months
    FROM resolution_set r
    JOIN type_median t ON t.request_type = r.request_type
    GROUP BY r.year
),
volume_set AS (
    SELECT created_at, status, is_scheduled, is_transferred, in_2025_data_gap
    FROM clean.service_requests
    WHERE NOT is_call_center AND NOT is_crew_logged AND NOT is_duplicate
),
open_set AS (
    SELECT created_at, status
    FROM volume_set
    WHERE NOT is_scheduled AND NOT is_transferred AND NOT in_2025_data_gap
),
open_share AS (
    SELECT
        extract(year FROM created_at)::integer AS year,
        count(*) AS open_set_requests,
        count(*) FILTER (WHERE status <> 'Closed') AS still_open_requests
    FROM open_set
    GROUP BY extract(year FROM created_at)::integer
)
SELECT
    y.year,
    y.resolved_requests,
    y.median_days,
    y.avg_days,
    y.p90_days,
    y.pct_closed_within_7_days,
    y.median_days - lag(y.median_days) OVER (ORDER BY y.year) AS median_days_change_vs_prev_year,
    y.pct_closed_within_7_days - lag(y.pct_closed_within_7_days) OVER (ORDER BY y.year)
        AS pct_within_7_days_change_vs_prev_year,
    y.pct_faster_than_type_median,
    y.median_days_comparable_months,
    y.pct_within_7_days_comparable_months,
    o.open_set_requests,
    o.still_open_requests,
    round(100.0 * o.still_open_requests / o.open_set_requests, 2) AS pct_still_open
FROM yearly y
JOIN open_share o ON o.year = y.year
ORDER BY y.year;


/*
 6c. analysis.q6_type_trend
 Question: Did each of the city's biggest request types get faster or slower?
 How it works:
   1. resolution_set: resolved requests used for timing, with year and month.
   2. type_year: per type and year, the count, median days, share of all that
      year's resolved requests, and the count and median on comparable months.
   3. eligible_types, top_types: types with at least 500 resolved requests in
      every year, ranked by total (ROW_NUMBER, ties by name); keep the top 10.
   4. with_previous, changes: LAG() fetches last year's median, FIRST_VALUE()
      the 2023 one; change in days and % (comparable months: % only).
   5. Final SELECT: CASE labels each change 'Faster' (below -5%), 'Slower'
      (above +5%) or 'About the same'.
 Why:
   - Pooled medians move when the mix of request types changes, even if no
     type got faster. Following one type at a time compares like with like.
   - At least 500 a year, so every yearly median rests on plenty of requests.
   - The +/-5% band stops tiny wobbles being called a trend. Percent is
     relative: a few hours is a big % for a fast type, so check change_days.
   - Comparable months matter for seasonal types such as HGW (a Solid Waste
     request type whose letters the data never spells out; it peaks in
     summer): 2025's full year has no April or May, 2023 and 2024 do.
 Techniques: CTE, PERCENTILE_CONT, FILTER, HAVING, SUM() OVER, ROW_NUMBER(),
   LAG(), FIRST_VALUE(), JOIN, CASE, NULLIF
*/
DROP TABLE IF EXISTS analysis.q6_type_trend;
CREATE TABLE analysis.q6_type_trend AS
WITH resolution_set AS (
    SELECT request_type, resolution_days,
           extract(year FROM created_at)::integer AS year,
           extract(month FROM created_at)::integer AS month
    FROM clean.service_requests
    WHERE in_resolution_analysis
),
type_year AS (
    SELECT
        request_type,
        year,
        count(*) AS resolved_requests,
        round(percentile_cont(0.5) WITHIN GROUP (ORDER BY resolution_days)::numeric, 2) AS median_days,
        -- This type's share of every resolved request that year (all types).
        round(100.0 * count(*) / sum(count(*)) OVER (PARTITION BY year), 2) AS pct_of_year_resolved,
        count(*) FILTER (WHERE month NOT IN (4, 5)) AS resolved_requests_comparable_months,
        round((percentile_cont(0.5) WITHIN GROUP (ORDER BY resolution_days)
               FILTER (WHERE month NOT IN (4, 5)))::numeric, 2) AS median_days_comparable_months
    FROM resolution_set
    GROUP BY request_type, year
),
eligible_types AS (
    -- At least 500 resolved requests in each of the three years.
    SELECT request_type, sum(resolved_requests) AS total_resolved
    FROM type_year
    GROUP BY request_type
    HAVING count(*) FILTER (WHERE resolved_requests >= 500) = 3
),
top_types AS (
    SELECT
        request_type,
        total_resolved,
        row_number() OVER (ORDER BY total_resolved DESC, request_type) AS type_rank
    FROM eligible_types
),
with_previous AS (
    SELECT
        t.type_rank,
        y.request_type,
        y.year,
        y.resolved_requests,
        y.pct_of_year_resolved,
        y.median_days,
        lag(y.median_days) OVER type_years AS previous_year_median,
        first_value(y.median_days) OVER type_years AS median_2023,
        y.resolved_requests_comparable_months,
        y.median_days_comparable_months,
        lag(y.median_days_comparable_months) OVER type_years AS previous_year_median_comparable,
        first_value(y.median_days_comparable_months) OVER type_years AS median_2023_comparable
    FROM type_year y
    JOIN top_types t ON t.request_type = y.request_type
    WHERE t.type_rank <= 10
    WINDOW type_years AS (PARTITION BY y.request_type ORDER BY y.year)
),
changes AS (
    SELECT
        *,
        median_days - previous_year_median AS change_days,
        round(100 * (median_days - previous_year_median) / NULLIF(previous_year_median, 0), 2) AS pct_change,
        CASE WHEN year > 2023 THEN median_days - median_2023 END AS change_vs_2023_days,
        CASE WHEN year > 2023
             THEN round(100 * (median_days - median_2023) / NULLIF(median_2023, 0), 2)
        END AS pct_change_vs_2023,
        round(100 * (median_days_comparable_months - previous_year_median_comparable)
                  / NULLIF(previous_year_median_comparable, 0), 2) AS pct_change_comparable_months,
        CASE WHEN year > 2023
             THEN round(100 * (median_days_comparable_months - median_2023_comparable)
                            / NULLIF(median_2023_comparable, 0), 2)
        END AS pct_change_vs_2023_comparable_months
    FROM with_previous
)
SELECT
    type_rank,
    request_type,
    year,
    resolved_requests,
    pct_of_year_resolved,
    median_days,
    previous_year_median,
    change_days,
    pct_change,
    CASE
        WHEN pct_change IS NULL THEN NULL          -- 2023: no previous year
        WHEN pct_change < -5    THEN 'Faster'
        WHEN pct_change >  5    THEN 'Slower'
        ELSE 'About the same'
    END AS direction,
    median_2023,
    change_vs_2023_days,
    pct_change_vs_2023,
    CASE
        WHEN pct_change_vs_2023 IS NULL THEN NULL  -- 2023 itself
        WHEN pct_change_vs_2023 < -5    THEN 'Faster'
        WHEN pct_change_vs_2023 >  5    THEN 'Slower'
        ELSE 'About the same'
    END AS direction_vs_2023,
    resolved_requests_comparable_months,
    median_days_comparable_months,
    pct_change_comparable_months,
    CASE
        WHEN pct_change_comparable_months IS NULL THEN NULL
        WHEN pct_change_comparable_months < -5    THEN 'Faster'
        WHEN pct_change_comparable_months >  5    THEN 'Slower'
        ELSE 'About the same'
    END AS direction_comparable_months,
    pct_change_vs_2023_comparable_months,
    CASE
        WHEN pct_change_vs_2023_comparable_months IS NULL THEN NULL
        WHEN pct_change_vs_2023_comparable_months < -5    THEN 'Faster'
        WHEN pct_change_vs_2023_comparable_months >  5    THEN 'Slower'
        ELSE 'About the same'
    END AS direction_vs_2023_comparable_months
FROM changes
ORDER BY type_rank, year;


/*
 6d. analysis.q6_mix_adjusted_median
 Question: With the same mix of request types, which year would be faster?
 How it works:
   1. resolution_set, type_share: comparable months only; each type's share of
      its year's resolved requests.
   2. weights: for every pair of years (measured, borrowed), each type's weight
      is its share in the borrowed year / its share in the measured year, so
      the measured year takes on the borrowed year's mix.
   3. weighted_days, running_weight, weighted_median: total the weight at each
      number of days, keep a running total in order of days, and take the first
      number of days where it reaches half the total weight.
   4. actual, final SELECT: the ordinary median beside it, 3 x 3 = 9 rows.
 Why:
   - Pooled medians move when the mix of types changes. This separates a real
     change in speed from a change in what residents asked for: compare "2025
     requests with 2024's mix" with 2024's actual median.
   - PERCENTILE_CONT takes no weights, hence the running total. Same-year rows
     weight every request 1, so they match the ordinary median to 0.01 days.
   - Comparable months, so every year's mix covers the same 10 months.
   - A type missing from the borrowed year gets no weight;
     pct_requests_with_type_in_mix_year shows how many requests are kept.
 Techniques: CTE, self-JOIN, SUM() OVER (type shares, running total), FILTER,
   PERCENTILE_CONT, ROW_NUMBER()
*/
DROP TABLE IF EXISTS analysis.q6_mix_adjusted_median;
CREATE TABLE analysis.q6_mix_adjusted_median AS
WITH resolution_set AS (
    SELECT request_type, resolution_days,
           extract(year FROM created_at)::integer AS year
    FROM clean.service_requests
    WHERE in_resolution_analysis
      AND extract(month FROM created_at) NOT IN (4, 5)
),
type_share AS (
    SELECT
        year,
        request_type,
        count(*)::numeric / sum(count(*)) OVER (PARTITION BY year) AS share
    FROM resolution_set
    GROUP BY year, request_type
),
weights AS (
    SELECT
        measured.year AS requests_from_year,
        borrowed.year AS type_mix_of_year,
        measured.request_type,
        borrowed.share / measured.share AS weight
    FROM type_share measured
    JOIN type_share borrowed ON borrowed.request_type = measured.request_type
),
weighted_days AS (
    SELECT
        w.requests_from_year,
        w.type_mix_of_year,
        r.resolution_days,
        count(*) AS requests,
        sum(w.weight) AS weight
    FROM resolution_set r
    JOIN weights w ON w.requests_from_year = r.year AND w.request_type = r.request_type
    GROUP BY w.requests_from_year, w.type_mix_of_year, r.resolution_days
),
running_weight AS (
    SELECT
        requests_from_year,
        type_mix_of_year,
        resolution_days,
        requests,
        sum(weight) OVER (PARTITION BY requests_from_year, type_mix_of_year
                          ORDER BY resolution_days) AS running_weight,
        sum(weight) OVER (PARTITION BY requests_from_year, type_mix_of_year) AS total_weight
    FROM weighted_days
),
weighted_median AS (
    SELECT
        requests_from_year,
        type_mix_of_year,
        sum(requests) AS requests_used,
        -- First number of days at which half of the weight has been reached.
        min(resolution_days) FILTER (WHERE running_weight >= total_weight / 2) AS weighted_median_days
    FROM running_weight
    GROUP BY requests_from_year, type_mix_of_year
),
actual AS (
    SELECT
        year,
        count(*) AS resolved_requests,
        round(percentile_cont(0.5) WITHIN GROUP (ORDER BY resolution_days)::numeric, 2) AS median_days
    FROM resolution_set
    GROUP BY year
)
SELECT
    row_number() OVER (ORDER BY m.requests_from_year, m.type_mix_of_year) AS sort_order,
    m.requests_from_year,
    m.type_mix_of_year,
    a.resolved_requests,
    round(100.0 * m.requests_used / a.resolved_requests, 2) AS pct_requests_with_type_in_mix_year,
    a.median_days AS actual_median_days,
    round(m.weighted_median_days, 2) AS mix_adjusted_median_days,
    round(m.weighted_median_days, 2) - a.median_days AS difference_days
FROM weighted_median m
JOIN actual a ON a.year = m.requests_from_year
ORDER BY sort_order;


-- Checks: row counts, at least 100 requests per 6c median, 6d same-year rows match.
DO $$
BEGIN
    IF (SELECT count(*) FROM analysis.q6_monthly_trend) <> 36 THEN
        RAISE EXCEPTION 'q6_monthly_trend should have 36 months';
    END IF;
    IF (SELECT count(*) FROM analysis.q6_monthly_trend WHERE data_gap) <> 2 THEN
        RAISE EXCEPTION 'q6_monthly_trend should flag exactly 2 data-gap months';
    END IF;
    IF (SELECT count(*) FROM analysis.q6_yearly_trend) <> 3 THEN
        RAISE EXCEPTION 'q6_yearly_trend should have 3 years';
    END IF;
    IF (SELECT count(*) FROM analysis.q6_type_trend) <> 30
       OR (SELECT count(DISTINCT type_rank) FROM analysis.q6_type_trend) <> 10 THEN
        RAISE EXCEPTION 'q6_type_trend should have 10 types x 3 years';
    END IF;
    IF (SELECT min(resolved_requests_comparable_months) FROM analysis.q6_type_trend) < 100 THEN
        RAISE EXCEPTION 'q6_type_trend: a comparable-months median rests on fewer than 100 requests';
    END IF;
    IF (SELECT count(*) FROM analysis.q6_mix_adjusted_median) <> 9 THEN
        RAISE EXCEPTION 'q6_mix_adjusted_median should have 3 x 3 rows';
    END IF;
    -- Same-year rows weight every request 1, so they must match the ordinary median.
    IF EXISTS (SELECT 1 FROM analysis.q6_mix_adjusted_median
               WHERE requests_from_year = type_mix_of_year AND abs(difference_days) > 0.01) THEN
        RAISE EXCEPTION 'q6_mix_adjusted_median: same-year weighted median differs from the ordinary median';
    END IF;
END $$;


