# Helper functions for the mesm-gp-ne-pacific-high-seas-mpa targets pipeline.
#
# Conventions: base pipe, explicit pkg::fun() calls everywhere, BigQuery via
# bigrquery. The BigQuery helpers (assert_unique_key, set_bq_table_documentation,
# run_bq_query_and_save_table, download_bq_table_to_csv) are adapted from the
# emLab fishing-effort-drivers pipeline so the repos behave the same way.

# ---- Grain assertions -------------------------------------------------------

# Assert that a BigQuery table has exactly one row per `unique_key`.
#
# The standing defence against the duplicate-row class of bug: a duplicated key
# silently multiplies any SUM() downstream, so every table whose grain we
# depend on declares it and is checked on every build.
assert_unique_key <- function(bq_table, unique_key, billing_project) {
  tbl <- bq_table_full_name(bq_table)
  keys <- paste(unique_key, collapse = ", ")
  sql <- sprintf(
    "SELECT %s, COUNT(*) AS n_rows
     FROM `%s`
     GROUP BY %s
     HAVING COUNT(*) > 1
     ORDER BY n_rows DESC
     LIMIT 5",
    keys, tbl, keys
  )
  dupes <- download_bq_query(sql, billing_project = billing_project)
  if (nrow(dupes) > 0) {
    examples <- paste(
      utils::capture.output(print(as.data.frame(dupes), row.names = FALSE)),
      collapse = "\n  "
    )
    stop(sprintf(
      paste0(
        "Grain assertion FAILED for `%s`.\n",
        "  Expected one row per (%s), but found duplicates.\n",
        "  Worst offenders (up to 5):\n  %s\n",
        "Do NOT use this table: a duplicated key silently multiplies any ",
        "SUM()/COUNT(*) downstream. Find where the fan-out is introduced and ",
        "fix it there rather than deduping the output."
      ),
      tbl, keys, examples
    ), call. = FALSE)
  }
  invisible(TRUE)
}

# Assert that no row of a BigQuery table matches any of `forbidden_rows`, a
# named character vector of SQL conditions (name -> condition), e.g.
#   c("fishing activity from a non-fishing vessel" = "fishing_activity AND NOT fishing_vessel")
#
# For rules a table must never break, such as fishing activity only ever
# coming from fishing vessels, checked on every build so that a change to the
# SQL (or to GFW's tables) that breaks one fails loudly.
assert_no_forbidden_rows <- function(bq_table, forbidden_rows, billing_project) {
  stopifnot(is.character(forbidden_rows), !is.null(names(forbidden_rows)))
  tbl <- bq_table_full_name(bq_table)
  counts <- sprintf("COUNTIF(%s) AS check_%d", forbidden_rows, seq_along(forbidden_rows))
  sql <- sprintf("SELECT %s FROM `%s`", paste(counts, collapse = ", "), tbl)
  result <- download_bq_query(sql, billing_project = billing_project)
  n_bad <- vapply(result, as.numeric, numeric(1))
  if (any(n_bad > 0)) {
    failed <- sprintf(
      "  %s (%s): %s rows",
      names(forbidden_rows), forbidden_rows, format(n_bad, big.mark = ",")
    )[n_bad > 0]
    stop(sprintf(
      "Forbidden-row assertion FAILED for `%s`:\n%s",
      tbl, paste(failed, collapse = "\n")
    ), call. = FALSE)
  }
  invisible(TRUE)
}

# ---- BigQuery table documentation --------------------------------------------

