# mesm-gp-ne-pacific-high-seas-mpa targets pipeline
#
# One store, split by topic. Each file under targets/ defines a list of targets:
#
#   targets/parameters.R  run version, time window, study area bounding box,
#                         pixel size
#   targets/ais.R         AIS vessel list, vessel class summary, AIS hours and
#                         kW-hours per pixel, month, vessel class and fishing
#                         activity, download sizes, and the site's data
#   targets/report.R      the site's map layer and the Quarto render
#
# Moving a target between these files does not invalidate it: targets hashes
# the command, not where it is written. To build one part only, e.g.
#   targets::tar_make(names = tidyselect::starts_with("ais_vessel"))
#
# Style: explicit pkg::fun() calls throughout; BigQuery via bigrquery.

targets::tar_source(c("r/functions.R", "r/bq_table_docs.R"))

# Run version, BigQuery settings, cost guards, and upstream GFW table names.
source("config.R")

targets::tar_option_set(
  memory = "transient",     # clear targets from memory after use
  garbage_collection = TRUE # force garbage collection between targets
)

targets::tar_source(c(
  "targets/parameters.R",
  "targets/ais.R",
  "targets/report.R"
))

list(
  parameter_targets,
  ais_targets,
  report_targets
)
