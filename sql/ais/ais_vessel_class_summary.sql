-- How many vessels there are of each vessel class, before running the AIS
-- position scan: one row per vessel class (NULL included). Vessels kept in
-- ais_vessels are counted under their class there; vessels it drops are
-- counted under the random forest's class (random_forest_info.best_vessel_class),
-- as the switch from generic 'fishing' to a trusted atomic class is made only
-- for kept vessels.
--
-- Reads only the vessel identity tables (under 10 GB), never the positions.
-- Starts from every vessel in vi_ssvid that broadcast AIS at some point from
-- {window_start_date} to {window_end_date}, then counts how many
--   * are noisy (GFW's noisy_vessel rule over the whole record: offsetting, or
--     24 hours or more broadcasting their MMSI under more than one name at
--     once),
--   * have no engine power,
--   * are kept in ais_vessels (known class other than 'gear', not noisy, with
--     an engine power), and of those, are fishing vessels, and
--   * of those, could have positions in the study area: their lat/lon extent
--     in at least one year from {first_year} to {last_year} (vi_ssvid_byyear)
--     overlaps the box. This is
--     an upper bound on the vessels that will appear in ais_effort_by_pixel,
--     since an extent can overlap the box without a single position falling
--     inside it (a vessel crossing the Pacific south of the box, say).
WITH
  -- Every vessel that broadcast AIS in the window, before any filter
  window_vessels AS (
    SELECT
      ssvid,
      random_forest_info.best_vessel_class AS vessel_class,
      -- NULL flags count as noisy, as they fail the tests in ais_vessels
      IFNULL(
        activity.offsetting OR activity.overlap_hours_multinames >= 24,
        TRUE
      ) AS noisy,
      random_forest_info.best_engine_power_kw IS NOT NULL AS has_engine_power
    FROM
      `{ais_vessel_info_table}`
    WHERE
      DATE(activity.first_timestamp) <= "{window_end_date}"
      AND DATE(activity.last_timestamp) >= "{window_start_date}"
  ),

  -- The vessels kept in the analysis
  kept_vessels AS (
    SELECT
      ssvid,
      TRUE AS kept,
      vessel_class AS kept_vessel_class,
      fishing_vessel
    FROM
      `{ais_vessels_table}`
  ),

  -- Vessels whose extent in some year of the window overlaps the study area
  study_area_vessels AS (
    SELECT DISTINCT
      ssvid,
      TRUE AS in_study_area
    FROM
      `{ais_vessel_info_by_year_table}`
    WHERE
      year BETWEEN {first_year} AND {last_year}
      AND activity.min_lon < {lon_max}
      AND activity.max_lon >= {lon_min}
      AND activity.min_lat < {lat_max}
      AND activity.max_lat >= {lat_min}
  ),

  vessels AS (
    SELECT
      window_vessels.* EXCEPT (vessel_class),
      IFNULL(kept_vessel_class, window_vessels.vessel_class) AS vessel_class,
      IFNULL(kept, FALSE) AS kept,
      IFNULL(fishing_vessel, FALSE) AS fishing_vessel,
      IFNULL(in_study_area, FALSE) AS in_study_area
    FROM
      window_vessels
      LEFT JOIN kept_vessels USING (ssvid)
      LEFT JOIN study_area_vessels USING (ssvid)
  )

SELECT
  vessel_class,
  `{is_fishing_udf}`(vessel_class) AS fishing_class,
  COUNT(*) AS n_vessels,
  COUNTIF(noisy) AS n_vessels_noisy,
  COUNTIF(NOT has_engine_power) AS n_vessels_no_engine_power,
  COUNTIF(kept) AS n_vessels_kept,
  COUNTIF(kept AND fishing_vessel) AS n_vessels_kept_fishing_vessel,
  COUNTIF(kept AND in_study_area) AS n_vessels_kept_study_area,
  COUNTIF(kept AND in_study_area AND fishing_vessel) AS n_vessels_kept_study_area_fishing_vessel
FROM
  vessels
GROUP BY
  vessel_class,
  fishing_class
