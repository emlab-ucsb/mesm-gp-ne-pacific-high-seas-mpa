# AIS hours and kW-hours in the study area.
#
#   1. the output BigQuery dataset (created if it does not exist),
#   2. the list of AIS vessels in the analysis, fishing and non-fishing: every
#      GFW vessel with a pipeline 5 random forest class other than NULL or
#      'gear' and an engine power, that was never noisy by GFW's definition,
#   3. how many vessels there are of each class, from the vessel identity
#      tables alone, to check before any position is read,
#   4. hours and kW-hours per pixel, month, vessel class, fishing vessel or
#      not and fishing activity or not, first for one test month (~0.3 TB) and
#      then, once
#      run_full_ais_scan is TRUE in config.R, for the whole window (~19.0 TB,
#      the one expensive query in the pipeline).
#
# Conventions:
#   - prefix every target, BigQuery table, SQL file and data/ file with ais_,
#   - give each new upstream table an entry in `upstream_tables` (config.R)
#     and a pin target here,
#   - give every query a cap from `max_tb_billed` (config.R),
#   - document every table in r/bq_table_docs.R.

# fishing_vessel must be TRUE for exactly the fishing classes (GFW's
# is_fishing UDF) in every row of every table that carries both. GFW's fishing
# call and the class agree in pipeline 5; if they ever stop agreeing, the build
# fails and the definition of a fishing vessel needs a decision.
fishing_vessel_disagrees_with_class <- sprintf(
  "fishing_vessel != IFNULL(`%s`(vessel_class), FALSE)",
  upstream_tables$ais_is_fishing_udf
)

# Rules the vessel list must never break, checked on every build (see
# assert_no_forbidden_rows() in r/functions.R).
ais_vessels_forbidden_rows <- c(
  "vessel with no class, or fishing gear" = "vessel_class IS NULL OR vessel_class = 'gear'",
  "vessel with no engine power" = "engine_power_kw IS NULL",
  "fishing-vessel call disagrees with vessel class" = fishing_vessel_disagrees_with_class,
  # vessel_class differs from the random forest class only where generic
  # 'fishing' took the vessel's own atomic class
  "vessel class changed other than from generic 'fishing' to its atomic class" = paste(
    "vessel_class != rf_vessel_class",
    "AND NOT (rf_vessel_class = 'fishing' AND vessel_class = rf_atomic_class)"
  )
)

# Grain and rules of the pixel tables: fishing_vessel matches the class in
# every row, and fishing activity only ever comes from fishing vessels, so
# never from a non-fishing vessel class.
ais_effort_by_pixel_unique_key <- c(
  "month", "lon_center", "lat_center", "vessel_class", "fishing_vessel", "fishing_activity"
)
ais_effort_by_pixel_forbidden_rows <- c(
  "fishing-vessel call disagrees with vessel class" = fishing_vessel_disagrees_with_class,
  "fishing activity from a vessel that is not a fishing vessel" = "fishing_activity AND NOT fishing_vessel",
  "fishing activity from a non-fishing vessel class" = sprintf(
    "fishing_activity AND NOT IFNULL(`%s`(vessel_class), FALSE)",
    upstream_tables$ais_is_fishing_udf
  ),
  "vessel with no class, or fishing gear" = "vessel_class IS NULL OR vessel_class = 'gear'"
)
ais_effort_by_pixel_cluster_fields <- c("fishing_activity", "fishing_vessel", "vessel_class")

