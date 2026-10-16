# Documentation for every BigQuery table this pipeline creates.
#
# Each table has its own `docs_<base table name>` object. One object per table
# on purpose: targets tracks the objects a command references, so a wording
# change in one table's docs rebuilds only that table, not the whole pipeline.
# Each holds the table `description` plus `fields`, a named character vector
# of column -> description. run_bq_query_and_save_table() writes both into the
# table's metadata, and set_bq_table_documentation() fails the build if the
# columns here and the columns in the table ever disagree, so when the SQL
# changes, this file has to change with it.
#
# Descriptions with "{...}" are glued with pipeline parameters in
# targets/ais.R.

docs_bq_dataset <- paste(
  "AIS data for the Bren School MESM group project on high seas conservation",
  "prioritisation along the Cobb-Eickelberg seamount chain, Northeast Pacific.",
  "Built by emlab-ucsb/mesm-gp-ne-pacific-high-seas-mpa."
)

# ---- AIS tables ----------------------------------------------------------------

docs_ais_vessels <- list(
  description = paste(
    "AIS vessels in the analysis, fishing and non-fishing, one row per vessel (ssvid): every vessel in GFW's vessel identity table",
    "(global-fishing-watch.pipe_ais_identity_v5_partners_published.vi_ssvid, pipeline v5, one row per vessel over its whole AIS record)",
    "with a pipeline 5 random forest vessel class (random_forest_info.best_vessel_class) other than NULL or 'gear', that was never noisy",
    "by GFW's noisy_vessel rule applied to its whole record (never offsetting, under 24 hours of overlap_hours_multinames), so a vessel",
    "noisy at any point is dropped in every year, that has an engine power (random_forest_info.best_engine_power_kw), and that broadcast",
    "AIS at some point from {window_start_date} to {window_end_date}. vessel_class is the random forest class, except that a vessel the",
    "model calls only generic 'fishing' takes its atomic class (random_forest_info.atomic_class) when that is one of the gears GFW says",
    "the atomic class predicts well ({trusted_atomic_classes}).",
    "The random forest fields replace the deprecated best.best_vessel_class and on_fishing_list_best (Pipe5 Release Notes, Sept 2026).",
    "Built by emlab-ucsb/mesm-gp-ne-pacific-high-seas-mpa: sql/ais/ais_vessels.sql."
  ),
  fields = c(
    ssvid = "AIS vessel identifier (MMSI) as GFW's ssvid; unique key.",
    vessel_class = "Vessel class over the whole record, e.g. 'trawlers', 'cargo', 'passenger': rf_vessel_class, except that where rf_vessel_class is the generic 'fishing' and rf_atomic_class is a gear the atomic class predicts well (trawlers, drifting_longlines, set_gillnets, tuna_purse_seines, squid_jigger), it is rf_atomic_class.",
    fishing_vessel = "TRUE if the pipeline 5 random forest calls the vessel a fishing vessel (random_forest_info.on_fishing_list_best, overridden by registry where available). Always TRUE exactly for the fishing classes (global-fishing-watch.udfs.is_fishing); the build fails if not. Only these vessels can have fishing activity.",
    flag = "GFW best flag state over the whole record (best.best_flag, ISO3). NULL if unknown.",
    engine_power_kw = "Pipeline 5 random forest engine power in kW over the whole record (random_forest_info.best_engine_power_kw), overwritten by the registry value where known. Never NULL: vessels without one are dropped.",
    rf_vessel_class = "Pipeline 5 random forest vessel class (random_forest_info.best_vessel_class): the finest class scoring at least 0.35, else its broader parent, and 'gear' wherever the ship name looks like gear.",
    rf_atomic_class = "Pipeline 5 random forest finest-level class prediction (random_forest_info.atomic_class), regardless of its score.",
    rf_atomic_class_score = "Random forest score for rf_atomic_class (random_forest_info.atomic_class_score)."
  )
)