# Set a BigQuery table's description and the description of every column.
#
# Every table this pipeline creates is documented in BigQuery itself, because
# the BQ console is where collaborators meet these tables. bigrquery's
# bq_table_patch() only updates the schema, so this PATCHes the REST API
# directly (with bigrquery's token) to set `description` and the per-field
# descriptions in one call.
#
# `field_descriptions` is a named character vector, column -> description. The
# build fails if it names a column that does not exist (a typo, or a column
# dropped from the SQL) or if any existing column is left undocumented, so the
# docs in r/bq_table_docs.R cannot silently drift from the tables.
set_bq_table_documentation <- function(bq_table, description, field_descriptions) {
  stopifnot(is.character(description), length(description) == 1, nzchar(description))
  meta <- bigrquery::bq_table_meta(bq_table)
  fields <- meta$schema$fields
  column_names <- vapply(fields, function(f) f$name, character(1))

  missing_docs <- setdiff(column_names, names(field_descriptions))
  unknown_docs <- setdiff(names(field_descriptions), column_names)
  if (length(missing_docs) > 0 || length(unknown_docs) > 0) {
    stop(sprintf(
      paste0(
        "Column documentation for `%s` does not match its schema.\n",
        "  Undocumented columns: %s\n",
        "  Documented but not in table: %s\n",
        "Update r/bq_table_docs.R (or the SQL) so every column has a description."
      ),
      bq_table_full_name(bq_table),
      if (length(missing_docs)) paste(missing_docs, collapse = ", ") else "none",
      if (length(unknown_docs)) paste(unknown_docs, collapse = ", ") else "none"
    ), call. = FALSE)
  }

  documented_fields <- lapply(fields, function(f) {
    f$description <- unname(field_descriptions[[f$name]])
    f
  })
  body <- list(
    description = description,
    schema = list(fields = documented_fields)
  )
  url <- sprintf(
    "https://bigquery.googleapis.com/bigquery/v2/projects/%s/datasets/%s/tables/%s",
    bq_table$project, bq_table$dataset, bq_table$table
  )
  response <- httr::PATCH(
    url,
    body = jsonlite::toJSON(body, auto_unbox = TRUE, null = "null"),
    bigrquery::bq_token(),
    httr::add_headers(`Content-Type` = "application/json")
  )
  httr::stop_for_status(response, task = "document BigQuery table")
  invisible(bigrquery::bq_table_meta(bq_table))
}

# ---- BigQuery read / write helpers -------------------------------------------

# Create the output dataset if it does not exist yet, and check it is in the
# same location as the GFW tables we read (BigQuery writes query results only
# to a dataset in the source's location). Returns the dataset's identity, which
# the first table targets take as a dependency so the dataset exists before
# they write to it.
ensure_bq_dataset <- function(bq_project, bq_dataset, location, description) {
  dataset <- bigrquery::bq_dataset(bq_project, bq_dataset)
  if (!bigrquery::bq_dataset_exists(dataset)) {
    bigrquery::bq_dataset_create(dataset, location = location, description = description)
  }
  meta <- bigrquery::bq_dataset_meta(dataset)
  if (!identical(meta$location, location)) {
    stop(sprintf(
      "Dataset `%s.%s` is in %s, but the GFW tables are in %s. Query results cannot be written across locations.",
      bq_project, bq_dataset, meta$location, location
    ), call. = FALSE)
  }
  list(project = bq_project, dataset = bq_dataset, location = meta$location)
}

# "project.dataset.table" for either a bigrquery bq_table object or the table
# metadata list returned by bigrquery::bq_table_meta() (which is what the BQ
# targets under targets/ hold, so downstream queries can be templated from them).
bq_table_full_name <- function(x) {
  if (!is.null(x$tableReference)) {
    ref <- x$tableReference
    return(sprintf("%s.%s.%s", ref$projectId, ref$datasetId, ref$tableId))
  }
  sprintf("%s.%s.%s", x$project, x$dataset, x$table)
}

# A character vector as a SQL list of string literals, for IN (...):
# c("a", "b") -> "'a', 'b'".
sql_string_list <- function(x) {
  stopifnot(is.character(x), length(x) > 0, !any(grepl("'", x, fixed = TRUE)))
  paste0("'", x, "'", collapse = ", ")
}

# A cap in TB (10^12 bytes) as the string BigQuery wants for maximumBytesBilled.
tb_to_bytes_string <- function(tb) {
  format(round(tb * 1e12), scientific = FALSE, trim = TRUE)
}

