-- The pixel table coarsened to {pixel_size}-degree pixels and summed over
-- {year}: one row per pixel, vessel class, fishing vessel or not and fishing
-- activity or not. The students' main cost layer, small enough to commit.
--
-- Reads only {year}'s monthly partitions. Pixels are regridded from the
-- table's pixel centres, which never sit on a cell edge, so
-- FLOOR(centre / {pixel_size}) is exact. Each new pixel is again labelled by
-- its centre.
SELECT
  {year} AS year,
  ROUND(FLOOR(lon_center / {pixel_size}) * {pixel_size} + {pixel_size} / 2, 6) AS lon_center,
  ROUND(FLOOR(lat_center / {pixel_size}) * {pixel_size} + {pixel_size} / 2, 6) AS lat_center,
  vessel_class,
  fishing_vessel,
  fishing_activity,
  SUM(hours) AS hours,
  SUM(kw_hours) AS kw_hours
FROM
  `{ais_effort_by_pixel_table}`
WHERE
  month BETWEEN "{year}-01-01" AND "{year}-12-01"
GROUP BY
  1, 2, 3, 4, 5, 6
ORDER BY
  1, 2, 3, 4, 5, 6
