# The Quarto site (qmd/): its map layer and the render. The site's data are
# built in targets/ais.R and committed under data/, and the rendered site is
# written to docs/ and committed too: GitHub Pages serves main/docs. List each
# data file the site reads in `deps` below, so the site re-renders when it
# changes.

report_targets <- list(
  ## Map layer ----
  # Coastlines for the maps: Natural Earth land, cut to the study area plus a
  # degree (well under 1 MB).
  targets::tar_target(
    land_geojson,
    write_land_geojson(study_area_bbox, path = "data/land_ne_50m.geojson"),
    format = "file"
  ),

  ## Quarto site ----
  # Renders qmd/ into docs/. Edits to any source file under qmd/ are tracked
  # because they are part of the returned file set. Commit docs/ afterwards to
  # publish.
  targets::tar_target(
    site,
    render_quarto_site(
      qmd_dir = "qmd",
      output_dir = "docs",
      deps = c(
        study_area_shapefile,
        land_geojson,
        ais_vessel_class_summary_csv,
        ais_effort_by_pixel_summary_csv,
        ais_download_sizes_csv,
        ais_effort_by_pixel_0p05deg_all_years_csv,
        ais_fishing_activity_by_pixel_0p05deg_yearly_csv
      )
    ),
    format = "file"
  )
)
