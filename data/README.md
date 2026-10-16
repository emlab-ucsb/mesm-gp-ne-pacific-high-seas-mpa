# data/

These are small data files you can use right away, no BigQuery needed. The
pipeline writes them all from the full table in BigQuery
(`emlab-gcp.mesm_gp_ne_pacific_high_seas.ais_effort_by_pixel_v20261016`), so
it's best not to edit them by hand: any changes would be overwritten the
next time it runs. `readr::read_csv()` reads the `.csv.gz` files just as
they are.

A few conventions that apply to every file:

- **Coverage.** January 2015 to August 2026, in the study area box
  (`small_gfw_bbox_mesm/`) pushed out to whole degrees: lon −160 to −120,
  lat 39 to 62.
- **Pixels.** `lon_center` and `lat_center` are the centre of a pixel, in
  degrees (WGS84). A 0.05° pixel spans ±0.025° around its centre.
- **Activity.** `hours` is hours of vessel activity. `kw_hours` is hours ×
  the vessel's engine power in kW. Both add up across rows.
- **Missing rows mean zero.** A pixel with no activity simply has no row.
- **Rounding.** Numbers are rounded to 7 significant digits.

The [site](https://emlab-ucsb.github.io/mesm-gp-ne-pacific-high-seas-mpa/)
explains what the vessel classes mean, how fishing activity is decided, and
which vessels I left out. It also lists the bigger datasets available from
BigQuery and how big each one is, and I'm happy to pull any of those for
you. For more on how GFW assigns vessel types, GFW's
[pipeline 5 release notes](https://docs.google.com/document/d/1wFtKu_6ixCGCfmTk3j6UPbKBgFrQdJ_BtrGiooC0yDQ/edit) are a great resource.

## Pixel data

### `ais_effort_by_pixel_0p05deg_2025.csv.gz`

**Our main cost layer:** all vessel activity at 0.05°, summed over 2025, the
most recent full year. I'd start here. About 970,000 rows, 12 MB. One
row per pixel, vessel class, fishing vessel and fishing activity.

| Column | Type | Description |
|---|---|---|
| `year` | number | Always 2025. |
| `lon_center` | number | Longitude of the pixel centre (degrees). |
| `lat_center` | number | Latitude of the pixel centre (degrees). |
| `vessel_class` | text | Vessel type, e.g. `trawlers`, `cargo`, `passenger`. `fishing` and `non_fishing` are catch-alls for vessels whose specific type GFW's model isn't sure of. |
| `fishing_vessel` | TRUE/FALSE | `TRUE` if GFW classifies the vessel as a fishing vessel (*what the vessel is*). |
| `fishing_activity` | TRUE/FALSE | `TRUE` for time spent fishing (*what the vessel was doing*). Only ever `TRUE` when `fishing_vessel` is. |
| `hours` | number | Hours of vessel activity in 2025. |
| `kw_hours` | number | Hours × engine power (kW) in 2025. |

### `ais_effort_by_pixel_0p05deg_all_years.csv.gz`

The same as the 2025 file, summed over the whole period (January 2015 to
August 2026) instead, without the `year` column. About 2.0 million rows,
24 MB. One row per pixel, vessel class, fishing vessel and fishing activity.

| Column | Type | Description |
|---|---|---|
| `lon_center` | number | Longitude of the pixel centre (degrees). |
| `lat_center` | number | Latitude of the pixel centre (degrees). |
| `vessel_class` | text | Vessel type, e.g. `trawlers`, `cargo`, `passenger`. `fishing` and `non_fishing` are catch-alls for vessels whose specific type GFW's model isn't sure of. |
| `fishing_vessel` | TRUE/FALSE | `TRUE` if GFW classifies the vessel as a fishing vessel (*what the vessel is*). |
| `fishing_activity` | TRUE/FALSE | `TRUE` for time spent fishing (*what the vessel was doing*). Only ever `TRUE` when `fishing_vessel` is. |
| `hours` | number | Hours of vessel activity. |
| `kw_hours` | number | Hours × engine power (kW). |

### `ais_fishing_activity_by_pixel_0p05deg_yearly.csv.gz`

Fishing activity only, at 0.05°, by year. About 340,000 rows, 4 MB. One row
per year, pixel and vessel class. 2026 covers January to August.

| Column | Type | Description |
|---|---|---|
| `year` | number | Calendar year. |
| `lon_center` | number | Longitude of the pixel centre (degrees). |
| `lat_center` | number | Latitude of the pixel centre (degrees). |
| `vessel_class` | text | Fishing vessel type, e.g. `trawlers`, `trollers`, `drifting_longlines`. |
| `hours` | number | Hours of fishing activity. |
| `kw_hours` | number | Hours × engine power (kW) of fishing activity. |

## Summaries

### `ais_effort_by_pixel_summary.csv`

Monthly totals for the whole box, with no pixels: good for time series. About
4,000 rows. One row per month, vessel class, fishing vessel and fishing
activity.

| Column | Type | Description |
|---|---|---|
| `month` | date | First day of the month. |
| `vessel_class` | text | Vessel type. |
| `fishing_vessel` | TRUE/FALSE | `TRUE` if GFW classifies the vessel as a fishing vessel. |
| `fishing_activity` | TRUE/FALSE | `TRUE` for time spent fishing. |
| `n_pixels` | number | Number of 0.01° pixels with any activity in that month and group. |
| `hours` | number | Hours of vessel activity. |
| `kw_hours` | number | Hours × engine power (kW). |

### `ais_vessel_class_summary.csv`

How many vessels there are of each class, and how many the filters dropped.
One row per vessel class. Counted from GFW's vessel identity tables, over
vessels broadcasting AIS anywhere in the world from January 2015 to August
2026.

| Column | Type | Description |
|---|---|---|
| `vessel_class` | text | Vessel type. Blank for vessels GFW's model couldn't classify. |
| `fishing_class` | TRUE/FALSE | `TRUE` if the class is a fishing class. |
| `n_vessels` | number | Vessels of this class, before any filter. |
| `n_vessels_noisy` | number | Of those, vessels that were ever noisy (impossible positions, or an MMSI shared by two vessels at once). Dropped. |
| `n_vessels_no_engine_power` | number | Of those, vessels with no engine power. Dropped. |
| `n_vessels_kept` | number | Vessels kept in the analysis. |
| `n_vessels_kept_fishing_vessel` | number | Of those kept, fishing vessels. |
| `n_vessels_kept_study_area` | number | Of those kept, vessels whose yearly range overlaps the study area: an upper bound on the vessels in our data. |
| `n_vessels_kept_study_area_fishing_vessel` | number | Of those, fishing vessels. |

### `ais_effort_by_pixel_download_sizes.csv`

How big the full table would be to download, cut different ways. One row per
cut. The site turns this into a table with gzipped sizes and download times.

| Column | Type | Description |
|---|---|---|
| `cut` | text | Short description of the cut. |
| `pixel_size` | number | Pixel size (degrees). |
| `time` | text | Time step: `month`, `year`, or `all` (summed over the whole period). |
| `year` | number | A single year, or blank for 2015 to 2026. |
| `fishing_activity_only` | TRUE/FALSE | `TRUE` if only fishing activity rows are kept. |
| `file` | text | The file in this folder holding that cut, or blank if you'd query BigQuery. |
| `n_rows` | number | Number of rows. |
| `csv_mb` | number | Size as an uncompressed CSV (MB). |

### `ais_effort_by_pixel_test_month_summary.csv`

The same columns as `ais_effort_by_pixel_summary.csv`, for July 2025 only.
It's from the one-month test run the pipeline does before the full scan, so
you can safely skip it.

## Maps and boundaries

- **`small_gfw_bbox_mesm/`**: the study area box (shapefile, WGS84): lon −160
  to −120, lat 39.89 to 61.55. The pipeline reads this.
- **`gfw_bbox_mesm/`**: the first, larger box (west edge at −166.79), no
  longer used.
- **`land_ne_50m.geojson`**: land polygons from
  [Natural Earth](https://www.naturalearthdata.com) at 1:50m, cut to the box
  plus a degree, for drawing coastlines on maps.

## Citing the data

If you use or show this data, please cite Global Fishing Watch's paper,
which is GFW's official citation for its AIS data:

> Kroodsma, D. A., Mayorga, J., Hochberg, T., Miller, N. A., Boerder, K.,
> Ferretti, F., Wilson, A., Bergman, B., White, T. D., Block, B. A., Woods,
> P., Sullivan, B., Costello, C., & Worm, B. (2018). Tracking the global
> footprint of fisheries. *Science*, 359(6378), 904–908.
> <https://doi.org/10.1126/science.aao5646>

It's also nice to say where the data came from, for example: "AIS data from
Global Fishing Watch (globalfishingwatch.org), pipeline 5, accessed October
2026." GFW's [pipeline 5 release notes](https://docs.google.com/document/d/1wFtKu_6ixCGCfmTk3j6UPbKBgFrQdJ_BtrGiooC0yDQ/edit) (September 2026) describe
how the data are built, especially how vessel types are assigned. The land
polygons are from [Natural Earth](https://www.naturalearthdata.com).
