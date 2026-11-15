# OVERWATCH log: osrs-analytics

Running log of the plan, decisions and progress. Newest entries at the top.

## Current plan: get more data

1. **Full-market 365-day backfill** (in progress)
   - Source: OSRS Wiki timeseries endpoint, one call per item (`/timeseries?timestep=24h&id=`). Returns up to 365 daily points.
   - Script: `tools/backfill_full_market.ps1` (PowerShell, because R is not installed on this machine).
   - Output: `%USERPROFILE%\osrs-data-local\prices_backfill_365d.csv`. Kept outside git: about 150 MB, and GitHub rejects files over 100 MB.
   - Resumable: progress is checkpointed in `backfill_done_ids.txt`. Failures go to `backfill_errors.log`.
   - Expected run time: about 90 minutes at 1.2 s per request.
2. **Fix hourly player-count gaps.** Not a failing job; see the correction below.
3. **Add accounts to hiscores** (`PLAYERS` in `osrs_collector.R`), with the account owner's permission.
4. **Start an events table** for game updates, with dates and sources. Needed for event studies.
5. **Convert storage to Parquet** once the full history exists.

## Log

### 2026-11-15: outage check (partly confirmed by public reports)
- **Reported 2026-11-09 to 2026-11-10:** a major infrastructure failure took RuneScape and OSRS offline for about four hours, followed by an emergency rollback. Sources (search snippets, not opened in full): https://massivelyop.com/2026/11/10/runescape-and-osrs-performed-an-emergency-rollback-yesterday-evening-after-an-incident/ and https://runescape.wiki/?diff=37235228 (login-server PSA).
- **Matches our data:** the 2026-11-09 dip to about 27k fits this window. It may be a real outage rather than a bad read; this needs checking against the wiki PSA times.
- **Reported October 2026:** worlds taken offline after a bug killed players and deleted gear (GamesRadar, dated 7 Oct 2026). Before our player data starts on 2026-10-18.
- **Not explained:** the 2026-11-03 total of 0. No source found yet.
- **Caveat:** these are search snippets. Full posts not read. The official Jagex post for the November incident was not found.

### 2026-11-15: player-count check ("drop of about 4,000")
- **Not confirmed.** Daily mean total players stay between about 104k and 125k across 2026-10-19 to 2026-11-12. No sustained drop.
- **Cannot detect a 4,000 change.** Each day has 3–7 samples taken at irregular hours. Hourly swings reach 50k+ within hours, so a 4k shift is below the noise.
- **Two artifacts to fix:** total = 0 at 2026-11-03 01:31 (failed read), and a dip to about 27k on 2026-11-09 (partial read). Exclude or flag these.
- **Link to World of Warcraft:** not verified. Source of the 4,000 figure needed.
- **Fix needed for any trend:** sample at fixed UTC hours, or compare same-hour samples. Otherwise the time-of-day cycle dominates.

