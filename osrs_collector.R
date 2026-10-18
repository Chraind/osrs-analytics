# =====================================================================
#  OSRS COLLECTOR  --  one run per day, builds history for analysis
#  Data: OSRS Wiki real-time prices API (RuneLite partnership)
#        + official OSRS hiscores
#
#  What one run does (safe to run twice - it skips what it already has):
#    1. items.csv           item dimension table (id, name, alch, limit)
#                           refreshed weekly so new items appear
#    2. prices_daily.csv    EVERY tradeable item: 24h average high/low
#                           price and volume. One row per item per day.
#    3. backfill            FIRST RUN ONLY: up to 365 days of daily
#                           history for the WATCHLIST, so forecasting
#                           does not have to wait a year for data
#    4. hiscores_daily.csv  level + xp per skill for each name in
#                           PLAYERS. This is the "new account" diary.
#
#  Column 'date' = the day the 24h window ENDS (UTC). Both the daily
#  snapshot and the backfill use that convention, so they line up.
#
#  All files are plain CSV in ./data next to this script, which is
#  what Power BI reads most easily (Get Data -> Folder or Text/CSV).
#
#  Requires: install.packages(c("httr","jsonlite"))
# =====================================================================

# ---------------------------- CONFIG ---------------------------------

USER_AGENT <- "osrs-collector - discord: Chriand"

# Accounts to log every day. Add the new account's name when it exists.
PLAYERS <- c("Cyrotion")

# Items that get a full-year backfill on the first run. Everything else
# only starts its history from the first day the collector runs.
# Add freely - names must match the wiki exactly (case does not matter).
WATCHLIST <- c(
  # herblore chains
  "Vial of blood", "Grimy cadantine", "Cadantine", "Wine of zamorak",
  "Bastion potion(4)", "Ranarr potion (unf)", "Grimy ranarr weed",
  "Ranarr weed", "Snape grass", "Prayer potion(4)", "Amulet of chemistry",
  # alch chains
  "Adamantite bar", "Adamant platebody", "Battlestaff", "Air orb",
  "Air battlestaff", "Nature rune",
  # gathering staples for the new-account series
  "Raw shark", "Raw monkfish", "Raw karambwan", "Raw anglerfish",
  "Yew logs", "Magic logs", "Iron ore", "Coal", "Runite ore"
)

API <- "https://prices.runescape.wiki/api/v1/osrs"
HS  <- "https://secure.runescape.com/m=hiscore_oldschool/index_lite.ws?player="

# ------------------------- WHERE AM I --------------------------------
# Task Scheduler starts R in C:\Windows\System32, so work out the
# script's own folder and put everything there.

script_dir <- local({
  a <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(sub("^--file=", "", a[1])))
  else getwd()   # running interactively in RStudio
})
DATA <- file.path(script_dir, "data")
dir.create(DATA, showWarnings = FALSE)

LOG <- file.path(DATA, "collector.log")
log_msg <- function(...) {
  line <- sprintf("%s  %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
                  paste0(...))
  cat(line, "\n")
  cat(line, "\n", file = LOG, append = TRUE)
}

# --------------------------- PLUMBING --------------------------------

for (p in c("httr", "jsonlite")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    log_msg(sprintf('FATAL: missing package "%s". Run install.packages("%s")', p, p))
    quit(status = 1)
  }
}

fetch <- function(path, simplify = FALSE) {
  resp <- httr::GET(paste0(API, path), httr::user_agent(USER_AGENT),
                    httr::timeout(60))
  httr::stop_for_status(resp)
  jsonlite::fromJSON(httr::content(resp, as = "text", encoding = "UTF-8"),
                     simplifyVector = simplify)
}

nz <- function(x) if (is.null(x)) NA_real_ else as.numeric(x)

utc_date <- function(unix) as.Date(as.POSIXct(unix, origin = "1970-01-01", tz = "UTC"))

# Append rows to a CSV, writing the header only when the file is new.
append_csv <- function(df, file) {
  if (!nrow(df)) return(invisible(0))
  new <- !file.exists(file)
  utils::write.table(df, file, sep = ",", row.names = FALSE,
                     col.names = new, append = !new, na = "")
  invisible(nrow(df))
}

dates_in <- function(file) {
  if (!file.exists(file)) return(as.Date(character(0)))
  unique(as.Date(utils::read.csv(file, colClasses = "character")$date))
}

# ------------------------- 1. ITEM TABLE -----------------------------

ITEMS <- file.path(DATA, "items.csv")

load_items <- function() {
  stale <- !file.exists(ITEMS) ||
    difftime(Sys.time(), file.info(ITEMS)$mtime, units = "days") > 7
  if (stale) {
    log_msg("refreshing item mapping")
    m <- fetch("/mapping", simplify = TRUE)
    keep <- intersect(c("id", "name", "members", "limit", "value",
                        "highalch", "lowalch", "examine"), names(m))
    utils::write.csv(m[, keep], ITEMS, row.names = FALSE, na = "")
  }
  utils::read.csv(ITEMS, stringsAsFactors = FALSE)
}

# ----------------------- 2. DAILY SNAPSHOT ---------------------------

PRICES <- file.path(DATA, "prices_daily.csv")

