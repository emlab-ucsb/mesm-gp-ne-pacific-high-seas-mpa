# Pipeline parameters shared by every analysis: the run version, the time
# window, the study area bounding box and the pixel grid.

parameter_targets <- list(
  ## Config ----
  targets::tar_target(run_version, run_version_value),
  # Data window: every AIS position from the first day of January 2015 to the
  # last day of August 2026. Ends with the vessel identity table: vi_ssvid's
  # activity ran to 2026-08-31 when the pipeline was built, so a later month
  # would miss vessels first seen in it.
  targets::tar_target(window_start_date, "2015-01-01"),
  targets::tar_target(window_end_date, "2026-08-31"),
  # One month of the window, run on its own before the full scan to check the
  # output and size the full table (~0.3 TB scanned). The most recent July:
  # AIS reception grows over the window and summer is the busiest season in
  # the North Pacific, so this month is near the largest.
  targets::tar_target(ais_test_month, "2025-07-01"),

  ## Pixel grid ----
  # Pixel width and height in degrees. Every pixel query bins on
  # FLOOR(coordinate / pixel_size), so this one number defines the grid. 0.01
  # degrees is ~1.1 km north-south and ~0.5-0.85 km east-west over the box.
  targets::tar_target(pixel_size, 0.01),

  ## Study area ----
  # The study area bounding box, drawn as a lon/lat rectangle in WGS84 (all
  # four sidecar files, so a change to any of them is picked up): lon -160 to
  # -120, lat 39.89 to 61.55. It replaced the first, larger box
  # (data/gfw_bbox_mesm, west edge at -166.79) on 2026-10-16.
  targets::tar_target(
    study_area_shapefile,
    list.files("data/small_gfw_bbox_mesm", pattern = "^gfwbbox_sm\\.", full.names = TRUE),
    format = "file"
  ),
  # The box edges are snapped outward to this grid (degrees), so every pixel at
  # any resolution that divides it (0.01, 0.05, 0.1, 0.25, 0.5, 1) is either
  # wholly in or wholly out of the box: no partial pixels along the edges when
  # the output is coarsened. Each edge moves out by less than this. Widening
  # the box does not change the bytes scanned (the AIS table is not clustered
  # on position), and the output can always be trimmed back to the drawn box.
  targets::tar_target(study_area_snap_deg, 1),
  # lon_min, lon_max, lat_min, lat_max of the snapped box. Fails if the
  # shapefile is not a single axis-aligned lon/lat rectangle, because the AIS
  # query filters positions on these four numbers alone.
  targets::tar_target(
    study_area_bbox,
    read_study_area_bbox(
      study_area_shapefile[grepl("\\.shp$", study_area_shapefile)],
      snap_deg = study_area_snap_deg
    )
  )
)