# Run a SQL query and save the result as a BigQuery table. Returns the table
# metadata, which is what targets tracks to decide if downstream needs to rerun.
#
# Every query is capped at `max_tb_billed` TB scanned: BigQuery refuses a query
# that would scan more before it starts, so a mistake in a query (a dropped
# date filter, say) fails for free instead of scanning the whole AIS archive.
# The dry-run estimate is printed first so the pipeline log shows each
# query's size.
run_bq_query_and_save_table <- function(
  sql,
  bq_table_name,
  bq_dataset,
  bq_project,
  billing_project,
  max_tb_billed,
  # WRITE_TRUNCATE overwrites an existing table; WRITE_APPEND appends.
  write_disposition = "WRITE_TRUNCATE",
  # Character vector of columns the output must be unique on. When supplied the
  # table is checked after the write and the build FAILS on any duplicate.
  unique_key = NULL,
  # Named character vector of SQL conditions no row may match (see
  # assert_no_forbidden_rows()). Checked after the write; the build FAILS on any
  # match.
  forbidden_rows = NULL,
  # DATE column to partition the output table on by month, and up to four
  # columns to cluster it on. Both cut what later queries of the table scan.
  partition_month_field = NULL,
  cluster_fields = NULL,
  # Table description and named vector of column descriptions, written to the
  # table's metadata in BigQuery: every table we create is documented where
  # people find it. See set_bq_table_documentation(). Pass both as NULL only
  # for an expensive table that is documented by its own target instead, so
  # that editing its docs does not re-run the query.
  description,
  field_descriptions
) {
  bq_table <- bigrquery::bq_table(
    project = bq_project,
    dataset = bq_dataset,
    table = bq_table_name
  )

  estimated_bytes <- bigrquery::bq_perform_query_dry_run(sql, billing = billing_project)
  message(sprintf(
    "%s: dry run estimates %.3f TB scanned (cap %.3f TB)",
    bq_table_name, as.numeric(estimated_bytes) / 1e12, max_tb_billed
  ))

  query_config <- list(maximum_bytes_billed = tb_to_bytes_string(max_tb_billed))
  if (!is.null(partition_month_field)) {
    query_config$time_partitioning <- list(type = "MONTH", field = partition_month_field)
  }
  if (!is.null(cluster_fields)) {
    query_config$clustering <- list(fields = as.list(cluster_fields))
  }

  # BigQuery will not WRITE_TRUNCATE a table into a different partitioning or
  # clustering, so a table whose spec has changed is dropped first. The
  # truncate would have replaced its contents anyway.
  if (write_disposition == "WRITE_TRUNCATE" && bigrquery::bq_table_exists(bq_table)) {
    meta <- bigrquery::bq_table_meta(bq_table)
    old_partition_field <- meta$timePartitioning$field
    old_cluster_fields <- unlist(meta$clustering$fields)
    if (!identical(old_partition_field, partition_month_field) ||
        !identical(old_cluster_fields, cluster_fields)) {
      message(sprintf("%s: partitioning or clustering changed; replacing the table", bq_table_name))
      bigrquery::bq_table_delete(bq_table)
    }
  }

  bigrquery::bq_project_query(
    billing_project,
    sql,
    destination_table = bq_table,
    use_legacy_sql = FALSE,
    write_disposition = write_disposition,
    # Merged into the job body by bigrquery (snake_case -> camelCase).
    configuration = list(query = query_config),
    quiet = TRUE
  )

  if (!is.null(unique_key)) {
    assert_unique_key(bq_table, unique_key, billing_project)
  }
  if (!is.null(forbidden_rows)) {
    assert_no_forbidden_rows(bq_table, forbidden_rows, billing_project)
  }

  if (is.null(description) && is.null(field_descriptions)) {
    return(bigrquery::bq_table_meta(bq_table))
  }
  set_bq_table_documentation(bq_table, description, field_descriptions)
}

# Run a SQL query and download the result as a tibble (for small summaries).
download_bq_query <- function(sql, billing_project) {
  bigrquery::bq_project_query(billing_project, sql, quiet = TRUE) |>
    bigrquery::bq_table_download(n_max = Inf, quiet = TRUE)
}

# ---- Analysis window ---------------------------------------------------------

# Last day of the month that `month_start` falls in, as "YYYY-MM-DD".
month_end_date <- function(month_start) {
  next_month <- seq(as.Date(month_start), by = "month", length.out = 2)[2]
  format(next_month - 1)
}

# Number of calendar months from `start_date` to `end_date`, both included.
n_months_in_window <- function(start_date, end_date) {
  length(seq(floor_month(start_date), floor_month(end_date), by = "month"))
}

