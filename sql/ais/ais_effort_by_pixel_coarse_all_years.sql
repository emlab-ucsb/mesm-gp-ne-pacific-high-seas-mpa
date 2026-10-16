-- The pixel table coarsened to {pixel_size}-degree pixels and summed over the
-- whole window: one row per pixel, vessel class, fishing vessel or not and
-- fishing activity or not. Small enough to commit, so the site's maps can be
-- drawn without BigQuery.
--
-- Pixels are regridded from the table's pixel centres, which never sit on a
-- cell edge, so FLOOR(centre / {pixel_size}) is exact. Each new pixel is again
-- labelled by its centre.
SELECT
  ROUND(FLOOR(lon_center / {pixel_size}) * {pixel_size} + {pixel_size} / 2, 6) AS lon_center,
  ROUND(FLOOR(lat_center / {pixel_size}) * {pixel_size} + {pixel_size} / 2, 6) AS lat_center,
  vessel_class,
  fishing_vessel,
  fishing_activity,
  SUM(hours) AS hours,
  SUM(kw_hours) AS kw_hours
FROM
  `{ais_effort_by_pixel_table}`
GROUP BY
  1, 2, 3, 4, 5
ORDER BY
  1, 2, 3, 4, 5
