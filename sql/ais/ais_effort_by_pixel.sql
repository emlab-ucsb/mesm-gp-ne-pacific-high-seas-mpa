-- AIS hours and kW-hours per pixel, month, vessel class, fishing vessel or
-- not, and fishing activity or not, for every vessel in ais_vessels, in the
-- study area bounding box.
--
-- Positions come from GFW's AIS messages (pipeline v5), {start_date} to
-- {end_date}, on good segments only (clean_segs), with
-- {lon_min} <= lon < {lon_max} and {lat_min} <= lat < {lat_max}. The messages
-- table is not clustered on position, so the lat/lon filter does not cut the
-- bytes scanned; the date filter is what sets the cost (~0.3 TB for a recent
-- month, ~19.0 TB for 2015-01 to 2026-08).
--
-- A position is fishing activity when the vessel is a fishing vessel
-- (fishing_vessel in ais_vessels: the pipeline 5 random forest's fishing call,
-- with a fishing class) and its fishing score is above 0.5. The score is the
-- pipeline 5 general fishing model's (nnet_score), which is 0, 1 or NULL (NULL
-- where thinned positions are over 12 hours apart; not fishing here), for
-- every class except squid jiggers, which fish at night under lights and use
-- night_loitering (0 or 1) instead. Every position of a vessel that is not a
-- fishing vessel is not fishing activity, whatever its score.
--
-- Pixels are {pixel_size} degrees on a side, binned on FLOOR(coordinate /
-- {pixel_size}) in NUMERIC (exact decimal) arithmetic: in FLOAT64, 0.01 is
-- not exact and a position on a cell edge can land in the neighbouring cell
-- (-79.29 / 0.01 floors to -7930), the problem pipeline 5 fixed in its own
-- spatial grid. Pixels are labelled by their centre (pipeline 5's own grid
-- labels the lower-left corner), so a pixel can be coarsened with
-- FLOOR(centre / new size) for any new size that is a multiple of
-- {pixel_size} without the centre ever sitting on an edge.
WITH
  -- Class, fishing-vessel call and engine power for every vessel (ssvid)
  vessels AS (
    SELECT
      ssvid,
      vessel_class,
      fishing_vessel,
      engine_power_kw
    FROM
      `{ais_vessels_table}`
  ),

  -- Individual positions in the window and the box
  positions AS (
    SELECT
      ssvid,
      DATE_TRUNC(DATE(timestamp), MONTH) AS month,
      lon,
      lat,
      hours,
      nnet_score,
      night_loitering
    FROM
      `{ais_messages_table}`
    WHERE
      DATE(timestamp) BETWEEN "{start_date}" AND "{end_date}"
      -- Only include positions from good segments
      AND clean_segs
      -- In the study area bounding box
      AND lon >= {lon_min}
      AND lon < {lon_max}
      AND lat >= {lat_min}
      AND lat < {lat_max}
  ),

  -- Keep only the vessels in the analysis, and call each position fishing
  -- activity or not. Squid jiggers are scored on night loitering rather than
  -- nnet_score. A missing score is not fishing activity.
  scored_positions AS (
    SELECT
      positions.*,
      vessel_class,
      fishing_vessel,
      engine_power_kw,
      IFNULL(
        fishing_vessel
        AND IF(vessel_class = 'squid_jigger', night_loitering, nnet_score) > 0.5,
        FALSE
      ) AS fishing_activity
    FROM
      positions
      JOIN vessels USING (ssvid)
  )

-- Hours and kW-hours per pixel, month, vessel class, fishing vessel or not and
-- fishing activity or not. Every vessel in ais_vessels has an engine power, so
-- kw_hours covers the same positions as hours
SELECT
  month,
  CAST(
    (FLOOR(CAST(lon AS NUMERIC) / NUMERIC '{pixel_size}') + NUMERIC '0.5') * NUMERIC '{pixel_size}'
    AS FLOAT64
  ) AS lon_center,
  CAST(
    (FLOOR(CAST(lat AS NUMERIC) / NUMERIC '{pixel_size}') + NUMERIC '0.5') * NUMERIC '{pixel_size}'
    AS FLOAT64
  ) AS lat_center,
  vessel_class,
  fishing_vessel,
  fishing_activity,
  SUM(hours) AS hours,
  SUM(hours * engine_power_kw) AS kw_hours
FROM
  scored_positions
GROUP BY
  month,
  lon_center,
  lat_center,
  vessel_class,
  fishing_vessel,
  fishing_activity
-- `hours` here is the SELECT alias, already SUM(hours)
HAVING
  hours > 0