# First day of the month a date falls in.
floor_month <- function(date) {
  as.Date(format(as.Date(date), "%Y-%m-01"))
}

# ---- Study area --------------------------------------------------------------

# Read the study area shapefile and return its bounding box, snapped outward to
# a `snap_deg` grid, as c(lon_min, lon_max, lat_min, lat_max).
#
# The AIS query keeps a position when lon_min <= lon < lon_max and lat_min <=
# lat < lat_max, which is the same area as the shapefile only if the shapefile
# is one axis-aligned rectangle in WGS84 lon/lat. That is checked here, so a
# redrawn study area that is not a rectangle fails instead of being silently
# replaced by its bounding box. (Using the edges as plain lon/lat bounds also
# matches how the box was drawn: BigQuery's ST_INTERSECTS would treat the
# edges as great circles, which bow the 61.6 N edge northward.)
read_study_area_bbox <- function(shapefile, snap_deg) {
  area <- sf::st_read(shapefile, quiet = TRUE)
  if (nrow(area) != 1 || !identical(sf::st_crs(area)$epsg, 4326L)) {
    stop("The study area must be a single feature in WGS84 (EPSG:4326).", call. = FALSE)
  }
  bbox <- sf::st_bbox(area)
  vertices <- sf::st_coordinates(area)
  is_rectangle <- sf::st_is_valid(area) &&
    all(vertices[, "X"] %in% bbox[c("xmin", "xmax")]) &&
    all(vertices[, "Y"] %in% bbox[c("ymin", "ymax")])
  if (!is_rectangle) {
    stop(
      "The study area is not an axis-aligned lon/lat rectangle, so it cannot be applied as lat/lon bounds.",
      call. = FALSE
    )
  }

  # The small tolerance keeps an edge that is already on the grid (e.g. -120.0)
  # where it is, despite floating-point division.
  snapped <- c(
    lon_min = floor(bbox[["xmin"]] / snap_deg + 1e-9) * snap_deg,
    lon_max = ceiling(bbox[["xmax"]] / snap_deg - 1e-9) * snap_deg,
    lat_min = floor(bbox[["ymin"]] / snap_deg + 1e-9) * snap_deg,
    lat_max = ceiling(bbox[["ymax"]] / snap_deg - 1e-9) * snap_deg
  ) |>
    round(6)
  if (snapped[["lon_min"]] < -180 || snapped[["lon_max"]] > 180) {
    stop("The study area crosses the antimeridian, which the AIS query does not handle.", call. = FALSE)
  }
  snapped
}

# ---- Table size --------------------------------------------------------------

# Rows and size of a BigQuery table built from `n_months` months, and the same
# scaled to `n_months_full` months: a rough size for the full table, from a
# test month.
project_bq_table_size <- function(bq_table_meta, n_months, n_months_full) {
  rows <- as.numeric(bq_table_meta$numRows)
  gb <- as.numeric(bq_table_meta$numBytes) / 1e9
  tibble::tibble(
    table = bq_table_full_name(bq_table_meta),
    n_months = n_months,
    rows = rows,
    gb = gb,
    n_months_full = n_months_full,
    projected_rows = rows / n_months * n_months_full,
    projected_gb = gb / n_months * n_months_full
  )
}

# ---- Data files --------------------------------------------------------------
# Small tables the site needs are downloaded to data/ and committed, so the
# Quarto site renders, and the data can be used, without BigQuery credentials.
# Each helper returns the file path so the target can use format = "file".

# Download a whole BigQuery table (from its bq_table_meta) and write it as CSV.
#
# `significant_digits` rounds every double column before writing: BigQuery does
# not fix the order it aggregates in, so SUM() results wobble in the last float
# digit between runs and would rewrite every row of a committed file for no
# reason. signif() rather than round() keeps the precision relative.
download_bq_table_to_csv <- function(
  bq_table_meta,
  path,
  billing_project,
  order_by = NULL,
  significant_digits = 7
) {
  sql <- sprintf("SELECT * FROM `%s`", bq_table_full_name(bq_table_meta))
  if (!is.null(order_by)) {
    sql <- paste(sql, "ORDER BY", paste(order_by, collapse = ", "))
  }
  download_bq_query(sql, billing_project = billing_project) |>
    round_doubles(significant_digits) |>
    write_csv_file(path)
}

