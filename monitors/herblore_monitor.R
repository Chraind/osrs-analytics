# =====================================================================
#  HERBLORE MONITOR  --  live GE prices -> chain economics
#  Data: OSRS Wiki real-time prices API (RuneLite partnership)
#
#  Doctrine encoded here (see herblore.md):
#    - DOSES ARE THE UNIT. Mix yields 3-dose, market sells 4-dose.
#    - Prescription goggles: x0.9 on the SECONDARY ONLY (wine / snape).
#      NOT the vial, NOT the herb, NOT the Zahur fee.
#    - Alchemist's amulet: 3.15 average doses per potion.
#    - GE tax 2% on sale.
#    - Zahur 200/service; grimy runs pay twice (clean + unf).
#
#  Requires: install.packages(c("httr","jsonlite"))
# =====================================================================

# ---------------------------- CONFIG ---------------------------------

# The API asks that you identify yourself. Put a Discord tag or email here.
USER_AGENT <- "herblore-monitor - discord: Chriand"

DOSES   <- 3.15   # alchemist's amulet: 3 + 0.15
TAX     <- 0.98   # GE takes 2% on sale
GOGGLES <- 0.90   # applies to the SECONDARY line only
ZAHUR   <- 200    # per service

# Set to your observed rate if you want the pessimistic view.
# The 533-potion prayer batch measured 3.126.
# DOSES <- 3.126

# Throughput. 2500/hr is the wiki's tick-perfect-with-banking figure -
# it is a ceiling, not a sustained average. Drop it if you want realism.
MIXES_PER_HOUR <- 2500

# Alchemist's amulet charges. One charge burns per proc.
PROC_RATE          <- 0.15   # 15% chance of the bonus dose
CHARGES_PER_AMULET <- 10     # verified in game
CHARGES_HELD       <- 1162    # update this when you recharge

XP_PER_MIX <- 155            # bastion; prayer is 87.5

API <- "https://prices.runescape.wiki/api/v1/osrs"
HS  <- "https://secure.runescape.com/m=hiscore_oldschool/index_lite.ws?player="

# Your OSRS name - pulls live Herblore XP so the road below costs itself.
# Set to NA to skip the hiscores lookup entirely.
PLAYER <- "Cyrotion"
RIVAL  <- NA        # e.g. "bonubo" for the total-level scoreboard

# --------------------------- PLUMBING --------------------------------

for (p in c("httr", "jsonlite")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop(sprintf('Missing package "%s".  Run: install.packages("%s")', p, p))
  }
}

fetch <- function(path, simplify = FALSE) {
  url  <- paste0(API, path)
  resp <- httr::GET(url, httr::user_agent(USER_AGENT))
  httr::stop_for_status(resp)
  jsonlite::fromJSON(
    httr::content(resp, as = "text", encoding = "UTF-8"),
    simplifyVector = simplify
  )
}

# The item->id map is ~4000 rows and basically never changes.
# Cache it next to the script so we only pull it once.
load_mapping <- function(cache = "osrs_mapping.rds") {
  if (file.exists(cache)) return(readRDS(cache))
  message("Fetching item mapping (one time)...")
  m <- fetch("/mapping", simplify = TRUE)
  saveRDS(m, cache)
  m
}

id_of <- function(mapping, item_name) {
  hit <- which(tolower(mapping$name) == tolower(item_name))
  if (length(hit) == 0) stop(sprintf('No item named "%s" in mapping.', item_name))
  mapping$id[hit[1]]
}

