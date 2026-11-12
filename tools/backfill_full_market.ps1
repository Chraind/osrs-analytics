# =====================================================================
#  FULL-MARKET 365-DAY BACKFILL
#
#  Pulls the 24h history for EVERY item in data/items.csv from the
#  OSRS Wiki timeseries endpoint (one call per item, up to 365 days).
#
#  Date convention (checked against existing prices_daily.csv rows):
#    the API timestamp is the START of the 24h window. This repo's
#    'date' is the day the window ENDS, so date = timestamp UTC date + 1.
#
#  Output is written OUTSIDE the git repo (the file is ~150 MB and
#  GitHub rejects files over 100 MB):
#    C:\Users\chria\osrs-data-local\prices_backfill_365d.csv
#  Progress is checkpointed, so the script can be re-run to resume.
#
#  Rate: one request every 1.2 s, to stay polite to the wiki API.
#  Expect about 90 minutes for ~4,660 items.
# =====================================================================

$ErrorActionPreference = "Continue"
$UserAgent = "osrs-analytics-backfill"   # identify the client; no personal details here
$Api = "https://prices.runescape.wiki/api/v1/osrs/timeseries?timestep=24h&id="
$RepoDir = Split-Path -Parent $PSScriptRoot
$OutDir = Join-Path $env:USERPROFILE "osrs-data-local"   # outside the repo, never committed
$Out = Join-Path $OutDir "prices_backfill_365d.csv"
$Done = Join-Path $OutDir "backfill_done_ids.txt"
$ErrLog = Join-Path $OutDir "backfill_errors.log"
$Items = Join-Path $RepoDir "data\items.csv"

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
if (-not (Test-Path $Out)) {
    "date,id,name,avg_high,avg_low,vol_high,vol_low,source" | Out-File -FilePath $Out -Encoding utf8
}
$doneIds = @{}
if (Test-Path $Done) { Get-Content $Done | ForEach-Object { $doneIds[$_] = $true } }

$list = Import-Csv $Items
$total = $list.Count
$n = 0
foreach ($it in $list) {
    $n++
    if ($doneIds.ContainsKey($it.id)) { continue }
    $resp = $null
    for ($attempt = 1; $attempt -le 3 -and -not $resp; $attempt++) {
        try {
            $resp = Invoke-RestMethod -Uri ($Api + $it.id) -Headers @{ "User-Agent" = $UserAgent } -TimeoutSec 120
        }
        catch {
            if ($attempt -eq 3) { Add-Content -Path $ErrLog -Value ("{0}  id={1}  {2}" -f (Get-Date -Format "s"), $it.id, $_.Exception.Message) }
            else { Start-Sleep -Seconds (10 * $attempt) }
        }
    }
    if ($resp) {
        $rows = foreach ($p in $resp.data) {
            $utc = ([DateTimeOffset]::FromUnixTimeSeconds([long]$p.timestamp)).UtcDateTime.AddDays(1).ToString("yyyy-MM-dd")
            $name = '"' + ($it.name -replace '"', '""') + '"'
            "{0},{1},{2},{3},{4},{5},{6},backfill365" -f $utc, $it.id, $name, $p.avgHighPrice, $p.avgLowPrice, $p.highPriceVolume, $p.lowPriceVolume
        }
        if ($rows) { Add-Content -Path $Out -Value $rows -Encoding utf8 }
        Add-Content -Path $Done -Value $it.id
    }
    if ($n % 200 -eq 0) { Write-Output ("progress {0}/{1}" -f $n, $total) }
    Start-Sleep -Milliseconds 1200
}
Write-Output ("finished: {0} items processed" -f $total)