# Round every plain double column to `significant_digits`. Dates and timestamps
# are doubles underneath, and signif() would strip their class, so they are
# excluded explicitly rather than by type alone.
round_doubles <- function(data, significant_digits = 7) {
  is_plain_double <- function(x) {
    is.double(x) && !inherits(x, c("Date", "POSIXct", "POSIXlt", "difftime"))
  }
  data |>
    dplyr::mutate(dplyr::across(
      tidyselect::where(is_plain_double),
      ~ signif(.x, significant_digits)
    ))
}

# Fail if a file that will be committed is too big for GitHub. GitHub blocks
# files over 100 MB and warns over 50 MB, so anything the pipeline writes into
# the repo is checked against `limit_mb` (default 50) right after it is
# written. Aggregate it, or keep it in BigQuery / the shared drive instead of
# raising the limit. (The targets store itself is git-ignored.)
assert_under_github_size_limit <- function(path, limit_mb = 50) {
  size_mb <- file.size(path) / 1e6
  if (is.na(size_mb) || size_mb > limit_mb) {
    stop(sprintf(
      "%s is %.1f MB, over the %.0f MB limit for files committed to GitHub. Aggregate it before saving.",
      path, size_mb, limit_mb
    ), call. = FALSE)
  }
  invisible(path)
}

# Write a tibble to CSV, creating the directory if needed. Returns the path.
write_csv_file <- function(tibble_to_write, path) {
  dir.create(dirname(path), showWarnings = FALSE, recursive = TRUE)
  readr::write_csv(tibble_to_write, path, na = "")
  assert_under_github_size_limit(path)
  path
}

# ---- Download sizes ----------------------------------------------------------

# Rows and approximate CSV size of the pixel table at a few resolutions, time
# steps and filters, computed in BigQuery so nothing is downloaded. `cuts` has
# one row per cut, with columns
#   cut                     a label,
#   pixel_size              degrees (a multiple of the table's 0.01; pixels
#                           are coarsened from their centres),
#   time                    "month", "year" or "all" (summed over the window),
#   year                    NA for every year, or one year,
#   fishing_activity_only   TRUE to keep only fishing activity rows,
# plus any other columns (e.g. where the cut is available), which are passed
# through to the result. Every cut keeps the table's other columns
# (vessel_class, fishing_vessel, fishing_activity). The CSV size counts each field as
# download_bq_table_to_csv() would write it (doubles to 7 significant digits);
# checked against a real download on 2026-10-16, it matched to 0.1 MB in 36 MB.
estimate_csv_sizes <- function(bq_table_meta, cuts, billing_project, max_tb_billed = 0.1) {
  tbl <- bq_table_full_name(bq_table_meta)
  # Length of a double as readr writes it after signif(x, 7): plain digits
  # from 1e7 up, where FORMAT('%g') would switch to scientific notation.
  number_length <- function(x) {
    sprintf(
      "IFNULL(IF(ABS(%1$s) >= 1e7, LENGTH(FORMAT('%%.0f', %1$s)), LENGTH(FORMAT('%%.7g', %1$s))), 0)",
      x
    )
  }
  coordinate <- function(column, pixel_size) {
    if (isTRUE(all.equal(pixel_size, 0.01))) {
      return(column)
    }
    sprintf(
      "ROUND(FLOOR(%1$s / %2$s) * %2$s + %2$s / 2, 6)",
      column, format(pixel_size, scientific = FALSE)
    )
  }

  rows <- lapply(seq_len(nrow(cuts)), function(i) {
    spec <- cuts[i, ]
    time_sql <- switch(
      spec$time,
      month = "CAST(month AS STRING)",
      year = "CAST(EXTRACT(YEAR FROM month) AS STRING)",
      all = NULL
    )
    group_columns <- c(
      if (!is.null(time_sql)) "time",
      "lon", "lat", "vessel_class", "fishing_vessel", "fishing_activity"
    )
    select_columns <- c(
      if (!is.null(time_sql)) paste(time_sql, "AS time"),
      paste(coordinate("lon_center", spec$pixel_size), "AS lon"),
      paste(coordinate("lat_center", spec$pixel_size), "AS lat"),
      "vessel_class", "fishing_vessel", "fishing_activity",
      "SUM(hours) AS hours", "SUM(kw_hours) AS kw_hours"
    )
    field_lengths <- c(
      if (!is.null(time_sql)) "LENGTH(time)",
      "LENGTH(CAST(lon AS STRING))", "LENGTH(CAST(lat AS STRING))",
      "LENGTH(vessel_class)", "IF(fishing_vessel, 4, 5)", "IF(fishing_activity, 4, 5)",
      number_length("hours"), number_length("kw_hours")
    )
    # Commas between fields, plus a newline
    row_length <- paste0(paste(field_lengths, collapse = " + "), " + ", length(field_lengths))
    filters <- c(
      if (!is.na(spec$year)) sprintf("month BETWEEN '%1$s-01-01' AND '%1$s-12-31'", spec$year),
      if (spec$fishing_activity_only) "fishing_activity"
    )
    where_sql <- if (length(filters) > 0) paste("WHERE", paste(filters, collapse = " AND ")) else ""
    sql <- sprintf(
      "WITH cut AS (SELECT %s FROM `%s` %s GROUP BY %s)
       SELECT COUNT(*) AS n_rows, SUM(%s) AS csv_bytes FROM cut",
      paste(select_columns, collapse = ", "), tbl, where_sql,
      paste(group_columns, collapse = ", "), row_length
    )
    job <- bigrquery::bq_project_query(
      billing_project, sql,
      configuration = list(query = list(maximum_bytes_billed = tb_to_bytes_string(max_tb_billed))),
      quiet = TRUE
    )
    # Byte counts pass R's integer limit (~2.1e9), so read them as doubles
    result <- bigrquery::bq_table_download(job, bigint = "numeric", quiet = TRUE)
    dplyr::mutate(
      spec,
      n_rows = as.numeric(result$n_rows),
      csv_mb = as.numeric(result$csv_bytes) / 1e6
    )
  })
  dplyr::bind_rows(rows)
}

