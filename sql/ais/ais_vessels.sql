-- AIS vessels in the analysis, fishing and non-fishing: one row per vessel
-- (ssvid).
--
-- Source: GFW's vessel identity table (vi_ssvid, pipeline v5), which
-- summarises each vessel's whole AIS record (2012 to present) in one row.
-- Vessel class, the fishing-vessel call and engine power come from the
-- pipeline 5 random forest (random_forest_info), which replaces the
-- deprecated best.best_vessel_class and on_fishing_list_best (Pipe5 Release
-- Notes for Research Partners, Sept 2026). The random forest predicts at the
-- ssvid level across all time.
--
-- Vessel class: the random forest's class (random_forest_info.best_vessel_class,
-- rf_vessel_class here), which names a specific gear only when the model's
-- score for it is at least 0.35 and otherwise rolls up to a broader parent.
-- Where it rolls all the way up to the generic 'fishing', the vessel takes the
-- model's finest-level prediction (random_forest_info.atomic_class) instead,
-- but only when that is one of the gears GFW says the atomic class predicts
-- well ({trusted_atomic_classes}; Pipe5 Release Notes, Appendix E). Every
-- other vessel, including the intermediate parents such as 'fixed_gear',
-- keeps the random forest class.
--
-- A vessel is kept when
--   * the random forest gives it a vessel class, and that class is not 'gear'
--     (random_forest_info.best_vessel_class is already 'gear' wherever the
--     ship name looks like fishing gear). The class is NULL for vessels with
--     too little activity for the model, ~0.2% of hours in the study area,
--   * it was never noisy, by GFW's noisy_vessel rule applied to its whole
--     record: never seen offsetting its position, and under 24 hours
--     broadcasting its MMSI under more than one name at once. A vessel that
--     was noisy at any point is dropped in every year, so each vessel is in
--     the time series for all of its years or none, and its whole-record class
--     never rests on another vessel's track. GFW's own noisy_vessel column
--     (product_vessel_info_summary) applies the same formula year by year; on
--     2026-10-16 every vessel it ever flagged also failed this test, this test
--     caught ~200 more in the study area whose overlap passes 24 hours only
--     summed across years, and it covers vessels missing from that table,
--   * it has an engine power, so its hours and kW-hours cover the same
--     vessels (every vessel with a random forest class has one; kept as a
--     check), and
--   * it broadcast AIS at some point from {window_start_date} to
--     {window_end_date} (the data window in targets/parameters.R).
-- NULL flags fail the tests, so a vessel with no activity summary is dropped.
--
-- fishing_vessel is the random forest's fishing-vessel call
-- (random_forest_info.on_fishing_list_best: the random forest call,
-- overridden by registry where available). In pipeline 5 it always agrees
-- with the class (TRUE exactly for the fishing classes), and the build fails
-- if it ever does not. Only these vessels can have fishing activity in
-- ais_effort_by_pixel.
--
-- Class, flag and engine power are whole-record values, so a vessel keeps the
-- same values in every month.
SELECT
  ssvid,
  CASE
    WHEN random_forest_info.best_vessel_class = 'fishing'
      AND random_forest_info.atomic_class IN ({trusted_atomic_classes})
      THEN random_forest_info.atomic_class
    ELSE random_forest_info.best_vessel_class
  END AS vessel_class,
  IFNULL(random_forest_info.on_fishing_list_best, FALSE) AS fishing_vessel,
  best.best_flag AS flag,
  random_forest_info.best_engine_power_kw AS engine_power_kw,
  -- Where vessel_class came from
  random_forest_info.best_vessel_class AS rf_vessel_class,
  random_forest_info.atomic_class AS rf_atomic_class,
  random_forest_info.atomic_class_score AS rf_atomic_class_score
FROM
  `{ais_vessel_info_table}`
WHERE
  -- Only vessels with a known class, and not fishing gear
  random_forest_info.best_vessel_class IS NOT NULL
  AND random_forest_info.best_vessel_class != 'gear'
  -- Not noisy (GFW's noisy_vessel rule, over the whole record)
  AND NOT activity.offsetting
  AND activity.overlap_hours_multinames < 24
  -- Only vessels with an engine power, for kW-hours
  AND random_forest_info.best_engine_power_kw IS NOT NULL
  -- Broadcast AIS at some point in the window
  AND DATE(activity.first_timestamp) <= "{window_end_date}"
  AND DATE(activity.last_timestamp) >= "{window_start_date}"
