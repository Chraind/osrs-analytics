# osrs-analytics

Automated daily data pipeline and analysis of the Old School RuneScape economy (R, GitHub Actions, Power BI).

Old School RuneScape has a closed player-driven economy with ~4,000 tradeable items, a fixed 2% sales tax, hard buy limits and public real-time trade data. That makes it a clean laboratory for market analysis: price formation, liquidity, forecasting and the effect of dated shocks such as game updates.

## Pipeline

| Step | What | Where |
|---|---|---|
| Collect | Daily 24h average price and volume for every item, plus player hiscores | `osrs_collector.R`, daily on GitHub Actions |
| Collect | Concurrent players online, split by members / F2P / seasonal / Deadman | `osrs_players.R`, hourly on GitHub Actions |
| Store | Append-only CSV files | `data/` |
| Analyse | Margins, liquidity, forecasting, event studies | coming |
| Present | Power BI dashboard and blog posts | coming |

The collector runs every day at 08:17 UTC (`.github/workflows/collect.yml`) and commits new data back to this repository. On its first run it also backfills up to a year of daily history for a watchlist of items.

## Monitors

Interactive scripts run by hand while playing, separate from the automated pipeline.

- `monitors/herblore_monitor.R` (v1): live profitability of two Herblore production chains, Bastion potions (XP route) and Prayer potions (profit route). It pulls the current order book, applies the 2% GE tax, equipment effects and service fees, prints netted vs instant vs worst-case margins, computes a break-even "tripwire" price for the dominant input, and costs the remaining road to level 99 from the player's live hiscores. Used during a real training run that gained ~2.8M Herblore XP while growing the bank from ~34M to ~50M gp.

## Data

- `data/prices_daily.csv`: `date, id, name, avg_high, avg_low, vol_high, vol_low, source`. `date` is the UTC day the 24h window ends. `source` is `daily` (snapshot) or `backfill`.
- `data/items.csv`: item dimension table (id, name, members, buy limit, alch values).
- `data/hiscores_daily.csv`: `date, player, skill, rank, level, xp`.
- `data/players_hourly.csv`: `timestamp_utc, total, main_game, members, f2p, seasonal, deadman, worlds_online`, read from the official world list. These are **concurrent** players at the time of the snapshot, not unique daily players, which Jagex does not publish. Daily activity is estimated as the mean and peak of the hourly snapshots.

## Sources

Prices: [OSRS Wiki real-time prices API](https://prices.runescape.wiki/), built with RuneLite. Hiscores: official Old School RuneScape hiscores.

## Running locally

```r
install.packages(c("httr", "jsonlite"))
source("osrs_collector.R")
```

On Windows, `install_collector_task.ps1` registers the collector as a daily scheduled task instead.