# ---- Site data ----------------------------------------------------------------

# The metadata of an existing BigQuery table, in the same form the BigQuery
# targets hold (bigrquery::bq_table_meta()), so downstream targets can use a
# table this pipeline built earlier without rebuilding it.
read_bq_table_meta <- function(bq_project, bq_dataset, bq_table_name) {
  bigrquery::bq_table_meta(bigrquery::bq_table(bq_project, bq_dataset, bq_table_name))
}

# Run a SQL query and write the result as a CSV (gzipped if `path` ends in
# .gz), rounding doubles to 7 significant digits as download_bq_table_to_csv()
# does. Capped at `max_tb_billed`, and fails if the file is too big to commit.
# Returns the path.
download_bq_query_to_csv <- function(sql, path, billing_project, max_tb_billed = 0.1) {
  job <- bigrquery::bq_project_query(
    billing_project, sql,
    configuration = list(query = list(maximum_bytes_billed = tb_to_bytes_string(max_tb_billed))),
    quiet = TRUE
  )
  bigrquery::bq_table_download(job, n_max = Inf, quiet = TRUE) |>
    round_doubles() |>
    write_csv_file(path)
}

# Land polygons for the site's maps: Natural Earth countries at 1:50m
# (rnaturalearthdata::countries50), cut to
# the study area plus `pad_deg` degrees, written as GeoJSON so the site can
# draw coastlines without downloading anything. Returns the path.
write_land_geojson <- function(study_area_bbox, path, pad_deg = 1) {
  crop_box <- sf::st_bbox(
    c(
      xmin = study_area_bbox[["lon_min"]] - pad_deg,
      xmax = study_area_bbox[["lon_max"]] + pad_deg,
      ymin = study_area_bbox[["lat_min"]] - pad_deg,
      ymax = study_area_bbox[["lat_max"]] + pad_deg
    ),
    crs = sf::st_crs(4326)
  )
  # Planar cropping in lon/lat, which is what the maps draw in
  s2_was_on <- sf::sf_use_s2(FALSE)
  on.exit(suppressMessages(sf::sf_use_s2(s2_was_on)), add = TRUE)
  land <- sf::st_as_sf(rnaturalearthdata::countries50) |>
    sf::st_geometry() |>
    sf::st_make_valid() |>
    sf::st_crop(crop_box) |>
    sf::st_union() |>
    sf::st_sf(geometry = _)
  dir.create(dirname(path), showWarnings = FALSE, recursive = TRUE)
  sf::st_write(land, path, delete_dsn = TRUE, quiet = TRUE)
  assert_under_github_size_limit(path)
  path
}

