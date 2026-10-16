# =============================================================================
# Shared configuration for the mesm-gp-ne-pacific-high-seas-mpa targets
# pipeline. Sourced at the top of _targets.R. Single source of truth for the run
# version, BigQuery settings, cost guards, and the upstream GFW tables we read.
# =============================================================================

# ---- Run version -------------------------------------------------------------
# Version suffix for every table this pipeline writes. Bump for a from-scratch
# rebuild (outputs land in new tables; old ones are left in place).
run_version_value <- "_v20261016"

# ---- BigQuery ----------------------------------------------------------------
bq_project <- "emlab-gcp"
bq_dataset <- "mesm_gp_ne_pacific_high_seas"
billing_project <- "emlab-gcp"
# The GFW tables we read are in the US multi-region, and BigQuery writes query
# results only to a dataset in the same location.
bq_location <- "US"

# Non-interactive auth: reuse the cached gargle token for this machine (run
# bigrquery::bq_auth() once interactively to create it). If you have tokens
# cached for more than one Google account, set the one to use in .Renviron
# (GARGLE_OAUTH_EMAIL=you@ucsb.edu).
gargle_email <- Sys.getenv("GARGLE_OAUTH_EMAIL")
options(gargle_oauth_email = if (nzchar(gargle_email)) gargle_email else TRUE)
# Helps download big results from BQ without the Storage API
options(bigrquery.bigquery_download_use_storage_api = FALSE)

# ---- Cost guards -------------------------------------------------------------
# emlab-gcp pays on-demand, by bytes scanned (~$6.25 per TiB). Every query
# passes one of these caps to BigQuery as maximumBytesBilled, so a query that
# would scan more fails before it runs and costs nothing.
max_tb_billed <- list(
  # Vessel identity tables: well under 1 GB each
  vessel_info = 0.05,
  # One month of AIS positions: ~0.3 TB (dry run, 2026-10-16)
  ais_test_month = 0.5,
  # Every AIS position, 2015-01 to 2026-08: ~19.0 TB (dry run, 2026-10-16)
  ais_full_window = 22
)

# The full AIS position scan (~19.0 TB, ~$108) is only part of the pipeline
# when this is TRUE, so a bare targets::tar_make() cannot start it by accident.
# It was built on 2026-10-16 (ais_effort_by_pixel_v20261016). With FALSE, the
# table is frozen: everything downstream (summaries, download sizes, site data)
# reads the table already in BigQuery, and the scan never re-runs. That also
# keeps a fresh clone, which has no record of the earlier run, from re-running
# it. Set TRUE only to rebuild the table on purpose; any change upstream of the
# scan (its SQL, the vessel list, the window, the box, the pixel size) then
# re-runs it on the next tar_make(), so run targets::tar_outdated() first.
run_full_ais_scan <- FALSE

# ---- Upstream GFW tables (read-only, maintained outside this pipeline) --------
# targets cannot see when these change, so each has a pin target in
# targets/ais.R; bump the pin to re-run against the current remote data.
upstream_tables <- list(
  # GFW AIS vessel identity (pipeline v5), one row per vessel (ssvid)
  # summarising its whole AIS record (2012 to present): the pipeline 5 random
  # forest's vessel class, fishing-vessel call and engine power
  # (random_forest_info), flag, the offsetting and shared-MMSI flags, and its
  # lat/lon extent. Activity runs to 2026-08-31 as of 2026-10-16, which sets the
  # end of the data window.
  ais_vessel_info = "global-fishing-watch.pipe_ais_identity_v5_partners_published.vi_ssvid",
  # The same, one row per vessel and year. Used only for each vessel's yearly
  # lat/lon extent in the vessel class summary.
  ais_vessel_info_by_year = "global-fishing-watch.pipe_ais_identity_v5_partners_published.vi_ssvid_byyear",
  # GFW UDF: TRUE when a vessel class is a fishing class.
  ais_is_fishing_udf = "global-fishing-watch.udfs.is_fishing",
  # GFW AIS positions (pipeline v5), one row per message, with hours, fishing
  # scores and clean_segs. A view; it is not clustered on position, so a
  # lat/lon filter does not reduce the bytes scanned, only the date filter does.
  ais_messages = "global-fishing-watch.pipe_ais_v5_published.messages"
)