# Returns c(high = instabuy, low = instasell).
#   high = what you PAY to buy right now
#   low  = what you RECEIVE selling right now
#
# WARNING: these are LAST TRADE prices, not the live bid/ask. They carry
# timestamps and can be hours stale. If low > high the book is "crossed",
# which means one side has not traded recently - do NOT trust it.
px <- function(latest, id) {
  rec <- latest$data[[as.character(id)]]
  nz  <- function(x) if (is.null(x)) NA_real_ else as.numeric(x)
  if (is.null(rec)) {
    return(c(high = NA_real_, low = NA_real_,
             highTime = NA_real_, lowTime = NA_real_))
  }
  c(high     = nz(rec$high),     low     = nz(rec$low),
    highTime = nz(rec$highTime), lowTime = nz(rec$lowTime))
}

# Minutes since that side last traded.
age <- function(t) {
  if (is.na(t)) return("    ?")
  sprintf("%4.0fm", (as.numeric(Sys.time()) - t) / 60)
}

# --------------------------- THE MATH --------------------------------

chain <- function(vial, herb, secondary, zahur, sale,
                  doses = DOSES, tax = TAX, goggles = GOGGLES,
                  charge = CHARGE_COST) {
  cost_potion <- vial + herb + zahur + secondary * goggles + charge
  cost_dose   <- cost_potion / doses
  net_dose    <- sale * tax / 4
  list(
    cost_potion    = cost_potion,
    cost_dose      = cost_dose,
    net_dose       = net_dose,
    profit_per_4   = 4 * (net_dose - cost_dose),
    profit_per_mix = doses * (net_dose - cost_dose),
    breakeven_4    = cost_dose * 4 / tax
  )
}

# Highest price you can pay for ONE input and still break even.
ceiling_for <- function(other_costs, sale, doses = DOSES, tax = TAX) {
  sale * tax / 4 * doses - other_costs
}

# ------------------------- XP / LEVELLING ----------------------------

# Row order of the OSRS hiscores lite response. Do not reorder -
# Herblore's position is what makes the lookup work.
SKILLS <- c(
  "Overall", "Attack", "Defence", "Strength", "Hitpoints", "Ranged",
  "Prayer", "Magic", "Cooking", "Woodcutting", "Fletching", "Fishing",
  "Firemaking", "Crafting", "Smithing", "Mining", "Herblore", "Agility",
  "Thieving", "Slayer", "Farming", "Runecrafting", "Hunter",
  "Construction", "Sailing"
)

hiscores <- function(player) {
  url  <- paste0(HS, utils::URLencode(player, reserved = TRUE))
  resp <- httr::GET(url, httr::user_agent(USER_AGENT))
  if (httr::status_code(resp) == 404) {
    stop(sprintf('Player "%s" is not on the hiscores (or the name is off).', player))
  }
  httr::stop_for_status(resp)
  txt  <- gsub("\r", "", httr::content(resp, as = "text", encoding = "UTF-8"))
  rows <- strsplit(trimws(txt), "\n")[[1]]
  rows <- rows[seq_len(min(length(rows), length(SKILLS)))]
  m <- do.call(rbind, lapply(strsplit(rows, ","), function(x) {
    suppressWarnings(as.numeric(x[1:3]))
  }))
  data.frame(
    skill = SKILLS[seq_len(nrow(m))],
    rank  = m[, 1], level = m[, 2], xp = m[, 3],
    stringsAsFactors = FALSE
  )
}

skill_xp <- function(hs, name) {
  v <- hs$xp[hs$skill == name]
  if (length(v) == 0 || is.na(v)) NA_real_ else v
}

xp_for_level <- function(L) {
  if (L <= 1) return(0)
  floor(sum(floor(seq_len(L - 1) + 300 * 2^(seq_len(L - 1) / 7))) / 4)
}

mixes_to <- function(current_xp, target_level, xp_per_mix = 155) {
  need <- xp_for_level(target_level) - current_xp
  if (need <= 0) return(0)
  ceiling(need / xp_per_mix)
}

# --------------------------- REPORTING -------------------------------

gp <- function(x) formatC(round(x), big.mark = ",", format = "d")

