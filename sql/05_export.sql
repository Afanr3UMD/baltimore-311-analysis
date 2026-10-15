/*
 05_export.sql
 Saves the 14 result tables built by sql/04_analysis.sql as CSV files in
 outputs/, one file per table with the same name, ready to open in Tableau.
 outputs/README.md explains each file and suggests a chart for it.

 Run from the project folder, after sql/04_analysis.sql (the file paths below
 are relative to the folder psql runs in):
   psql -d baltimore_311 -f sql/05_export.sql

 How each export works
   COPY (query) TO STDOUT sends the query's rows to psql, and \g writes them
   to a file on this computer. It does the same as \copy, but \copy has to fit
   on one line, while this form lets each query span several lines.
   - HEADER true: the first line holds the column names.
   - ORDER BY: a table has no built-in row order, so every file sets one.
   - A blank cell means no value (NULL), e.g. no change in the first year.
   - Yes/no columns are written as true/false (PostgreSQL would write t/f),
     which Tableau reads as a True/False field.
*/

\set ON_ERROR_STOP on

-- Dates as 2025-01-01, whatever the database's default date style is.
SET datestyle = 'ISO';


-- Question 1: most common request types, and volume by month and year

COPY (
    SELECT year, rank, request_type, requests_comparable_months, requests_full_year,
           previous_year_requests_comparable, change, pct_change,
           includes_data_gap::text AS includes_data_gap
    FROM analysis.q1_top_request_types
    ORDER BY year, rank, request_type
) TO STDOUT WITH (FORMAT csv, HEADER true) \g outputs/q1_top_request_types.csv

COPY (
    SELECT month, year, category, category_order, requests, running_total_in_year,
           same_month_last_year, pct_change_vs_last_year,
           data_gap::text AS data_gap
    FROM analysis.q1_monthly_volume
    ORDER BY month, category_order
) TO STDOUT WITH (FORMAT csv, HEADER true) \g outputs/q1_monthly_volume.csv

COPY (
    SELECT year, category, category_order, requests_full_year, requests_comparable_months,
           previous_year_requests_comparable, change, pct_change,
           includes_data_gap::text AS includes_data_gap
    FROM analysis.q1_yearly_totals
    ORDER BY category_order, year
) TO STDOUT WITH (FORMAT csv, HEADER true) \g outputs/q1_yearly_totals.csv


-- Question 2: which request types take the longest to close

COPY (
    SELECT *
    FROM analysis.q2_resolution_by_type
    ORDER BY rank_slowest, request_type
) TO STDOUT WITH (FORMAT csv, HEADER true) \g outputs/q2_resolution_by_type.csv


-- Question 3: neighborhoods and council districts, per resident

COPY (
    SELECT *
    FROM analysis.q3_neighborhoods
    ORDER BY rank_requests_per_1000, neighborhood
) TO STDOUT WITH (FORMAT csv, HEADER true) \g outputs/q3_neighborhoods.csv

COPY (
    SELECT *
    FROM analysis.q3_council_districts_2025
    ORDER BY council_district
) TO STDOUT WITH (FORMAT csv, HEADER true) \g outputs/q3_council_districts_2025.csv


-- Question 4: seasonal patterns

COPY (
    SELECT *
    FROM analysis.q4_seasonality
    ORDER BY sort_order
) TO STDOUT WITH (FORMAT csv, HEADER true) \g outputs/q4_seasonality.csv

COPY (
    SELECT *
    FROM analysis.q4_season_summary
    ORDER BY sort_order
) TO STDOUT WITH (FORMAT csv, HEADER true) \g outputs/q4_season_summary.csv


-- Question 5: still open, or unusually long

COPY (
    SELECT *
    FROM analysis.q5_open_and_long_by_year
    ORDER BY sort_order
) TO STDOUT WITH (FORMAT csv, HEADER true) \g outputs/q5_open_and_long_by_year.csv

COPY (
    SELECT sort_order, long_tail_rank, request_type,
           is_pooled_row::text AS is_pooled_row,
           types_in_row, long_requests, total_resolved, pct_of_type_long,
           share_of_all_long, cumulative_share_of_all_long, citywide_p90_days
    FROM analysis.q5_long_tail_by_type
    ORDER BY sort_order
) TO STDOUT WITH (FORMAT csv, HEADER true) \g outputs/q5_long_tail_by_type.csv


-- Question 6: have resolution times improved or worsened

COPY (
    SELECT month, year, resolved_requests, median_days, p90_days, pct_closed_within_7_days,
           median_days_same_month_last_year, change_vs_last_year, moving_avg_3_month_median,
           pct_faster_than_type_median, pct_still_open,
           data_gap::text AS data_gap
    FROM analysis.q6_monthly_trend
    ORDER BY month
) TO STDOUT WITH (FORMAT csv, HEADER true) \g outputs/q6_monthly_trend.csv

COPY (
    SELECT *
    FROM analysis.q6_yearly_trend
    ORDER BY year
) TO STDOUT WITH (FORMAT csv, HEADER true) \g outputs/q6_yearly_trend.csv

COPY (
    SELECT *
    FROM analysis.q6_type_trend
    ORDER BY type_rank, year
) TO STDOUT WITH (FORMAT csv, HEADER true) \g outputs/q6_type_trend.csv

COPY (
    SELECT *
    FROM analysis.q6_mix_adjusted_median
    ORDER BY sort_order
) TO STDOUT WITH (FORMAT csv, HEADER true) \g outputs/q6_mix_adjusted_median.csv
