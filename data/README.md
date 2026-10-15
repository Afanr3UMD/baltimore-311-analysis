# Data sources

The 311 CSVs are about 1.2 GB together, so they are not committed. Download them into `data/raw/` with the commands below. The two small population files are committed.

## Baltimore 311 Customer Service Requests (Open Baltimore)

One dataset per calendar year, published by the City of Baltimore on [Open Baltimore](https://data.baltimorecity.gov).

| File | Year | Rows | Size | Open Baltimore item |
|---|---|---|---|---|
| `311_2023.csv` | 2023 | 1,025,029 | 404 MB | [e002bef8e17d44788f0d01025a20127e](https://data.baltimorecity.gov/datasets/e002bef8e17d44788f0d01025a20127e_0) |
| `311_2024.csv` | 2024 | 1,081,868 | 425 MB | [68a1136acff444bba6c93e845dfc00e1](https://data.baltimorecity.gov/datasets/68a1136acff444bba6c93e845dfc00e1_0) |
| `311_2025.csv` | 2025 | 931,324 | 379 MB | [52c763f4496d4101ba0c20af33336a9c](https://data.baltimorecity.gov/datasets/52c763f4496d4101ba0c20af33336a9c_0) |

Downloaded 2026-10-15. Row counts can change slightly if the city updates the data.

```bash
cd data/raw
curl -L -o 311_2023.csv "https://data.baltimorecity.gov/api/download/v1/items/e002bef8e17d44788f0d01025a20127e/csv?layers=0"
curl -L -o 311_2024.csv "https://data.baltimorecity.gov/api/download/v1/items/68a1136acff444bba6c93e845dfc00e1/csv?layers=0"
curl -L -o 311_2025.csv "https://data.baltimorecity.gov/api/download/v1/items/52c763f4496d4101ba0c20af33336a9c/csv?layers=0"
```

If a file comes back as a few hundred bytes of JSON saying the download "is being generated", wait a minute and run that line again.

## Population (2020 Census)

Both come from public layers on the City of Baltimore's ArcGIS server (owner `baltimore_citistat`).

| File | Rows | Source layer | Check |
|---|---|---|---|
| `population_neighborhoods_2020.csv` | 279 | Neighborhood Statistical Area (NSA) Boundaries, field `Population` | Sums to 585,682 (2020 Census city total: 585,708) |
| `population_council_districts_2020.csv` | 14 | Baltimore City Council Districts (updated 2026-04-30), field `totalPop` | Sums to 585,708 |