report <- function(label, r, sale, ok_note = "") {
  cat(sprintf("\n  %s  (sale %s)\n", label, gp(sale)))
  cat(sprintf("    cost/potion   %10s\n", gp(r$cost_potion)))
  cat(sprintf("    cost/dose     %10s\n", gp(r$cost_dose)))
  cat(sprintf("    net/dose      %10s\n", gp(r$net_dose)))
  cat(sprintf("    profit per(4) %10s   %s\n", gp(r$profit_per_4),
              if (r$profit_per_4 > 0) "GREEN" else "*** RED ***"))
  cat(sprintf("    profit per mix%10s\n", gp(r$profit_per_mix)))
  cat(sprintf("    break-even(4) %10s   (cushion %s)\n",
              gp(r$breakeven_4), gp(sale - r$breakeven_4)))
  if (nzchar(ok_note)) cat(sprintf("    %s\n", ok_note))
}

rule <- function(txt) cat(sprintf("\n%s\n%s\n", txt, strrep("-", nchar(txt))))

# ============================ MAIN ===================================

mapping <- load_mapping()
latest  <- fetch("/latest")

items <- c(
  vial      = "Vial of blood",
  cad_g     = "Grimy cadantine",
  cad_c     = "Cadantine",
  wine      = "Wine of zamorak",
  bastion4  = "Bastion potion(4)",
  ranarr_u  = "Ranarr potion (unf)",
  ranarr_g  = "Grimy ranarr weed",
  ranarr_c= "ranarr weed",
  snape     = "Snape grass",
  prayer4   = "Prayer potion(4)",
  amulet    = "Amulet of chemistry"
)

P <- lapply(items, function(nm) px(latest, id_of(mapping, nm)))

# Cost of the amulet charge burned on each proc, spread over every potion.
# 15% of mixes proc, each burns 1 of 10 charges.
CHARGE_COST <- PROC_RATE * P$amulet["low"] / CHARGES_PER_AMULET

cat(sprintf("\n%s   OSRS Herblore monitor\n", format(Sys.time(), "%Y-%m-%d %H:%M")))
cat(sprintf("doses/potion %.3f   tax %.0f%%   goggles x%.2f on secondary only\n",
            DOSES, (1 - TAX) * 100, GOGGLES))

rule("LIVE BOOK")
cat(sprintf("  %-22s %10s %6s %10s %6s\n",
            "item", "instabuy", "age", "instasell", "age"))
for (k in names(items)) {
  crossed <- !is.na(P[[k]]["low"]) && !is.na(P[[k]]["high"]) &&
    P[[k]]["low"] > P[[k]]["high"]
  cat(sprintf("  %-22s %10s %6s %10s %6s%s\n", items[[k]],
              gp(P[[k]]["high"]), age(P[[k]]["highTime"]),
              gp(P[[k]]["low"]),  age(P[[k]]["lowTime"]),
              if (crossed) "   <- CROSSED, one side is stale" else ""))
}

# ---- BASTION --------------------------------------------------------

rule("BASTION  (vial of blood + cadantine + wine of zamorak)")

sale_wall <- P$bastion4["high"]   # patient wall, near the instabuy line
sale_dump <- P$bastion4["low"]    # what a dump realises

# Grimy route: buy grimy, Zahur cleans AND makes the unf -> 2 services.
# Clean route: buy clean, Zahur only makes the unf -> 1 service.
# Herb rule: whichever total is lower wins. Check every time.
grimy_total <- P$cad_g["low"] + 2 * ZAHUR
clean_total <- P$cad_c["low"] + 1 * ZAHUR

grimyR_total <- P$ranarr_g["low"] + 2 * ZAHUR
cleanR_total <- P$ranarr_c["low"] + 1 * ZAHUR

route <- if (grimy_total <= clean_total) "GRIMY" else "CLEAN"
routeR <- if (grimyR_total <= cleanR_total) "GRIMY" else "CLEAN"

