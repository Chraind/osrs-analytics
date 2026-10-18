# =====================================================================
#  OSRS PLAYER COUNT  --  one snapshot per hour
#
#  Source: the official world list the game client itself downloads
#  (oldschool.runescape.com/slr.ws). It is a small binary file listing
#  every world with its type flags and current player count.
#
#  What this measures: CONCURRENT players at the moment of the run,
#  not unique daily players. Jagex does not publish daily actives.
#  Daily figures are built later as mean / peak / trough of the hourly
#  snapshots. Say that plainly wherever the numbers are shown.
#
#  Output: data/players_hourly.csv, one row per run.
#  Requires: install.packages("httr")
# =====================================================================

USER_AGENT <- "osrs-analytics player count - discord: Chriand"
SLR <- "https://oldschool.runescape.com/slr.ws?order=LPWM"

script_dir <- local({
  a <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(sub("^--file=", "", a[1]))) else getwd()
})
DATA <- file.path(script_dir, "data")
dir.create(DATA, showWarnings = FALSE)
OUT <- file.path(DATA, "players_hourly.csv")
LOG <- file.path(DATA, "collector.log")

log_msg <- function(...) {
  line <- sprintf("%s  [players] %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S", tz = "UTC"),
                  paste0(...))
  cat(line, "\n"); cat(line, "\n", file = LOG, append = TRUE)
}

# World type bit flags, as used by the game client (RuneLite WorldType).
F_MEMBERS  <- bitwShiftL(1L, 0)
F_DEADMAN  <- bitwShiftL(1L, 29)
F_SEASONAL <- bitwShiftL(1L, 30)    # Leagues and other seasonal modes

# --------------------------- PARSER ----------------------------------
# Layout (big-endian):
#   int32  payload length
#   uint16 world count
#   per world:
#     uint16 id
#     int32  type flags
#     string address   (null-terminated)
#     string activity  (null-terminated)
#     uint8  location
#     int16  players   (-1 = world offline)

parse_worlds <- function(buf) {
  pos <- 1L
  u8  <- function() { v <- as.integer(buf[pos]); pos <<- pos + 1L; v }
  u16 <- function() { v <- u8() * 256L + u8(); v }
  i16 <- function() { v <- u16(); if (v >= 32768L) v - 65536L else v }
  i32 <- function() {
    v <- readBin(buf[pos:(pos + 3L)], "integer", size = 4, endian = "big")
    pos <<- pos + 4L; v
  }
  str <- function() {
    end <- pos
    while (buf[end] != as.raw(0)) end <- end + 1L
    s <- if (end > pos) rawToChar(buf[pos:(end - 1L)]) else ""
    pos <<- end + 1L
    s
  }

  i32()                       # payload length, not needed
  n <- u16()
  w <- data.frame(id = integer(n), flags = integer(n), activity = character(n),
                  location = integer(n), players = integer(n),
                  stringsAsFactors = FALSE)
  for (k in seq_len(n)) {
    w$id[k]       <- u16()
    w$flags[k]    <- i32()
    str()                     # address
    w$activity[k] <- str()
    w$location[k] <- u8()
    w$players[k]  <- i16()
  }
  w
}

# ---------------------------- MAIN -----------------------------------

resp <- tryCatch(httr::GET(SLR, httr::user_agent(USER_AGENT), httr::timeout(30)),
                 error = function(e) { log_msg("request failed: ", conditionMessage(e)); NULL })
if (is.null(resp) || httr::status_code(resp) != 200) {
  log_msg("world list unavailable (status ",
          if (is.null(resp)) "none" else httr::status_code(resp), ")")
  quit(status = 0)            # a missed hour is a gap, not a failure
}

w <- tryCatch(parse_worlds(httr::content(resp, as = "raw")),
              error = function(e) { log_msg("parse failed: ", conditionMessage(e)); NULL })
if (is.null(w) || !nrow(w)) quit(status = 0)

on   <- w[w$players >= 0, ]
has  <- function(f) bitwAnd(on$flags, f) != 0
seas <- has(F_SEASONAL)
dmm  <- has(F_DEADMAN)
main <- !seas & !dmm

row <- data.frame(
  timestamp_utc  = format(Sys.time(), "%Y-%m-%d %H:%M:%S", tz = "UTC"),
  total          = sum(on$players),
  main_game      = sum(on$players[main]),
  members        = sum(on$players[main &  has(F_MEMBERS)]),
  f2p            = sum(on$players[main & !has(F_MEMBERS)]),
  seasonal       = sum(on$players[seas]),
  deadman        = sum(on$players[dmm]),
  worlds_online  = nrow(on)
)

new <- !file.exists(OUT)
utils::write.table(row, OUT, sep = ",", row.names = FALSE,
                   col.names = new, append = !new)
log_msg(sprintf("total %d (members %d, f2p %d, seasonal %d) on %d worlds",
                row$total, row$members, row$f2p, row$seasonal, row$worlds_online))