# Render the Quarto project in `qmd_dir` into `output_dir` (its output-dir in
# _quarto.yml), which GitHub Pages serves. Returns the source files plus the
# rendered HTML, so a format = "file" target re-renders when either the source
# or (via `deps`, the data files passed in only to create the dependency) the
# data change. Falls back to the Quarto CLI bundled with Positron or RStudio
# when none is on the PATH.
render_quarto_site <- function(qmd_dir, output_dir, deps = NULL) {
  if (is.null(quarto::quarto_path())) {
    bundled <- c(
      "/Applications/Positron.app/Contents/Resources/app/quarto/bin/quarto",
      "/Applications/RStudio.app/Contents/Resources/app/quarto/bin/quarto"
    )
    bundled <- bundled[file.exists(bundled)]
    if (length(bundled) == 0) {
      stop("No Quarto CLI found. Install Quarto or set QUARTO_PATH.", call. = FALSE)
    }
    Sys.setenv(QUARTO_PATH = bundled[1])
  }
  # quiet = FALSE so a failing chunk is named in the pipeline log
  quarto::quarto_render(qmd_dir, as_job = FALSE, quiet = FALSE)
  # GitHub Pages serves the folder as-is; .nojekyll stops it running Jekyll
  file.create(file.path(output_dir, ".nojekyll"))
  output <- file.path(output_dir, "index.html")
  stopifnot(file.exists(output))
  for (path in list.files(output_dir, recursive = TRUE, full.names = TRUE)) {
    assert_under_github_size_limit(path)
  }
  c(list.files(qmd_dir, recursive = TRUE, full.names = TRUE), output)
}

# The fields of a BigQuery table's metadata that change only when the table is
# rewritten: its name, size and last modification. A target holding this
# instead of the full metadata is not invalidated by fields that drift on
# their own (such as long-term storage bytes after 90 days).
stable_bq_table_meta <- function(meta) {
  meta[c("tableReference", "numRows", "numBytes", "lastModifiedTime")]
}

# Every combination of `pixel_sizes` and `times`, for all activity and for
# fishing activity only, plus every pixel size by month for `one_year` alone:
# the cuts estimate_csv_sizes() sizes. `files` maps
# "<activity>, <pixel size>, <time>" to the file under data/ holding that cut.
download_cut_grid <- function(pixel_sizes, times, one_year, files = character()) {
  grid <- expand.grid(
    pixel_size = pixel_sizes,
    time = times,
    fishing_activity_only = c(FALSE, TRUE),
    stringsAsFactors = FALSE
  )
  # Integer, so round_doubles() leaves it alone
  grid$year <- NA_integer_
  single_year <- expand.grid(
    pixel_size = pixel_sizes,
    time = "month",
    fishing_activity_only = FALSE,
    stringsAsFactors = FALSE
  )
  single_year$year <- as.integer(one_year)
  cuts <- tibble::as_tibble(rbind(grid, single_year))
  activity <- ifelse(cuts$fishing_activity_only, "fishing activity", "all activity")
  time_label <- c(month = "monthly", year = "yearly", all = "all years summed")[cuts$time]
  cuts$cut <- paste0(
    ifelse(is.na(cuts$year), "", paste0(cuts$year, " only, ")),
    ifelse(cuts$fishing_activity_only, "fishing activity only, ", ""),
    format(cuts$pixel_size, nsmall = 2), " deg, ", time_label
  )
  key <- paste0(activity, ", ", cuts$pixel_size, ", ", cuts$time)
  cuts$file <- ifelse(is.na(cuts$year) & key %in% names(files), unname(files[key]), NA_character_)
  cuts[c("cut", "pixel_size", "time", "year", "fishing_activity_only", "file")]
}