cat(sprintf("\n  herb rule:  grimy %s + 400 = %s   vs   clean %s + 200 = %s   -> buy %s\n",
            gp(P$cad_g["low"]), gp(grimy_total),
            gp(P$cad_c["low"]), gp(clean_total), route))

cat(sprintf("\n  herb rule:  grimy %s + 400 = %s   vs   clean %s + 200 = %s   -> buy %s\n",
            gp(P$ranarr_g["low"]), gp(grimyR_total),
            gp(P$ranarr_c["low"]), gp(cleanR_total), routeR))



herb_px <- if (route == "GRIMY") P$cad_g["low"] else P$cad_c["low"]
herb_fee <- if (route == "GRIMY") 2 * ZAHUR else 1 * ZAHUR

# Netted inputs (patient buy offers at the instasell line)
b_net <- chain(P$vial["low"], herb_px, P$wine["low"], herb_fee, sale_wall)
# Instant inputs (pay the ask)
b_ins <- chain(P$vial["high"],
               if (route == "GRIMY") P$cad_g["high"] else P$cad_c["high"],
               P$wine["high"], herb_fee, sale_wall)
# Worst case: pay up on inputs, dump on the way out
b_bad <- chain(P$vial["high"],
               if (route == "GRIMY") P$cad_g["high"] else P$cad_c["high"],
               P$wine["high"], herb_fee, sale_dump)

report("netted inputs -> patient wall", b_net, sale_wall)
report("instant inputs -> patient wall", b_ins, sale_wall)
report("instant inputs -> instant dump", b_bad, sale_dump)

vial_ceil <- ceiling_for(herb_px + herb_fee + P$wine["low"] * GOGGLES + CHARGE_COST,
                         sale_wall)
cat(sprintf("\n  amulet charges: %s/ea -> %s per potion\n",
            gp(P$amulet["low"]), gp(CHARGE_COST)))
cat(sprintf("  VIAL TRIPWIRE: stop buying above %s  (now %s, headroom %s)\n",
            gp(vial_ceil), gp(P$vial["low"]), gp(vial_ceil - P$vial["low"])))
cat("  NB: this ceiling moves with the (4) price, not the vial. Watch the potion.\n")

# Amulet sensitivity - at 3.00 doses the chain often flips red.
b_noamu <- chain(P$vial["low"], herb_px, P$wine["low"], herb_fee, sale_wall, doses = 3.00)
cat(sprintf("  amulet check: at 3.00 doses profit per(4) = %s (break-even %s)\n",
            gp(b_noamu$profit_per_4), gp(b_noamu$breakeven_4)))

# ---- PRAYER ---------------------------------------------------------

rule("PRAYER  (ranarr potion (unf) + snape grass)  -- 87.5 xp/mix")

pr_net <- chain(0, P$ranarr_u["low"], P$snape["low"], 0, P$prayer4["high"])
pr_ins <- chain(0, P$ranarr_u["high"], P$snape["high"], 0, P$prayer4["high"])
report("netted inputs -> patient wall", pr_net, P$prayer4["high"])
report("instant inputs -> patient wall", pr_ins, P$prayer4["high"])

unf_ceil <- ceiling_for(P$snape["low"] * GOGGLES + CHARGE_COST, P$prayer4["high"])
cat(sprintf("\n  UNF TRIPWIRE: stop buying above %s  (now %s)\n",
            gp(unf_ceil), gp(P$ranarr_u["low"])))

# ---- WHICH CHAIN ----------------------------------------------------

rule("CHAIN COMPARISON")
cat(sprintf("  bastion:  %s gp/mix,  155.0 xp/mix,  %6.2f gp per xp\n",
            gp(b_net$profit_per_mix), b_net$profit_per_mix / 155))
cat(sprintf("  prayer :  %s gp/mix,   87.5 xp/mix,  %6.2f gp per xp\n",
            gp(pr_net$profit_per_mix), pr_net$profit_per_mix / 87.5))
