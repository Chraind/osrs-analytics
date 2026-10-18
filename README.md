# osrs-analytics

Automated daily data pipeline and analysis of the Old School RuneScape economy (R, GitHub Actions, Power BI).

Old School RuneScape has a closed player-driven economy with ~4,000 tradeable items, a fixed 2% sales tax, hard buy limits and public real-time trade data. That makes it a clean laboratory for market analysis: price formation, liquidity, forecasting and the effect of dated shocks such as game updates.

## Pipeline

| Step | What | Where |
|---|---|---|
| Collect | Daily 24h average price and volume for every item, plus player hiscores | `osrs_collector.R`, run by GitHub Actions |
| Store | Append-only CSV files | `data/` |
| Analyse | Margins, liquidity, forecasting, event studies | coming |
| Present | Power BI dashboard and blog posts | coming |

The collector runs every day at 08:17 UTC (`.github/workflows/collect.yml`) and commits new data back to this repository. On its first run it also backfills up to a year of daily history for a watchlist of items.

## Data

- `data/prices_daily.csv`: `date, id, name, avg_high, avg_low, vol_high, vol_low, source`. `date` is the UTC day the 24h window ends. `source` is `daily` (snapshot) or `backfill`.
- `data/items.csv`: item dimension table (id, name, members, buy limit, alch values).
- `data/hiscores_daily.csv`: `date, player, skill, rank, level, xp`.

## Sources

Prices: [OSRS Wiki real-time prices API](https://prices.runescape.wiki/), built with RuneLite. Hiscores: official Old School RuneScape hiscores.

## Running locally

```r
install.packages(c("httr", "jsonlite"))
source("osrs_collector.R")
```

On Windows, `install_collector_task.ps1` registers the collector as a daily scheduled task instead.