ais_targets <- list(
  ## Parameters ----
  # Gears for which a vessel the random forest calls only generic 'fishing'
  # takes the model's finest-level (atomic) class instead: the fishing classes
  # GFW says the atomic class predicts well (Pipe5 Release Notes, Appendix E:
  # "gear, set_gillnets, tuna_purse_seines, trawlers, drifting_longlines,
  # squid_jigger"; gear is excluded from the analysis).
  targets::tar_target(
    ais_trusted_atomic_classes,
    c("trawlers", "drifting_longlines", "set_gillnets", "tuna_purse_seines", "squid_jigger")
  ),

  ## Output dataset ----
  targets::tar_target(
    bq_output_dataset,
    ensure_bq_dataset(
      bq_project = bq_project,
      bq_dataset = bq_dataset,
      location = bq_location,
      description = docs_bq_dataset
    )
  ),

  ## Pinned upstream AIS tables ----
  # Maintained outside this pipeline and targets cannot see when they change.
  # Bump `pinned` to force the consumer queries to re-run against the current
  # remote data.
  targets::tar_target(
    ais_vessel_info_pin,
    # -> ais_vessels_bq, ais_vessel_class_summary_bq
    list(
      table = c(
        upstream_tables$ais_vessel_info,
        upstream_tables$ais_vessel_info_by_year,
        upstream_tables$ais_is_fishing_udf
      ),
      pinned = "2026-10-16"
    )
  ),
  targets::tar_target(
    ais_messages_pin,
    # -> ais_effort_by_pixel_test_bq, ais_effort_by_pixel_bq
    list(table = upstream_tables$ais_messages, pinned = "2026-10-16")
  ),

  ## Vessel list ----
  # Every vessel, fishing and non-fishing, with a random forest class other
  # than NULL or 'gear' and an engine power, never noisy, that broadcast AIS
  # at some point in the window. One row per ssvid.
  tarchetypes::tar_file_read(
    name = ais_vessels_bq,
    command = "sql/ais/ais_vessels.sql",
    read = run_bq_query_and_save_table(
      sql = readr::read_file(!!.x) |>
        glue::glue(
          ais_vessel_info_table = upstream_tables$ais_vessel_info,
          trusted_atomic_classes = sql_string_list(ais_trusted_atomic_classes),
          window_start_date = window_start_date,
          window_end_date = window_end_date,
          # Dependency only: the dataset must exist before we write to it, and
          # bumping the pin refreshes against new upstream data
          .bq_output_dataset = bq_output_dataset,
          .ais_vessel_info_pin = ais_vessel_info_pin
        ),
      bq_table_name = paste0("ais_vessels", run_version),
      bq_dataset = bq_dataset,
      bq_project = bq_project,
      billing_project = billing_project,
      max_tb_billed = max_tb_billed$vessel_info,
      # Grain contract: build fails if this key is ever duplicated.
      unique_key = c("ssvid"),
      forbidden_rows = ais_vessels_forbidden_rows,
      description = glue::glue(
        docs_ais_vessels$description,
        trusted_atomic_classes = paste(ais_trusted_atomic_classes, collapse = ", "),
        window_start_date = window_start_date,
        window_end_date = window_end_date
      ),
      field_descriptions = docs_ais_vessels$fields
    )
  ),

  ## Vessels per class ----
  # Read before the position scan: how many vessels of each class there are,
  # how many the filters drop, and how many could be in the study area.
  tarchetypes::tar_file_read(
    name = ais_vessel_class_summary_bq,
    command = "sql/ais/ais_vessel_class_summary.sql",
    read = run_bq_query_and_save_table(
      sql = readr::read_file(!!.x) |>
        glue::glue(
          ais_vessel_info_table = upstream_tables$ais_vessel_info,
          ais_vessel_info_by_year_table = upstream_tables$ais_vessel_info_by_year,
          ais_vessels_table = bq_table_full_name(ais_vessels_bq),
          is_fishing_udf = upstream_tables$ais_is_fishing_udf,
          window_start_date = window_start_date,
          window_end_date = window_end_date,
          first_year = format(as.Date(window_start_date), "%Y"),
          last_year = format(as.Date(window_end_date), "%Y"),
          lon_min = study_area_bbox[["lon_min"]],
          lon_max = study_area_bbox[["lon_max"]],
          lat_min = study_area_bbox[["lat_min"]],
          lat_max = study_area_bbox[["lat_max"]],
          # Dependency only: bump the pin to refresh against new upstream data
          .ais_vessel_info_pin = ais_vessel_info_pin
        ),
      bq_table_name = paste0("ais_vessel_class_summary", run_version),
      bq_dataset = bq_dataset,
      bq_project = bq_project,
      billing_project = billing_project,
      max_tb_billed = max_tb_billed$vessel_info,
      unique_key = c("vessel_class"),
      description = glue::glue(
        docs_ais_vessel_class_summary$description,
        window_start_date = window_start_date,
        window_end_date = window_end_date,
        first_year = format(as.Date(window_start_date), "%Y"),
        last_year = format(as.Date(window_end_date), "%Y"),
        lon_min = study_area_bbox[["lon_min"]],
        lon_max = study_area_bbox[["lon_max"]],
        lat_min = study_area_bbox[["lat_min"]],
        lat_max = study_area_bbox[["lat_max"]]
      ),
      field_descriptions = docs_ais_vessel_class_summary$fields
    )
  ),
  targets::tar_target(
    name = ais_vessel_class_summary_csv,
    command = download_bq_table_to_csv(
      ais_vessel_class_summary_bq,
      path = "data/ais_vessel_class_summary.csv",
      billing_project = billing_project,
      order_by = c("n_vessels_kept_study_area DESC", "vessel_class")
    ),
    format = "file"
  ),

  ## Hours and kW-hours per pixel: test month ----
  # The same query as the full table, for ais_test_month only (~0.3 TB). Check
  # its size and contents before setting run_full_ais_scan in config.R.
  tarchetypes::tar_file_read(
    name = ais_effort_by_pixel_test_bq,
    command = "sql/ais/ais_effort_by_pixel.sql",
    read = run_bq_query_and_save_table(
      sql = readr::read_file(!!.x) |>
        glue::glue(
          ais_vessels_table = bq_table_full_name(ais_vessels_bq),
          ais_messages_table = upstream_tables$ais_messages,
          start_date = ais_test_month,
          end_date = month_end_date(ais_test_month),
          lon_min = study_area_bbox[["lon_min"]],
          lon_max = study_area_bbox[["lon_max"]],
          lat_min = study_area_bbox[["lat_min"]],
          lat_max = study_area_bbox[["lat_max"]],
          pixel_size = pixel_size,
          # Dependency only: bump the pin to refresh against new upstream data
          .ais_messages_pin = ais_messages_pin
        ),
      bq_table_name = paste0("ais_effort_by_pixel_test", run_version),
      bq_dataset = bq_dataset,
      bq_project = bq_project,
      billing_project = billing_project,
      max_tb_billed = max_tb_billed$ais_test_month,
      unique_key = ais_effort_by_pixel_unique_key,
      forbidden_rows = ais_effort_by_pixel_forbidden_rows,
      partition_month_field = "month",
      cluster_fields = ais_effort_by_pixel_cluster_fields,
      description = glue::glue(
        docs_ais_effort_by_pixel$description,
        start_date = ais_test_month,
        end_date = month_end_date(ais_test_month),
        snap_deg = study_area_snap_deg,
        lon_min = study_area_bbox[["lon_min"]],
        lon_max = study_area_bbox[["lon_max"]],
        lat_min = study_area_bbox[["lat_min"]],
        lat_max = study_area_bbox[["lat_max"]],
        pixel_size = pixel_size
      ),
      field_descriptions = docs_ais_effort_by_pixel$fields
    )
  ),
  # Rows and GB of the test month, scaled to every month of the window: a rough
  # size for the full table (rough because AIS reception grows over the
  # window, so earlier months are smaller).
  targets::tar_target(
    ais_effort_by_pixel_test_size,
    project_bq_table_size(
      ais_effort_by_pixel_test_bq,
      n_months = 1,
      n_months_full = n_months_in_window(window_start_date, window_end_date)
    )
  ),
  # Pixels, hours and kW-hours per vessel class, fishing vessel or not and
  # fishing activity or not, in the test month.
  tarchetypes::tar_file_read(
    name = ais_effort_by_pixel_test_summary_csv,
    command = "sql/ais/ais_effort_by_pixel_summary.sql",
    read = readr::read_file(!!.x) |>
      glue::glue(
        ais_effort_by_pixel_table = bq_table_full_name(ais_effort_by_pixel_test_bq)
      ) |>
      download_bq_query(billing_project = billing_project) |>
      dplyr::arrange(month, dplyr::desc(hours)) |>
      round_doubles() |>
      write_csv_file("data/ais_effort_by_pixel_test_month_summary.csv"),
    format = "file"
  ),

  ## Hours and kW-hours per pixel: full window ----
  # Every AIS position from window_start_date to window_end_date (~19.0 TB,
  # ~$108 on-demand). Part of the pipeline only when run_full_ais_scan is TRUE
  # in config.R. Once built, it re-runs whenever its SQL, the vessel list, the
  # window, the box or the pixel size changes: check targets::tar_outdated()
  # before targets::tar_make(). Its BigQuery documentation is written by a
  # separate target (ais_effort_by_pixel_docs), so editing the docs does not
  # re-run the scan.
  if (run_full_ais_scan) {
    list(
      tarchetypes::tar_file_read(
        name = ais_effort_by_pixel_bq,
        command = "sql/ais/ais_effort_by_pixel.sql",
        read = run_bq_query_and_save_table(
          sql = readr::read_file(!!.x) |>
            glue::glue(
              ais_vessels_table = bq_table_full_name(ais_vessels_bq),
              ais_messages_table = upstream_tables$ais_messages,
              start_date = window_start_date,
              end_date = window_end_date,
              lon_min = study_area_bbox[["lon_min"]],
              lon_max = study_area_bbox[["lon_max"]],
              lat_min = study_area_bbox[["lat_min"]],
              lat_max = study_area_bbox[["lat_max"]],
              pixel_size = pixel_size,
              # Dependency only: bump the pin to refresh against new upstream data
              .ais_messages_pin = ais_messages_pin
            ),
          bq_table_name = paste0("ais_effort_by_pixel", run_version),
          bq_dataset = bq_dataset,
          bq_project = bq_project,
          billing_project = billing_project,
          max_tb_billed = max_tb_billed$ais_full_window,
          unique_key = ais_effort_by_pixel_unique_key,
          forbidden_rows = ais_effort_by_pixel_forbidden_rows,
          partition_month_field = "month",
          cluster_fields = ais_effort_by_pixel_cluster_fields,
          # Documented by ais_effort_by_pixel_docs below
          description = NULL,
          field_descriptions = NULL
        )
      ),
      targets::tar_target(
        ais_effort_by_pixel_docs,
        set_bq_table_documentation(
          bigrquery::bq_table(
            ais_effort_by_pixel_bq$tableReference$projectId,
            ais_effort_by_pixel_bq$tableReference$datasetId,
            ais_effort_by_pixel_bq$tableReference$tableId
          ),
          description = glue::glue(
            docs_ais_effort_by_pixel$description,
            start_date = window_start_date,
            end_date = window_end_date,
            snap_deg = study_area_snap_deg,
            lon_min = study_area_bbox[["lon_min"]],
            lon_max = study_area_bbox[["lon_max"]],
            lat_min = study_area_bbox[["lat_min"]],
            lat_max = study_area_bbox[["lat_max"]],
            pixel_size = pixel_size
          ),
          field_descriptions = docs_ais_effort_by_pixel$fields
        )
      )
    )
  },

  ## The pixel table, for everything downstream ----
  # Everything below reads the pixel table through this target. With
  # run_full_ais_scan TRUE it is the scan's own output; with FALSE (the
  # default) it is the table already in BigQuery, re-read on every run (one
  # free metadata call), so the summaries, download sizes and site data keep
  # working while the scan is frozen. Only fields that change when the table
  # is rewritten are kept, so a re-read alone never triggers a rebuild.
  if (run_full_ais_scan) {
    targets::tar_target(
      ais_effort_by_pixel_table,
      stable_bq_table_meta(ais_effort_by_pixel_bq)
    )
  } else {
    targets::tar_target(
      ais_effort_by_pixel_table,
      read_bq_table_meta(bq_project, bq_dataset, paste0("ais_effort_by_pixel", run_version)) |>
        stable_bq_table_meta(),
      cue = targets::tar_cue(mode = "always")
    )
  },

  ## Monthly summary ----
  # Pixels, hours and kW-hours per month, vessel class, fishing vessel or not
  # and fishing activity or not.
  tarchetypes::tar_file_read(
    name = ais_effort_by_pixel_summary_csv,
    command = "sql/ais/ais_effort_by_pixel_summary.sql",
    read = readr::read_file(!!.x) |>
      glue::glue(
        ais_effort_by_pixel_table = bq_table_full_name(ais_effort_by_pixel_table)
      ) |>
      download_bq_query(billing_project = billing_project) |>
      dplyr::arrange(month, dplyr::desc(hours)) |>
      round_doubles() |>
      write_csv_file("data/ais_effort_by_pixel_summary.csv"),
    format = "file"
  ),

  ## Download sizes ----
  # How many rows, and roughly how big a CSV, the pixel table would be at a
  # few resolutions and time steps, and with a couple of filters. Computed in
  # BigQuery (~0.2 TB in all); add a row to size another cut.
  targets::tar_target(
    ais_download_cuts,
    tibble::tribble(
      ~cut, ~pixel_size, ~time, ~year, ~fishing_activity_only,
      "Full table (0.01 deg, monthly)", 0.01, "month", NA, FALSE,
      "0.01 deg, yearly", 0.01, "year", NA, FALSE,
      "0.01 deg, all years summed", 0.01, "all", NA, FALSE,
      "0.05 deg, monthly", 0.05, "month", NA, FALSE,
      "0.05 deg, yearly", 0.05, "year", NA, FALSE,
      "0.05 deg, all years summed", 0.05, "all", NA, FALSE,
      "0.1 deg, monthly", 0.1, "month", NA, FALSE,
      "0.1 deg, yearly", 0.1, "year", NA, FALSE,
      "0.1 deg, all years summed", 0.1, "all", NA, FALSE,
      "2025 only, 0.01 deg, monthly", 0.01, "month", 2025, FALSE,
      "2025 only, 0.1 deg, monthly", 0.1, "month", 2025, FALSE,
      "Fishing activity only, 0.01 deg, monthly", 0.01, "month", NA, TRUE,
      "Fishing activity only, 0.05 deg, yearly", 0.05, "year", NA, TRUE,
      "Fishing activity only, 0.1 deg, yearly", 0.1, "year", NA, TRUE
    )
  ),
  targets::tar_target(
    ais_download_sizes_csv,
    estimate_csv_sizes(
      ais_effort_by_pixel_table,
      cuts = ais_download_cuts,
      billing_project = billing_project
    ) |>
      round_doubles(significant_digits = 3) |>
      write_csv_file("data/ais_effort_by_pixel_download_sizes.csv"),
    format = "file"
  ),

  ## Site data ----
  # Two coarse cuts of the pixel table, gzipped and committed so the Quarto
  # site (qmd/) renders on GitHub Actions without BigQuery. 0.05 degrees
  # matches the project's other cost layers. write_csv_file() fails if either
  # passes GitHub's 50 MB limit.
  tarchetypes::tar_file_read(
    name = ais_effort_by_pixel_0p05deg_all_years_csv,
    command = "sql/ais/ais_effort_by_pixel_coarse_all_years.sql",
    read = readr::read_file(!!.x) |>
      glue::glue(
        ais_effort_by_pixel_table = bq_table_full_name(ais_effort_by_pixel_table),
        pixel_size = 0.05
      ) |>
      download_bq_query_to_csv(
        path = "data/ais_effort_by_pixel_0p05deg_all_years.csv.gz",
        billing_project = billing_project
      ),
    format = "file"
  ),
  tarchetypes::tar_file_read(
    name = ais_fishing_activity_by_pixel_0p05deg_yearly_csv,
    command = "sql/ais/ais_fishing_activity_by_pixel_coarse_yearly.sql",
    read = readr::read_file(!!.x) |>
      glue::glue(
        ais_effort_by_pixel_table = bq_table_full_name(ais_effort_by_pixel_table),
        pixel_size = 0.05,
        window_end_date = window_end_date
      ) |>
      download_bq_query_to_csv(
        path = "data/ais_fishing_activity_by_pixel_0p05deg_yearly.csv.gz",
        billing_project = billing_project
      ),
    format = "file"
  )
)