collect_prices <- function(items) {
  raw  <- fetch("/24h")
  # The /24h window is the 24 hours before the request, so it is labelled
  # with the UTC date it ENDS on: the date of this run. Backfill rows use
  # the same convention (bucket start + 1 day).
  day  <- as.Date(Sys.time(), tz = "UTC")
  if (day %in% dates_in(PRICES)) {
    log_msg("prices for ", day, " already stored - skipping")
    return(invisible(NULL))
  }
  ids <- names(raw$data)
  df <- data.frame(
    date     = as.character(day),
    id       = as.integer(ids),
    avg_high = vapply(raw$data, function(r) nz(r$avgHighPrice),    0),
    avg_low  = vapply(raw$data, function(r) nz(r$avgLowPrice),     0),
    vol_high = vapply(raw$data, function(r) nz(r$highPriceVolume), 0),
    vol_low  = vapply(raw$data, function(r) nz(r$lowPriceVolume),  0),
    source   = "daily",
    stringsAsFactors = FALSE
  )
  df$name <- items$name[match(df$id, items$id)]
  df <- df[, c("date", "id", "name", "avg_high", "avg_low",
               "vol_high", "vol_low", "source")]
  append_csv(df, PRICES)
  log_msg("stored ", nrow(df), " items for ", day)
}

# ------------------------ 3. BACKFILL --------------------------------

BACKFILL_DONE <- file.path(DATA, ".backfill_done")

backfill <- function(items) {
  if (file.exists(BACKFILL_DONE)) return(invisible(NULL))
  log_msg("first run: backfilling ", length(WATCHLIST), " watchlist items")
  have <- dates_in(PRICES)
  out  <- list()
  for (nm in WATCHLIST) {
    id <- items$id[tolower(items$name) == tolower(nm)][1]
    if (is.na(id)) { log_msg("  not found in mapping: ", nm); next }
    r <- tryCatch(fetch(sprintf("/timeseries?timestep=24h&id=%d", id),
                        simplify = TRUE)$data,
                  error = function(e) { log_msg("  failed ", nm, ": ",
                                                conditionMessage(e)); NULL })
    Sys.sleep(1)                         # be polite to a free API
    if (is.null(r) || !NROW(r)) next
    d <- data.frame(
      date     = as.character(utc_date(r$timestamp) + 1),
      id       = id,
      name     = items$name[items$id == id][1],
      avg_high = r$avgHighPrice,
      avg_low  = r$avgLowPrice,
      vol_high = r$highPriceVolume,
      vol_low  = r$lowPriceVolume,
      source   = "backfill",
      stringsAsFactors = FALSE
    )
    out[[nm]] <- d[!(as.Date(d$date) %in% have), ]   # never overlap the snapshot
  }
  n <- append_csv(do.call(rbind, out), PRICES)
  writeLines(as.character(Sys.time()), BACKFILL_DONE)
  log_msg("backfill stored ", n, " rows")
}

# ------------------------ 4. HISCORES --------------------------------

HISCORES <- file.path(DATA, "hiscores_daily.csv")

# Row order of the lite response. Do not reorder.
SKILLS <- c(
  "Overall", "Attack", "Defence", "Strength", "Hitpoints", "Ranged",
  "Prayer", "Magic", "Cooking", "Woodcutting", "Fletching", "Fishing",
  "Firemaking", "Crafting", "Smithing", "Mining", "Herblore", "Agility",
  "Thieving", "Slayer", "Farming", "Runecrafting", "Hunter",
  "Construction", "Sailing"
)

collect_hiscores <- function() {
  today <- as.character(as.Date(Sys.time(), tz = "UTC"))
  have  <- if (file.exists(HISCORES))
    utils::read.csv(HISCORES, colClasses = "character")[, c("date", "player")]
  else data.frame(date = character(0), player = character(0))

  for (pl in PLAYERS) {
    if (any(have$date == today & have$player == pl)) {
      log_msg("hiscores for ", pl, " already stored today"); next
    }
    resp <- tryCatch(
      httr::GET(paste0(HS, utils::URLencode(pl, reserved = TRUE)),
                httr::user_agent(USER_AGENT), httr::timeout(30)),
      error = function(e) NULL)
    if (is.null(resp) || httr::status_code(resp) != 200) {
      # A brand-new account is not on the hiscores until it has some
      # xp AND has logged out once. 404 is normal on day one.
      log_msg("hiscores unavailable for ", pl, " (status ",
              if (is.null(resp)) "none" else httr::status_code(resp), ")")
      next
    }
    txt  <- gsub("\r", "", httr::content(resp, as = "text", encoding = "UTF-8"))
    rows <- strsplit(trimws(txt), "\n")[[1]][seq_along(SKILLS)]
    m <- do.call(rbind, lapply(strsplit(rows, ","),
                               function(x) suppressWarnings(as.numeric(x[1:3]))))
    df <- data.frame(date = today, player = pl, skill = SKILLS,
                     rank = m[, 1], level = m[, 2], xp = m[, 3])
    # -1 means "not ranked" (too little xp), not a real number
    df[df == -1] <- NA
    append_csv(df, HISCORES)
    log_msg("stored hiscores for ", pl)
    Sys.sleep(1)
  }
}

# ============================ MAIN ===================================
# Each step is isolated: one failing endpoint does not lose the others.

log_msg("---- run start ----")
items <- tryCatch(load_items(), error = function(e) {
  log_msg("FATAL: mapping failed: ", conditionMessage(e)); quit(status = 1)
})
tryCatch(collect_prices(items), error = function(e) log_msg("prices failed: ", conditionMessage(e)))
tryCatch(backfill(items),       error = function(e) log_msg("backfill failed: ", conditionMessage(e)))
tryCatch(collect_hiscores(),    error = function(e) log_msg("hiscores failed: ", conditionMessage(e)))
log_msg("---- run end ----")
