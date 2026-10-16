# The Quarto site (qmd/): its map layer and the render. The site's data are
# built in targets/ais.R and committed under data/, so GitHub Actions can
# render the site on every push without BigQuery. List each data file the
# site reads in `deps` below, so the site re-renders when it changes.

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
  # Renders qmd/ to qmd/_site/. Edits to any source file under qmd/ are
  # tracked because they are part of the returned file set.
  targets::tar_target(
    site,
    render_quarto_site(
      qmd_dir = "qmd",
      deps = c(
        study_area_shapefile,
        land_geojson,
        ais_effort_by_pixel_summary_csv,
        ais_download_sizes_csv,
        ais_effort_by_pixel_0p05deg_all_years_csv,
        ais_fishing_activity_by_pixel_0p05deg_yearly_csv
      )
    ),
    format = "file"
  )
)
