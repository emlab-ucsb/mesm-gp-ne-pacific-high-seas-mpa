-- Fishing activity from the pixel table, coarsened to {pixel_size}-degree
-- pixels and summed by year: one row per year, pixel and vessel class (every
-- row is a fishing vessel's fishing activity). Small enough to commit, so the
-- site can map fishing activity year by year without BigQuery. The last year
-- is partial (the window ends {window_end_date}).
--
-- Pixels are regridded from the table's pixel centres, which never sit on a
-- cell edge, so FLOOR(centre / {pixel_size}) is exact. Each new pixel is again
-- labelled by its centre.
SELECT
  EXTRACT(YEAR FROM month) AS year,
  ROUND(FLOOR(lon_center / {pixel_size}) * {pixel_size} + {pixel_size} / 2, 6) AS lon_center,
  ROUND(FLOOR(lat_center / {pixel_size}) * {pixel_size} + {pixel_size} / 2, 6) AS lat_center,
  vessel_class,
  SUM(hours) AS hours,
  SUM(kw_hours) AS kw_hours
FROM
  `{ais_effort_by_pixel_table}`
WHERE
  fishing_activity
GROUP BY
  1, 2, 3, 4
ORDER BY
  1, 2, 3, 4