cat("  bastion = fewer clicks per level, thin book (patience, tranche 400-550)\n")
cat("  prayer  = more clicks, deep book (velocity, clears same day)\n")

# ---- ROAD -----------------------------------------------------------

CURRENT_XP <- NA_real_

if (!is.na(PLAYER)) {
  hs <- hiscores(PLAYER)
  CURRENT_XP <- skill_xp(hs, "Herblore")
  
  rule(sprintf("ACCOUNT: %s", PLAYER))
  cat(sprintf("  total level %s   total xp %s\n",
              gp(hs$level[hs$skill == "Overall"]),
              gp(hs$xp[hs$skill == "Overall"])))
  cat(sprintf("  Herblore %2d  (%s xp)\n",
              hs$level[hs$skill == "Herblore"], gp(CURRENT_XP)))
  
  if (!is.na(RIVAL)) {
    r <- try(hiscores(RIVAL), silent = TRUE)
    if (!inherits(r, "try-error")) {
      d <- hs$level[hs$skill == "Overall"] - r$level[r$skill == "Overall"]
      cat(sprintf("  %s total level %s   -> %+d\n",
                  RIVAL, gp(r$level[r$skill == "Overall"]), d))
    }
  }
}

if (!is.na(CURRENT_XP)) {
  rule("ROAD (bastion, netted inputs, at the current wall)")
  
  lv_now  <- max(2, floor(max(which(sapply(1:99, xp_for_level) <= CURRENT_XP))))
  targets <- (lv_now + 1):99
  if (length(targets) == 0) targets <- integer(0)
  
  cat(sprintf("  %-5s | %8s %7s %12s %11s %6s | %9s %8s %6s\n",
              "lvl", "mixes", "procs", "capital", "profit", "hrs",
              "cum mix", "cum proc", "cum hr"))
  cat(sprintf("  %s\n", strrep("-", 89)))
  
  prev <- CURRENT_XP
  cum_m <- 0
  for (L in targets) {
    step_xp <- xp_for_level(L) - prev
    m       <- ceiling(step_xp / XP_PER_MIX)
    prev    <- xp_for_level(L)
    cum_m   <- cum_m + m
    cat(sprintf("  %-5d | %8s %7s %12s %11s %6.1f | %9s %8s %6.1f\n",
                L, gp(m), gp(m * PROC_RATE),
                gp(m * b_net$cost_potion), gp(m * b_net$profit_per_mix),
                m / MIXES_PER_HOUR,
                gp(cum_m), gp(cum_m * PROC_RATE), cum_m / MIXES_PER_HOUR))
  }
  
  # ---- amulet charges for the whole road ----
  procs_left <- cum_m * PROC_RATE
  short      <- max(0, procs_left - CHARGES_HELD)
  # 3 SD of a binomial over the remaining mixes, so you buy once and forget
  sd3        <- 3 * sqrt(cum_m * PROC_RATE * (1 - PROC_RATE))
  need_amu   <- ceiling((short + sd3) / CHARGES_PER_AMULET)
  
  cat(sprintf("\n  CHARGES: %s procs to 99, %s held -> short %s (+%s at 3sd)\n",
              gp(procs_left), gp(CHARGES_HELD), gp(short), gp(sd3)))
  if (need_amu > 0) {
    cat(sprintf("  BUY %s amulets of chemistry @ %s = %s\n",
                gp(need_amu), gp(P$amulet["low"]),
                gp(need_amu * P$amulet["low"])))
  } else {
    cat("  Charges cover the road. Nothing to buy.\n")
  }
  
  cat(sprintf("\n  hours at %s mixes/hr (wiki tick-perfect figure - a ceiling).\n",
              gp(MIXES_PER_HOUR)))
  cat("  Capital recycles as walls clear - size batches to what you can\n")
  cat("  sell, not to what you can afford.\n")
}

cat("\n")