### 2026-11-12: environment and backfill restart
- **R 4.5.1 installed** by you. Not yet on PATH in the current shell; open a new terminal to use `Rscript`.
- **First backfill attempt failed.** Every request timed out at 30 s. Single-request timing was erratic: 42 s on one item, then 0.1 s and 0.4 s on others, so the API was slow but not blocking. Stopped the run.
- **Fix:** timeout raised to 120 s, with 3 attempts and a backoff, in `tools/backfill_full_market.ps1`. Restarted. Progress file and error log are in `%USERPROFILE%\osrs-data-local\`.
- **Open risk:** if slow responses are common, a full run takes much longer than the 90-minute estimate. Check the progress count before planning around the estimate.

### 2026-11-12: checks and decisions
- **Date convention confirmed.** The wiki timeseries timestamp is the start of the 24h window. The repo's `date` is the day the window ends. So `date = timestamp UTC date + 1 day`. Checked on item 257 (Ranarr weed): the 2026-11-09 repo row matches the window starting 2026-11-08.
- **Data-quality issue found.** The newest daily snapshot (2026-11-10) for item 257 matches the 11-09 window exactly, not the 11-10 window. The 2026-11-10 snapshot may have been taken before that day finished. Treat the newest day as provisional until this is checked.
- **Coverage.** Full-market price coverage (4,200+ items per day) starts on 2026-10-18. Before that, only the watchlist (~25 items) has history. The timeseries backfill fixes this for all items.
- **Correction to earlier analysis.** I previously said hourly player counts were missing about 80% of runs. The job runs, but GitHub's scheduled runs fire about 5–10 times a day instead of 24. Recent runs all show `success`, except one `cancelled` run on 2026-11-11. Cause is GitHub schedule throttling, not a failing job. Fix is more frequent cron entries or a different scheduler, not a code change.
- **Collector run history.** `collect.yml` has one `cancelled` run (2026-11-11). Daily runs otherwise succeed.

## Backfill documentation (for review)

**Status at writing:** backfill still running. Validation and final coverage are **pending**; no result below is final.

**Source.** OSRS Wiki real-time prices API, `/timeseries?timestep=24h&id=<item id>`. Each point is a 24h average high/low price and trade volumes, from the wiki's collection of game trade data. These are observed, not reconstructed. The wiki returns up to 365 points per item.

**Date convention.** API `timestamp` is the start of the 24h window. Stored `date` = timestamp UTC date + 1 day, matching `prices_daily.csv` (checked on item 257).

**Deduplication key.** `(date, id)`. Both sources use it. The backfill writes to its own file and does not dedupe against `prices_daily.csv`; that merge step is not written yet. Proposed rule when merging: keep the existing daily row where both exist, since it came from the daily snapshot.

**Does it preserve existing data?** Yes. The script writes only to `%USERPROFILE%\osrs-data-local\`. It never opens or writes anything under `data/`.

**Does it conflict with the daily collectors?** No. The collectors commit only to `data/` on `main`. This branch changes only `tools/` and `OVERWATCH.md`, and the backfill runs outside the repo. Merging the branch later cannot clash with the daily data commits.

**Historical observed vs. unavailable data.**
- Observed: any `(date, id)` the wiki returned a point for.
- Unavailable: days with no trades, or items the API has no history for. The script writes nothing for those, so they show as gaps, not zeros. This is not confirmed yet; check the API's behaviour on a thinly traded item during validation.
- Reconstructed: none. The script does not fill or interpolate.

**Known problems in the first run.**
- Timeouts: the first run had every request time out at 30 s (see the 2026-11-12 entry above). Fixed by raising the timeout to 120 s with retries.
- Errors so far in the current run: see `backfill_errors.log` (sanitized copy in `tools/logs/`).

**Validation results (partial run, 1,537 items, 546,601 rows).**
1. Row count per item: max 365. Pass.
2. Duplicate `(date, id)` keys: 0. Pass.
3. Date convention: the backfill matches the collector's own `source = backfill` rows exactly, 3,051 of 3,051 overlapping rows. Pass.
4. **Fail: blank prices.** 62,770 rows (about 11%) have one side of the price missing.
5. **Fail: high below low.** 44,783 rows (about 8%) have `avg_high < avg_low`. Kept as recorded, not corrected; decide a rule before analysis.
6. **Fail: sparse history.** 162 of 1,537 items have 365 points spanning more than 400 days. "One year" holds only for liquid items. Thin items have gaps, and the data does not say which days are missing.
7. **Open: daily snapshot disagrees with the timeseries.** Against the 37,527 overlapping `prices_daily.csv` rows, only 18.5% match on the same date. Shifting the snapshot back one day gives 84.5%. So the snapshot's date label may be one day off, or it uses a different window. Unresolved; needs a reviewer decision before merging the two sources.
8. Item count: 1,537 of 4,663 so far, still running. Coverage check pending.

**Limitations.**
- The script omits items that fail after 3 attempts. The error log lists them, so they can be retried.
- Accuracy depends on the wiki's collection; this repo cannot verify it independently.
- Volume figures may be incomplete for thin markets.

### Open questions
- Who is "Overwatch"? No file named overwatch was found on this machine. This log is a stand-in until the right file or location is named.
