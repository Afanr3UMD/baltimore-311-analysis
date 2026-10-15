# Baltimore 311: How Fast Does the City Respond?

An analysis of 3,038,219 service requests made to Baltimore's 311 line from 2023 to 2025, built entirely in PostgreSQL. It covers what residents report, where and when, how long the city takes to close each request, and whether that is getting better or worse.

**Tools:** PostgreSQL (loading, cleaning and analysis), Python (small helper scripts), CSV exports for Tableau.

## Key findings

1. **Demand is rising, led by parking.** Resident requests from the field grew 6.18% in 2025 (442,553, against 416,794 in 2024, comparing the same 10 months each year). Parking Complaint grew 57.20% in 2025, to 46,329 requests, and is now by far the most common (Sanitation Property, second, had 29,720).
2. **A few request types take months.** The typical request is closed in 2.38 days (the median), but the average is 15.49 days, because a small number take months or more. Surface Repair is the slowest type (median 213.17 days), and 6 of the 10 slowest types belong to Transportation. For all 142 request types ranked, the average is higher than the median.
3. **Busier neighborhoods are not served worse.** Requests per 1,000 residents vary about 74-fold across 232 neighborhoods (47.00 to 3,457.67 a year). Busier neighborhoods have slower raw medians (correlation 0.47). But when each request is compared with the typical time for its type, busier neighborhoods come out slightly faster (correlation 0.22 with the share closed faster than typical). So the gap most likely comes from the kinds of request they make, not slower service. In 2025, Council District 10 was the slowest district on both measures (median 3.95 days).
4. **Potholes peak in March.** Pothole reports in March run 59% above an average month and 4.02 times November's low, and 60.41% of them come in winter and spring.
5. **Long waits are growing.** Against a fixed bar for each request type (its 2023 90th percentile), the share of closed requests that took unusually long rose from 9.96% in 2023 to 17.14% in 2024 and 25.19% in 2025. Just 10 of the 142 ranked types account for half (50.33%) of all requests slower than the citywide 90th percentile of 27.18 days.
6. **Response times got worse, and a flat 2025 median hides it.** The median time to close rose from 2.13 days in 2023 to 2.73 in 2024 and 2.74 in 2025, and the share closed within a week fell from 71.34% to 66.60%. In 2025, quick request types such as parking complaints made up more of the work, which pulled the median down. With 2024's mix of request types, 2025's median would have been 3.09 days, against 2.84 in 2024 (same 10 months). 7 of the 10 biggest request types got slower from 2023 to 2025.

## The data

Three yearly files from [Open Baltimore](https://data.baltimorecity.gov), one row per request (3,038,221 rows), plus 2020 Census population by neighborhood and council district from the city's map layers. [`data/README.md`](data/README.md) lists the sources and download commands.

## Cleaning

Every cleaning step is done in SQL and logs how many rows it affected. [`data_cleaning_log.md`](data_cleaning_log.md) lists all 36 steps and the reasons behind them. Highlights:

- **Flag, don't delete.** Only 2 test records were removed. Everything else that would distort a measure is kept and flagged, so each analysis decides what to include.
- **Found a gap in the city's own data.** The 2025 file is missing most requests from 2025-03-31 to 2025-06-01. The city issued 193,674 request numbers in that period, but only 48,423 of those requests are in the file, so about 145,000 are missing. The gap is flagged and left out of comparisons.
- **Fixed dates the export had shifted.** On 989,917 rows the due date was earlier than the request itself, because the export had moved it back by the UTC offset; those due dates are removed. Close times saved without seconds are no longer read as closing before the request was created.
- **Measured only what the city controls.** Resolution times use 1,279,216 closed requests from the field. They leave out call-center questions, work crews logged themselves, booked pickups (the time is the wait for the booked date), duplicates, transfers, referrals and the 2025 gap.

## Questions and SQL techniques

All analysis is in [`sql/04_analysis.sql`](sql/04_analysis.sql). Each query has a plain-language comment block: the question, the steps, why, and the techniques used.

| # | Question | Techniques |
|---|---|---|
| 1 | Which request types are most common, and how does volume change by month and year? | CTEs, `RANK()`, `LAG()`, running totals with `SUM() OVER`, a `generate_series` calendar |
| 2 | Which request types take longest to close (median, not just average)? | `PERCENTILE_CONT` for the median and 90th percentile, `mode()`, `HAVING` cutoffs |
| 3 | How do request rates and speed differ by neighborhood and council district, per resident? | joins to Census population, a type-adjusted speed measure, `RANK()` |
| 4 | Which requests are seasonal? | a seasonal index with `AVG() OVER`, `CASE` for seasons, `CROSS JOIN LATERAL` |
| 5 | What share is still open, or took unusually long? | a fixed 2023 percentile bar, a Pareto running total |
| 6 | Are resolution times improving? | `LAG(12)` for the same month last year, a 3-month moving average, a weighted median for a like-for-like comparison |

The results are exported as CSV files for Tableau. [`outputs/README.md`](outputs/README.md) describes each file and suggests charts.

## How to run it

Needs PostgreSQL (built on version 18) and Python 3. Run everything from the project folder:

```bash
createdb baltimore_311
# Download the three 311 files into data/raw/ (commands in data/README.md)
psql -d baltimore_311 -f sql/01_schema.sql
psql -d baltimore_311 -f sql/02_load.sql       # about 30 seconds
psql -d baltimore_311 -f sql/03_cleaning.sql   # about 5 minutes
psql -d baltimore_311 -f sql/04_analysis.sql   # about 30 seconds
psql -d baltimore_311 -f sql/05_export.sql
```

## Project structure

```
sql/
  01_schema.sql        tables for the raw and clean data
  02_load.sql          loads the 311 files and population tables
  03_cleaning.sql      builds clean.service_requests and the cleaning log
  04_analysis.sql      the six questions (14 result tables)
  05_export.sql        saves the results as CSVs for Tableau
scripts/
  fix_ragged_rows.py       pads short rows while loading
  download_population.py   2020 population tables
  download_boundaries.py   map shapes for Tableau
data/README.md         data sources and download commands
data_cleaning_log.md   every cleaning step, with row counts
outputs/               result CSVs, map files and chart ideas
```

## Limitations

- **April and May 2025 are mostly missing** from the city's file. Year-over-year comparisons use the same 10 months in every year.
- **Council districts were redrawn between the 2024 and 2025 files**, so per-resident rates by district cover 2025 only. Neighborhoods are compared across all three years.
- **Closed is not always fixed.** Among the requests used for resolution times, 46.3% are marked "Work completed". Others were closed after review or by a department's own system.
- **"Still open" is a snapshot** from each file's last update.
- **Population comes from the 2020 Census.**

## About

Afan Rashid. Previously an End User Engineer in the City of Baltimore's IT department.
