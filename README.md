# Vessel activity in the Northeast Pacific: the AIS cost layer

*Gavin McDonald, emLab (UCSB), technical advisor to the Bren MESM group
project.*

**Site: <https://emlab-ucsb.github.io/mesm-gp-ne-pacific-high-seas-mpa/>**

Hi all, and welcome! This repo builds the vessel activity data for our
project,
[New Wave of High Seas Protections: Scoping Northern Seamount Ecosystems under BBNJ](https://bren.ucsb.edu/projects/new-wave-high-seas-protections-scoping-northern-seamount-ecosystems-under-biodiversity),
where we're working out which areas along the Cobb-Eickelberg seamount chain
might be good candidates for protection. It turns Global Fishing Watch (GFW)
AIS data into a gridded cost layer: hours and kilowatt-hours of vessel
activity per pixel and month, split by vessel type and into fishing and
non-fishing activity, from January 2015 to August 2026.

## Where to start

**The site is the best place to start:**
<https://emlab-ucsb.github.io/mesm-gp-ne-pacific-high-seas-mpa/>. It has the
maps, the files you can start working with (including our 2025 cost layer), a
table of the bigger datasets available and how big each one is, what every
column means, and a few things to keep in mind.

**The data you'll probably want first** is our main cost layer:
[data/ais_effort_by_pixel_0p05deg_2025.csv.gz](data/ais_effort_by_pixel_0p05deg_2025.csv.gz),
all vessel activity at 0.05° for 2025. Everything in [data/](data/) is ready
to read straight into R, and the [data README](data/README.md) describes every
column. If you need something bigger or different from BigQuery, just let me
know and I'm happy to pull it for you.

The rest of this README is about what's under the hood and how to reproduce
it, in case you're curious or want to build on it.

## What's in here

- **BigQuery tables** in `emlab-gcp.mesm_gp_ne_pacific_high_seas`, each
  documented in BigQuery itself (the Details and Schema tabs in the console):
  - `ais_effort_by_pixel_v20261016`: the full table. One row per month,
    0.01° pixel, vessel class, fishing vessel and fishing activity, with
    `hours` and `kw_hours`. 262 million rows, 13 GB.
  - `ais_vessels_v20261016`: the vessels in the analysis, with each one's
    class, fishing-vessel call, flag and engine power.
  - `ais_vessel_class_summary_v20261016`: vessel counts by class.
  - `ais_effort_by_pixel_test_v20261016`: one test month (July 2025) that I
    built before running the full scan.
- **Small data files in [data/](data/)**, including our 2025 cost layer, that
  you can read straight into R.
- **The site,** written in [qmd/](qmd/) and rendered into [docs/](docs/),
  which GitHub Pages serves.

## How it works

It's a [targets](https://books.ropensci.org/targets/) pipeline in R, with
the heavy lifting done in BigQuery SQL and package versions pinned with
[renv](https://rstudio.github.io/renv/). In a nutshell:

1. **Vessels.** I start from GFW's pipeline 5 vessel identity table for each
   vessel's class, fishing-vessel call and engine power, and leave out
   fishing gear, vessels GFW couldn't classify, and MMSIs that were ever
   noisy (from every year).
2. **Pixels.** Every AIS position in our study area box from January 2015 to
   August 2026 gets scored as fishing or not, binned into 0.01° pixels, and
   summed by month. This is the one big query: it reads 19 TB.
3. **Everything downstream.** The download-size estimates, the small files
   in `data/`, and the site.

The pipeline checks every table each time it runs: no duplicate rows,
`fishing_vessel` always matching the vessel class, and no fishing activity
from non-fishing vessels. If anything looks off, it stops so we can take a
look. The vessel and fishing definitions follow GFW's
[pipeline 5 release notes for research partners](https://docs.google.com/document/d/1wFtKu_6ixCGCfmTk3j6UPbKBgFrQdJ_BtrGiooC0yDQ/edit)
(September 2026), which are well worth a read, especially if you're working
with vessel types.

## Running it yourself

**Getting set up:**

1. Open `mesm-gp-ne-pacific-high-seas-mpa.Rproj` (or the folder in Positron).
2. Run `renv::restore()` to install the same package versions I used.
3. Run `bigrquery::bq_auth()` once to log in with a Google account that has
   BigQuery access to `emlab-gcp`. That needs an emLab account, so if you
   don't have one, no worries: I'm happy to run the pipeline or pull data for
   you. If you have more than one Google account cached, adding
   `GARGLE_OAUTH_EMAIL=you@ucsb.edu` to a `.Renviron` file in the project
   tells it which one to use.

**Running the pipeline:**

```r
targets::tar_visnetwork()  # see the pipeline and what's out of date
targets::tar_outdated()    # list what would re-run
targets::tar_make()        # run whatever is out of date
```

**A note on costs.** BigQuery charges by how much data each query reads
(about $6.25 per TiB), so I've built in a few guardrails:

- **The big 19 TB scan (~$108) is switched off.** In [config.R](config.R),
  `run_full_ais_scan` is `FALSE`, which freezes the full table: everything
  downstream reads the table that's already in BigQuery, and the big scan
  never re-runs. If we ever need to rebuild it, we can flip that to `TRUE`,
  but let's chat first so it doesn't run by accident. While it's `TRUE`,
  changing anything upstream of the scan (its SQL, the vessel filters, the
  box, the dates, the pixel size) re-runs it on the next `tar_make()`.
- **Everything else is cheap, though not quite free.** On a fresh copy of
  the repo, your machine doesn't know about earlier runs, so `tar_make()`
  rebuilds the vessel tables, the test month, the summaries and the site
  data. That comes to about $3.
- **Every query has a cap** on how much it can read (`max_tb_billed` in
  [config.R](config.R)), so if something goes wrong, it fails safely
  instead of running up a bill.

**Updating the site.** Edit the page in [qmd/](qmd/), run
`targets::tar_make(names = "site")` to render it into [docs/](docs/), have a
look at `docs/index.html` in your browser, then commit `docs/` and push to
`main`. GitHub Pages takes it from there. The site only reads the files in
`data/`, so you don't need BigQuery access for this part.

## Where things live

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

The code uses explicit `package::function()` calls (no `library()`), the
base pipe `|>`, and tidyverse style, and it's set up the same way as
[emlab-ucsb/fishing-effort-drivers](https://github.com/emlab-ucsb/fishing-effort-drivers).

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
2026."

For more on how GFW builds the data, especially how vessel types are
assigned, GFW's
[pipeline 5 release notes for research partners](https://docs.google.com/document/d/1wFtKu_6ixCGCfmTk3j6UPbKBgFrQdJ_BtrGiooC0yDQ/edit)
(September 2026) are the place to look. Coastlines on the site come from
[Natural Earth](https://www.naturalearthdata.com), and Claude (Anthropic)
helped as a coding assistant; the site's last section has the details.

## Questions?

If anything's unclear, looks off, or you'd like the data cut a different way,
just reach out. I'm always happy to help!
