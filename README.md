# Vessel activity in the Northeast Pacific: the AIS cost layer

This repo builds the vessel-activity data for our Bren MESM group project,
[New Wave of High Seas Protections: Scoping Northern Seamount Ecosystems under BBNJ](https://bren.ucsb.edu/projects/new-wave-high-seas-protections-scoping-northern-seamount-ecosystems-under-biodiversity).
We're prioritizing areas for protection along the Cobb-Eickelberg seamount
chain, and we need a cost layer: where, and how much, people already use the
ocean. This is that layer, built from Global Fishing Watch (GFW) AIS data.

**Start with the site:** <https://emlab-ucsb.github.io/mesm-gp-ne-pacific-high-seas-mpa/>.
It has maps of all vessel activity and of fishing, trends over time, and how
big the data are to download. It rebuilds itself every time we push to
`main`.

You don't need to run any of the code here to use the data. It's already in
BigQuery, and a few small versions are in [data/](data/). Most of you only need
the sections on what's in the table, what to watch out for, and how to get it
into R.

## The short version

- **The full data is one BigQuery table:**
  `emlab-gcp.mesm_gp_ne_pacific_high_seas.ais_effort_by_pixel_v20261016`.
  It has 262 million rows (13 GB). Each row is the vessel activity in one
  0.01° pixel (about 1 km), in one month, for one vessel class, split into
  fishing activity and everything else. It covers January 2015 to August 2026.
- **Don't download the whole thing.** As a CSV it's about 17 GB. Aggregate it
  in BigQuery first, then download. The [download sizes](#how-big-is-a-download)
  table below tells you what to expect.
- **There's a small 0.05° version in the repo already.**
  [data/ais_effort_by_pixel_0p05deg_all_years.csv.gz](data/ais_effort_by_pixel_0p05deg_all_years.csv.gz)
  (25 MB) sums the whole period at 0.05°, the same resolution as our other
  cost layers.
  [data/ais_fishing_activity_by_pixel_0p05deg_yearly.csv.gz](data/ais_fishing_activity_by_pixel_0p05deg_yearly.csv.gz)
  (4 MB) has fishing activity at 0.05° by year. `readr::read_csv()` reads them
  as-is.
- **Queries cost real money, but reading this table is cheap.** A query over
  the whole table reads about 13 GB, roughly $0.07. Rebuilding the table from
  GFW's raw data reads 19 TB, about $108, so please check with me before
  re-running that part of the pipeline.

## What's in the table

One row per month, pixel, vessel class, fishing vessel or not, and fishing
activity or not:

| Column | What it is |
|---|---|
| `month` | First day of the month (UTC). |
| `lon_center`, `lat_center` | Centre of the 0.01° pixel. The pixel spans ±0.005° around it. |
| `vessel_class` | The vessel's type, e.g. `trawlers`, `cargo`, `passenger`, `tug`. 28 classes show up in our box. |
| `fishing_vessel` | `TRUE` if GFW classifies the vessel as a fishing vessel. This is about *what the vessel is*. |
| `fishing_activity` | `TRUE` for time spent fishing. This is about *what the vessel was doing*. |
| `hours` | Hours of vessel activity. |
| `kw_hours` | Hours × the vessel's engine power (kW). |

Only rows with some activity are in the table. A pixel-month with no vessels
simply has no row, so treat missing as zero. The 0.05° files in [data/](data/)
have the same columns, minus `month` (the all-years file) or with `year`
instead (the fishing file).

**Hours vs kW-hours.** Hours is how much time vessels spent there. kW-hours
weights each hour by the vessel's engine power, so an hour from a big trawler
counts for more than an hour from a small troller. It's the standard GFW
measure of fishing *effort*, and a decent proxy for how much fishing pressure
a place gets. Engine power comes from GFW's model (replaced by registry values
where they exist), and every vessel in the table has one.

**`fishing_vessel` vs `fishing_activity`.** A trawler steaming to port is a
fishing vessel that isn't fishing: `fishing_vessel = TRUE`,
`fishing_activity = FALSE`. A cargo ship is never fishing: both are `FALSE`.
The pipeline checks every row, and a non-fishing vessel can never have fishing
activity. Fishing activity is GFW's model estimate of when a vessel is
fishing, based on how it moves. GFW calls it "apparent fishing".

**Vessel classes.** These come from GFW's vessel classification model. When
the model isn't confident about a fishing vessel's gear, it falls back to the
generic class `fishing`. Where it does have a best guess for one of the gears
it predicts well (trawlers, drifting longlines, set gillnets, tuna purse
seines, squid jiggers), we use that guess instead. A few hundred vessels in
the box are still just `fishing`. There's a similar catch-all on the
non-fishing side, `non_fishing`.

## How the table was built

1. **The vessel list.** We start from GFW's vessel identity table (one row
   per vessel, identified by MMSI, the vessel's AIS ID), using GFW's latest
   "pipeline 5" models. It gives us each vessel's class, whether it's a
   fishing vessel, and its engine power.
2. **The positions.** Every AIS position in the box from January 2015 to
   August 2026, on GFW's "good" track segments only.
3. **Fishing or not.** Each position from a fishing vessel gets GFW's fishing
   call (squid jiggers use a separate night-loitering rule, since they fish
   at night under lights). Positions from non-fishing vessels are never
   fishing.
4. **The pixels.** Positions are binned into 0.01° pixels and summed by month,
   vessel class and the two fishing flags.

**The box.** It's the rectangle in
[data/small_gfw_bbox_mesm/](data/small_gfw_bbox_mesm/) (lon −160 to −120,
lat 39.89 to 61.55), pushed outward to whole degrees: lon −160 to −120, lat 39
to 62. That way, if you coarsen to 0.05°, 0.1°, 0.25°, 0.5° or 1°, no pixel is
cut in half by the edge of the box. To trim back to the box as drawn, filter
on `lat_center`.

### What we left out, and why

- **Fishing gear.** Lots of AIS transmitters are on nets and buoys, not
  vessels. They're dropped.
- **Vessels GFW couldn't classify.** These have too little AIS activity for
  the model, about 0.2% of hours.
- **Noisy vessels.** These are MMSIs that GFW saw broadcasting impossible
  positions, or shared by two vessels at the same time. If a vessel was ever
  noisy, we drop it from *every* year, not just the bad ones, so each vessel
  is in the time series for all of its years or none of them. It also means
  a vessel's class never rests on someone else's track.
- **Anything after August 2026.** GFW's vessel identity data currently runs
  through August.

The vessel list, with each vessel's class, flag and engine power, is in
`emlab-gcp.mesm_gp_ne_pacific_high_seas.ais_vessels_v20261016`.
[data/ais_vessel_class_summary.csv](data/ais_vessel_class_summary.csv) has
vessel counts by class.

## Things to watch out for

- **The box isn't all high seas.** It takes in a big chunk of the US and
  Canadian EEZs, the coast, and inland waters. Clip to your planning region
  before you use any of it as a cost.
- **Most of the hours aren't fishing.** Over the whole period, passenger
  vessels are 54% of all hours, trawlers 13%, tugs 11% and cargo ships 10%.
  Fishing activity is only about 1% of all vessel hours. Decide early what
  "cost" means for your prioritization: fishing activity only, fishing
  kW-hours, or all traffic? These give very different maps.
- **AIS doesn't see everything.** Not every vessel carries AIS, some switch
  it off, and reception varies by place and over time. Satellite coverage
  has improved a lot since 2015, so some of any upward trend is just better
  coverage. Be careful reading trends from the raw totals.
- **Fishing activity is a model estimate,** not observed fishing. It's good
  at the scale we're using it, but it isn't a logbook.
- **Hours add up; vessel counts don't.** You can sum `hours` and `kw_hours`
  across pixels, months and classes however you like. We don't store vessel
  counts, because the same vessel shows up in many pixels and months.
- **Coastal pixels include time in port.** Hours in harbors and anchorages
  count as non-fishing activity.

## Getting the data into R

**The easy way: the 0.05° files.** No BigQuery needed:

```r
effort <- readr::read_csv("data/ais_effort_by_pixel_0p05deg_all_years.csv.gz")

fishing_hours <- effort |>
  dplyr::filter(fishing_activity) |>
  dplyr::group_by(lon_center, lat_center) |>
  dplyr::summarise(hours = sum(hours), kw_hours = sum(kw_hours), .groups = "drop")

fishing_raster <- terra::rast(
  dplyr::select(fishing_hours, lon_center, lat_center, hours),
  type = "xyz",
  crs = "EPSG:4326"
)
```

Because the files store pixel centres, you can pass them straight to
`terra::rast(type = "xyz")` like that.

**Anything else: query BigQuery.** You need access to BigQuery in the
`emlab-gcp` project (ask me if you don't have it). The first time, run
`bigrquery::bq_auth()` to log in with your UCSB Google account. Then
aggregate in BigQuery and download the (much smaller) result. For example,
fishing activity per year at 0.1°:

```r
sql <- "
SELECT
  EXTRACT(YEAR FROM month) AS year,
  ROUND(FLOOR(lon_center / 0.1) * 0.1 + 0.05, 3) AS lon_center,
  ROUND(FLOOR(lat_center / 0.1) * 0.1 + 0.05, 3) AS lat_center,
  SUM(hours) AS fishing_hours,
  SUM(kw_hours) AS fishing_kw_hours
FROM `emlab-gcp.mesm_gp_ne_pacific_high_seas.ais_effort_by_pixel_v20261016`
WHERE fishing_activity
GROUP BY 1, 2, 3
"

fishing <- bigrquery::bq_project_query("emlab-gcp", sql) |>
  bigrquery::bq_table_download()
```

The `FLOOR(... / 0.1) * 0.1 + 0.05` bit regrids the 0.01° pixels to 0.1°.
For 0.05° pixels, swap in 0.05 and 0.025. Because the table stores pixel
centres, this regridding is always exact.

Some ways to keep queries cheap and fast:

- **Filter on `month` when you can.** The table is partitioned by month, so
  `WHERE month BETWEEN '2025-01-01' AND '2025-12-01'` only reads 2025.
- **Filter on `fishing_activity` early if that's all you need.** Fishing rows
  are only a percent or two of the table.
- **Use the BigQuery console** to try a query first. It shows how much data
  the query will read before you run it.

## How big is a download?

Rows and CSV size for a few aggregations and filters (from
[data/ais_effort_by_pixel_download_sizes.csv](data/ais_effort_by_pixel_download_sizes.csv)).
Every row keeps the vessel class and the two fishing columns.

| Cut | Rows | CSV |
|---|---|---|
| Full table (0.01°, monthly) | 262 million | 17 GB |
| 0.01°, yearly | 108 million | 6.4 GB |
| 0.01°, all years summed | 25 million | 1.4 GB |
| 0.05°, monthly | 43 million | 2.8 GB |
| 0.05°, yearly | 10 million | 613 MB |
| 0.05°, all years summed | 2.0 million | 113 MB |
| 0.1°, monthly | 16 million | 1.0 GB |
| 0.1°, yearly | 3.5 million | 204 MB |
| 0.1°, all years summed | 665,000 | 36 MB |
| 2025 only, 0.01°, monthly | 31 million | 2.0 GB |
| 2025 only, 0.1°, monthly | 1.5 million | 96 MB |
| Fishing activity only, 0.01°, monthly | 3.5 million | 229 MB |
| Fishing activity only, 0.05°, yearly | 340,000 | 20 MB |
| Fishing activity only, 0.1°, yearly | 151,000 | 9 MB |

A few rules of thumb:

- **These estimates are accurate.** I downloaded one cut to check, and the
  file came out at exactly the estimated size.
- **Compressing helps a lot.** Gzip (`readr::write_csv("x.csv.gz")`) makes
  files about 4× smaller, and Parquet (`arrow::write_parquet()`) about 3×.
- **Downloads run at roughly 40,000 rows a second.** A few million rows takes
  a minute or two; 100+ million rows takes an hour or more and won't fit in
  a laptop's memory.
- **GitHub won't take files over 50 MB,** and the pipeline refuses to write
  one into this repo. Keep big downloads on the shared drive, not in git.

To size a different cut, add a row to `ais_download_cuts` in
[targets/ais.R](targets/ais.R) and run `targets::tar_make()`.

## Re-running or changing the pipeline

You only need this if you're changing how the data is built. Everything is a
[targets](https://books.ropensci.org/targets/) pipeline, with package
versions pinned by [renv](https://rstudio.github.io/renv/).

**Setup:**

1. Open `mesm-gp-ne-pacific-high-seas-mpa.Rproj` (or the folder in Positron).
2. Run `renv::restore()` to install the right package versions.
3. Run `bigrquery::bq_auth()` once to log in. If you have more than one
   Google account cached, add `GARGLE_OAUTH_EMAIL=you@ucsb.edu` to a
   `.Renviron` file in the project.

**Running:**

```r
targets::tar_visnetwork()  # see the pipeline and what's out of date
targets::tar_outdated()    # list what would re-run
targets::tar_make()        # run whatever is out of date
```

**The expensive part is switched off.** The pixel table reads every AIS
position in the window: 19 TB, about $108. In [config.R](config.R),
`run_full_ais_scan` is `FALSE`. That freezes the table: everything
downstream (the summaries, download sizes and site data) reads the table
already in BigQuery, and the scan never re-runs. Only set it to `TRUE` if you
mean to rebuild the table, and check with me first. A few things to know:

- **Running the pipeline isn't free.** Even with the scan off, a full
  `tar_make()` on a fresh copy of the repo rebuilds the vessel tables, the
  one-month test table, the summaries and the site data (about $3), since
  your machine has no record of the earlier runs.
- **There's a safety cap.** Every query has a cap on how much it may read
  (`max_tb_billed` in [config.R](config.R)), so a mistake fails instead of
  running up a bill.
- **The site rebuilds itself.** It reads only the files in [data/](data/), so
  editing the pages in [qmd/](qmd/) and pushing is all it takes. GitHub
  Actions re-renders the site on every push to `main`. To preview it
  locally, run `targets::tar_make(names = "site")` and open
  `qmd/_site/index.html`.

**Where things live:**

```
_targets.R            pipeline entry point
config.R              BigQuery settings, cost caps, GFW source tables
targets/parameters.R  dates, study area box, pixel size
targets/ais.R         the vessel list, pixel tables, download sizes, site data
targets/report.R      the site's coastline layer and render
sql/ais/              the SQL behind each table
r/functions.R         helper functions (BigQuery, checks, study area, site)
r/bq_table_docs.R     table and column descriptions, written into BigQuery
qmd/                  the Quarto site
data/                 the study area box, small data files for the site
```

Every table the pipeline writes is documented in BigQuery itself: look at
the table's Details and Schema tabs in the console. The build also checks
each table's rules every time, such as no duplicate rows and no fishing
activity from non-fishing vessels, and stops if one breaks.

**Code style:** explicit `package::function()` calls (no `library()`), the
base pipe `|>`, and tidyverse style. The setup follows
[emlab-ucsb/fishing-effort-drivers](https://github.com/emlab-ucsb/fishing-effort-drivers).

## Sources

- **AIS data and models: [Global Fishing Watch](https://globalfishingwatch.org),
  pipeline 5.** Credit GFW whenever you use or show this data.
- **Pipeline 5 changes:** described in GFW's *Pipe5 Release Notes for
  Research Partners* (September 2026). The table follows them: the new vessel
  class model, the new fishing model, and GFW's noisy-vessel definition.
  That document isn't public; ask me if you want to read it.
- **Coastlines on the site: [Natural Earth](https://www.naturalearthdata.com),**
  1:50m.
- **Generative AI:** Claude (Anthropic) was used as a coding assistant. The
  site's last section describes how.