docs_ais_vessel_class_summary <- list(
  description = paste(
    "Number of AIS vessels per vessel class (pipeline 5 random forest, random_forest_info.best_vessel_class), from the vessel identity",
    "tables alone (no positions read):",
    "every vessel in vi_ssvid that broadcast AIS at some point from {window_start_date} to {window_end_date}, how many have no engine",
    "power or are noisy, how many are kept in ais_vessels, and how many of those could have positions in the study area",
    "(lon {lon_min} to {lon_max}, lat {lat_min} to {lat_max}): their lat/lon extent in at least one year from {first_year} to {last_year} (vi_ssvid_byyear)",
    "overlaps the box. The study-area counts are upper bounds, since an extent can overlap the box with no position inside it.",
    "Built by emlab-ucsb/mesm-gp-ne-pacific-high-seas-mpa: sql/ais/ais_vessel_class_summary.sql."
  ),
  fields = c(
    vessel_class = "Vessel class: ais_vessels.vessel_class for kept vessels, the random forest class (random_forest_info.best_vessel_class) for dropped ones; unique key. NULL for vessels with too little activity for the model.",
    fishing_class = "TRUE if GFW counts the class as a fishing class (global-fishing-watch.udfs.is_fishing).",
    n_vessels = "Vessels of this class in vi_ssvid that broadcast AIS at some point in the window, before any filter.",
    n_vessels_noisy = "Of n_vessels, those that were ever noisy by GFW's noisy_vessel rule over the whole record: seen offsetting their position, or 24 hours or more sharing their MMSI with another name at the same time (or with no activity flags). Dropped from the analysis in every year.",
    n_vessels_no_engine_power = "Of n_vessels, those with no engine power (random_forest_info.best_engine_power_kw), which kW-hours need. Dropped from the analysis. Can overlap n_vessels_noisy.",
    n_vessels_kept = "Of n_vessels, those kept in ais_vessels: a class other than NULL or 'gear', never noisy, and with an engine power.",
    n_vessels_kept_fishing_vessel = "Of n_vessels_kept, those that are fishing vessels (the random forest's fishing call), whose positions can be fishing activity.",
    n_vessels_kept_study_area = "Of n_vessels_kept, those whose lat/lon extent in at least one year of the window overlaps the study area. Upper bound on the vessels with positions there.",
    n_vessels_kept_study_area_fishing_vessel = "Of n_vessels_kept_study_area, those that are fishing vessels."
  )
)

docs_ais_effort_by_pixel <- list(
  description = paste(
    "AIS hours and kW-hours per {pixel_size}-degree pixel, month, vessel class, fishing vessel or not, and fishing activity or not,",
    "{start_date} to {end_date}, in the study area bounding box (lon {lon_min} to {lon_max}, lat {lat_min} to {lat_max}; data/small_gfw_bbox_mesm snapped outward to",
    "{snap_deg} degrees). Every vessel in ais_vessels, fishing and non-fishing.",
    "Positions are GFW AIS messages on good segments (global-fishing-watch.pipe_ais_v5_published.messages, pipeline v5, clean_segs).",
    "A position is fishing activity when the vessel",
    "is a fishing vessel (ais_vessels.fishing_vessel) and its score is 1 (above 0.5): the pipeline 5 general fishing model's nnet_score",
    "(0, 1 or NULL; NULL is not fishing) for every class except squid jiggers, which use night_loitering. Positions of vessels that",
    "are not fishing vessels are never fishing activity (checked on every build). Positions are binned to pixels in exact decimal",
    "(NUMERIC) arithmetic.",
    "Only rows with hours are kept. Partitioned by month and clustered by fishing_activity, fishing_vessel and vessel_class.",
    "Built by emlab-ucsb/mesm-gp-ne-pacific-high-seas-mpa: sql/ais/ais_effort_by_pixel.sql."
  ),
  fields = c(
    month = "First day of the calendar month (DATE).",
    lon_center = "Longitude of the pixel centre (degrees). The pixel spans lon_center +/- half the pixel size.",
    lat_center = "Latitude of the pixel centre (degrees). The pixel spans lat_center +/- half the pixel size.",
    vessel_class = "Vessel class (pipeline 5 random forest) from ais_vessels.",
    fishing_vessel = "TRUE if the vessel is a fishing vessel (ais_vessels.fishing_vessel: the pipeline 5 random forest's fishing call, with a fishing class). A vessel's type, not what it was doing; see fishing_activity.",
    fishing_activity = "TRUE for hours of fishing activity (GFW's apparent fishing): a fishing vessel at a position with fishing score > 0.5. Always FALSE when fishing_vessel is FALSE, so never TRUE for a non-fishing vessel class. (month, lon_center, lat_center, vessel_class, fishing_vessel, fishing_activity) is the unique key.",
    hours = "Sum of AIS hours over the positions in the row.",
    kw_hours = "Sum of hours x engine power (kW) over the positions in the row. Every vessel in ais_vessels has an engine power, so this covers the same positions as hours."
  )
)
