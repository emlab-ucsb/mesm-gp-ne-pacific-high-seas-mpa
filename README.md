# Vessel activity in the Northeast Pacific: the AIS cost layer

This repo builds the vessel-activity data for our Bren MESM group project,
[New Wave of High Seas Protections: Scoping Northern Seamount Ecosystems under BBNJ](https://bren.ucsb.edu/projects/new-wave-high-seas-protections-scoping-northern-seamount-ecosystems-under-biodiversity),
which prioritizes areas for protection along the Cobb-Eickelberg seamount
chain. It turns Global Fishing Watch (GFW) AIS data into a gridded cost layer:
hours and kilowatt-hours of vessel activity per pixel and month, split by
vessel type and into fishing and non-fishing activity, January 2015 to August
2026.

**If you want to use the data, start with the site:**
<https://emlab-ucsb.github.io/mesm-gp-ne-pacific-high-seas-mpa/>. It has the
maps, the files you can start with, a table of the bigger datasets available
(and how big each is), what every column means, and the caveats. The files
in [data/](data/) are ready to use, and for anything bigger, which lives in
emLab's BigQuery project, Gavin is happy to pull it for you. This README is about what the repo does and how to
reproduce it.

## What it produces

- **BigQuery tables**, in `emlab-gcp.mesm_gp_ne_pacific_high_seas`, each
  documented in BigQuery itself (see the table's Details and Schema tabs):
  - `ais_effort_by_pixel_v20261016`: the full table. One row per month,
    0.01° pixel, vessel class, fishing vessel and fishing activity, with
    `hours` and `kw_hours`. 262 million rows, 13 GB.
  - `ais_vessels_v20261016`: the vessels in the analysis, with each one's
    class, fishing-vessel call, flag and engine power.
  - `ais_vessel_class_summary_v20261016`: vessel counts by class.
  - `ais_effort_by_pixel_test_v20261016`: one test month (July 2025), built
    before the full scan.
- **Small data files in [data/](data/)** that you can read straight into
  R, including the students' main cost layer: all activity at 0.05° for 2025
  (`data/ais_effort_by_pixel_0p05deg_2025.csv.gz`). The
  [data README](data/README.md) has the schema of every file.
- **The site,** rendered from [qmd/](qmd/) into [docs/](docs/), which GitHub
  Pages serves.

## How it works

It's a [targets](https://books.ropensci.org/targets/) pipeline in R, with
the heavy lifting in BigQuery SQL and package versions pinned by
[renv](https://rstudio.github.io/renv/):

1. **Vessels.** From GFW's pipeline 5 vessel identity table, each vessel's
   class, fishing-vessel call and engine power. It drops fishing gear,
   vessels GFW couldn't classify, and MMSIs that were ever noisy (from
   every year).
2. **Pixels.** Every AIS position in the study area box from January 2015 to
   August 2026, scored as fishing or not, binned into 0.01° pixels and summed
   by month. This is the one expensive query: it reads 19 TB.
3. **Downstream.** Download-size estimates, the small files in `data/`, and
   the site.

Every table is checked on every build: no duplicate rows, `fishing_vessel`
always matching the vessel class, and no fishing activity from non-fishing
vessels. The build stops if any check fails. The vessel and fishing
definitions follow GFW's *Pipe5 Release Notes for Research Partners*
(September 2026). That document isn't public; ask Gavin if you want to
read it.

## Reproducing it

**Setup:**

1. Open `mesm-gp-ne-pacific-high-seas-mpa.Rproj` (or the folder in Positron).
2. Run `renv::restore()` to install the package versions in `renv.lock`.
3. Run `bigrquery::bq_auth()` once to log in with a Google account that has
   BigQuery access to `emlab-gcp`, which needs an emLab account. If you
   don't have one, Gavin is happy to run the pipeline or pull data for you. If you have
   more than one account cached, add `GARGLE_OAUTH_EMAIL=you@ucsb.edu` to a
   `.Renviron` file in the project.

**Running:**

```r
targets::tar_visnetwork()  # see the pipeline and what's out of date
targets::tar_outdated()    # list what would re-run
targets::tar_make()        # run whatever is out of date
```

**Costs.** BigQuery bills emlab-gcp by data read, about $6.25 per TiB.

- **The 19 TB scan (~$108) is switched off.** In [config.R](config.R),
  `run_full_ais_scan` is `FALSE`. That freezes the full table: everything
  downstream reads the table already in BigQuery, and the scan never
  re-runs. Only set it to `TRUE` to rebuild the table on purpose, and check
  with Gavin first. While it's `TRUE`, changing anything upstream of the scan
  (its SQL, the vessel filters, the box, the dates, the pixel size) re-runs
  it on the next `tar_make()`.
- **Everything else is cheap, but not free.** On a fresh copy of the repo,
  your machine has no record of earlier runs, so `tar_make()` rebuilds the
  vessel tables, the test month, the summaries and the site data. That's
  about $3.
- **Every query has a cap.** Caps on how much each query may read are set in
  `max_tb_billed` in [config.R](config.R), so a mistake fails instead of
  running up a bill.

**Updating the site.** Edit the page in [qmd/](qmd/), run
`targets::tar_make(names = "site")` to render it into [docs/](docs/), check
`docs/index.html` in a browser, then commit `docs/` and push to `main`.
GitHub Pages serves whatever is in `main/docs`. The site reads only the files
in `data/`, so this needs no BigQuery access.

## Layout

```
_targets.R            pipeline entry point
config.R              BigQuery settings, cost caps, the scan switch, GFW source tables
targets/parameters.R  dates, study area box, pixel size
targets/ais.R         vessels, pixel tables, download sizes, the data/ files
targets/report.R      the site's coastline layer and render
sql/ais/              the SQL behind each table
r/functions.R         helper functions (BigQuery, checks, study area, site)
r/bq_table_docs.R     table and column descriptions, written into BigQuery
data/                 small data files and the study area box (see data/README.md)
qmd/                  the site's source (Quarto)
docs/                 the rendered site, served by GitHub Pages
renv.lock, renv/      pinned package versions
```

**Code style:** explicit `package::function()` calls (no `library()`), the
base pipe `|>`, and tidyverse style. The setup follows
[emlab-ucsb/fishing-effort-drivers](https://github.com/emlab-ucsb/fishing-effort-drivers).

## Sources

AIS data and models are from [Global Fishing Watch](https://globalfishingwatch.org)
(pipeline 5); credit GFW whenever you use or show this data. Coastlines are
from [Natural Earth](https://www.naturalearthdata.com). Claude (Anthropic)
was used as a coding assistant; the site's last section describes how.
