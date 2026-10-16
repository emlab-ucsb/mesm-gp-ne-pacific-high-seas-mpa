-- Summary of an ais_effort_by_pixel table: one row per month, vessel class,
-- fishing vessel or not and fishing activity or not, with the number of pixels
-- that have any hours and the total hours and kW-hours. Reads the pixel table
-- only (a few GB at most).
SELECT
  month,
  vessel_class,
  fishing_vessel,
  fishing_activity,
  -- One row per pixel at this grain, so the row count is the pixel count
  COUNT(*) AS n_pixels,
  SUM(hours) AS hours,
  SUM(kw_hours) AS kw_hours
FROM
  `{ais_effort_by_pixel_table}`
GROUP BY
  month,
  vessel_class,
  fishing_vessel,
  fishing_activity
