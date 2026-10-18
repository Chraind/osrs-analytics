# =====================================================================
#  Registers osrs_collector.R as a daily Windows scheduled task.
#
#  Put this file in the SAME folder as osrs_collector.R, then:
#    right-click -> "Run with PowerShell"
#  (or in PowerShell:  powershell -ExecutionPolicy Bypass -File .\install_collector_task.ps1)
#
#  Run it again any time to update the task. To remove it:
#    Unregister-ScheduledTask -TaskName "OSRS collector" -Confirm:$false
# =====================================================================

$TaskName = "OSRS collector"
$RunAt    = "10:00"          # local time; change if you like

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path $here "osrs_collector.R"
if (-not (Test-Path $script)) { throw "osrs_collector.R not found next to this file: $here" }

# Newest installed R
$rscript = Get-ChildItem "C:\Program Files\R\*\bin\Rscript.exe" -ErrorAction SilentlyContinue |
           Sort-Object FullName -Descending | Select-Object -First 1
if (-not $rscript) { throw "Rscript.exe not found under C:\Program Files\R. Is R installed?" }

$action   = New-ScheduledTaskAction -Execute $rscript.FullName `
              -Argument "`"$script`"" -WorkingDirectory $here
$trigger  = New-ScheduledTaskTrigger -Daily -At $RunAt
# StartWhenAvailable: if the PC was off at 10:00, run as soon as it is on.
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
              -RunOnlyIfNetworkAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
  -Settings $settings -Description "Daily OSRS price + hiscores snapshot" -Force | Out-Null

Write-Host "Registered '$TaskName' daily at $RunAt using $($rscript.FullName)"
Write-Host "Running it once now so the backfill starts..."
Start-ScheduledTask -TaskName $TaskName
Write-Host "Check data\collector.log in $here in a minute or two."
