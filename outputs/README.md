# Outputs for Tableau

The results of the six analysis questions, saved as CSV files for Tableau. Tableau Public can't connect to PostgreSQL, so the results are exported as files:

- [`sql/05_export.sql`](../sql/05_export.sql) writes the 14 CSVs, one per table built by [`sql/04_analysis.sql`](../sql/04_analysis.sql), with the same names.
- [`scripts/download_boundaries.py`](../scripts/download_boundaries.py) downloads the two `.geojson` boundary files used for the maps, from the same City of Baltimore layers as the population tables.

To rebuild them, from the project folder:

```bash
psql -d baltimore_311 -f sql/05_export.sql
python3 scripts/download_boundaries.py
```

## Before building charts

- **Percentages run from 0 to 100.** For example, 25.19 means 25.19%. In Tableau, show them with a custom number format and a `%` suffix. Don't use the Percentage format, because it multiplies by 100 again.
- **April and May 2025 are mostly missing from the city's file.** In `q1_monthly_volume`, `data_gap` is `true` for those two months; shade them gray so the drop isn't read as real. In `q6_monthly_trend` they have no medians, so set the line to break there (Format → Special Values → Hide (Break Lines)).
- **Year-over-year changes use comparable months:** every month except April and May, in every year.
- **Sort by the rank or `sort_order` column.** Otherwise Tableau sorts names alphabetically.
- **A blank cell means no value.** Examples: no previous year to compare with, or a group below a size cutoff.

## Files

| File | One row is | Rows |
|---|---|---:|
| `q1_top_request_types.csv` | a year and one of its 10 most common resident request types | 30 |
| `q1_monthly_volume.csv` | a month and a group (resident field requests, call center, crew-logged work) | 108 |
| `q1_yearly_totals.csv` | a year and a group, with the change from the year before | 9 |
| `q2_resolution_by_type.csv` | a request type: median, average and 90th-percentile days to close | 142 |
| `q3_neighborhoods.csv` | a neighborhood: requests per 1,000 residents, median days, type-adjusted speed | 232 |
| `q3_council_districts_2025.csv` | a council district, 2025 only (the district map changed that year) | 14 |
| `q4_seasonality.csv` | a request type and a calendar month, with its seasonal index | 132 |
| `q4_season_summary.csv` | a request type: peak and quietest month, share of the year by season | 11 |
| `q5_open_and_long_by_year.csv` | a year: share still open, share unusually long | 3 |
| `q5_long_tail_by_type.csv` | a request type's share of all very slow requests, with a running total | 143 |
| `q6_monthly_trend.csv` | a month: median days to close and 3-month moving average | 36 |
| `q6_yearly_trend.csv` | a year: median, 90th percentile and share closed within 7 days | 3 |
| `q6_type_trend.csv` | one of the 10 biggest request types in one year, with the change since 2023 | 30 |
| `q6_mix_adjusted_median.csv` | a year's median, re-weighted to another year's mix of request types | 9 |
| `neighborhoods.geojson` | a neighborhood's boundary (all 279; property `neighborhood`) | 279 |
| `council_districts.geojson` | a council district's boundary, current map (property `council_district`) | 14 |

The comment block above each query in `sql/04_analysis.sql` explains every column.

## Chart ideas

Three dashboards, two questions each. Each lists more views than one dashboard needs, so pick 3 or 4.

### 1. What residents report, and when (Questions 1 and 4)

- **Monthly volume** (`q1_monthly_volume`): a line chart with `month` across and `requests` up, one line per `category`. Shade the two `data_gap` months gray, with a note that the city's file is missing them.
- **Top request types** (`q1_top_request_types`): horizontal bars of `requests_comparable_months`, sorted by `rank`, with `year` as a filter. Show `pct_change` as the label.
- **Seasonal heatmap** (`q4_seasonality`): `request_type` down (sorted by `volume_rank`) and `month_name` across (sorted by `calendar_month`), colored by `seasonal_index`. Use a diverging color centered at 1.00, so busier-than-average months and quieter ones stand out. Potholes peaking in late winter is visible at a glance.
- **Yearly change** (`q1_yearly_totals`): a small table or bar of `pct_change` by year for each group.

### 2. Is the city getting faster? (Questions 5 and 6)

- **Headline numbers** (`q6_yearly_trend`, `q5_open_and_long_by_year`): big-number tiles comparing 2023 with 2025 for `median_days`, `pct_closed_within_7_days` and `pct_long`.
- **Monthly speed** (`q6_monthly_trend`): a line of `median_days` with `moving_avg_3_month_median` as a smoother second line. The line breaks at the 2025 gap.
- **Type by type** (`q6_type_trend`): a dumbbell chart, one row per `request_type`, with a dot for `median_days` in 2023 and another in 2025, joined by a line. Color the 2025 dot by `direction_vs_2023` (only the 2025 rows have it). It shows how many of the biggest types got slower.
- **Like for like** (`q6_mix_adjusted_median`): filter `type_mix_of_year` = 2024, then bars of `actual_median_days` next to `mix_adjusted_median_days` for each year. It shows what the ordinary median hides when the mix of requests changes.
- **Unusually long** (`q5_open_and_long_by_year`): bars of `pct_long` by year. It is measured against a fixed 2023 bar, so 2023 is about 10% by design.

### 3. What is slow, and where (Questions 2, 3 and 5)

- **Slowest request types** (`q2_resolution_by_type`): horizontal bars of `median_days` for the 15 slowest (`rank_slowest` ≤ 15), with `avg_days` as a dot on the same axis. The gap between bar and dot shows how a few very slow requests pull the average up. Color by `main_agency`.
- **Neighborhood maps** (`neighborhoods.geojson` + `q3_neighborhoods`): one map colored by `requests_per_1000_residents`, and one by `pct_faster_than_type_median`, diverging at 50 (below 50 = slower than typical for the mix of requests). The request rate is skewed: the busiest neighborhoods make several times as many requests per resident as a typical one. So use stepped color (about 5 steps) for that map, or it shows a few dark areas and the rest pale.
- **Busier vs slower** (`q3_neighborhoods`): a scatter with `requests_per_1000_residents` across and `median_days` up, plus a trend line. Then swap `median_days` for `pct_faster_than_type_median`. This is the key point of Question 3: busier neighborhoods have slower raw medians, but not once the kinds of request are taken into account.
- **Council districts** (`q3_council_districts_2025`): bars of `requests_per_1000_residents` and `pct_faster_than_type_median` for the 14 districts, or a map using `council_districts.geojson`.
- **Where the long waits come from** (`q5_long_tail_by_type`): a Pareto chart. Bars of `long_requests` by `request_type`, sorted by `sort_order`, plus a line of `cumulative_share_of_all_long` on a second axis with a reference line at 80%. The pooled "All other types" row sorts last.

### Joining the maps

1. Connect to a spatial file and choose `neighborhoods.geojson`. Then add `q3_neighborhoods.csv` as a second table.
2. Tableau relates the two on `neighborhood`, because both files use that name. If it doesn't, pick `neighborhood` on both sides.
3. Double-click Geometry to draw the map, then drag a measure onto Color.

Neighborhoods below the size cutoffs (fewer than 500 residents or 100 resolved requests) have no CSV row, so they show as gray. Council districts work the same way, joined on `council_district`.

### Color

- Counts and rates use one color from light to dark.
- `seasonal_index` and `pct_faster_than_type_median` use a diverging color, centered at 1.00 and 50.
- The three request groups in Question 1 keep the same three colors on every chart. Data-gap months are gray.
