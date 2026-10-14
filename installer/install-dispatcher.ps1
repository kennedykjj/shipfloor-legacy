# Registers the shipfloor dispatcher (serves every registered project): every 1, 3, 5 or 10 minutes (not 30 seconds, see below)
# (-EveryMin, else dispatcher.every_min of the machine config, else 3), only while the user is logged on.
# Runs hidden (mintty -w hide) so no console window appears.
# 0.5 (30 seconds) is refused here, exit 2: Task Scheduler repeats a trigger at most once a minute.
# Run `shipfloor install` first: the task starts the installed copy in ~/.shipfloor/factory.
# -DryRun prints the pace and registers nothing.
param([ValidateSet(0.5, 1, 3, 5, 10)][double]$EveryMin = 0, [switch]$DryRun)
$ErrorActionPreference = 'Stop'
$noHalf = 'Windows Task Scheduler cannot repeat a task more often than once a minute: 30 seconds is not supported on Windows; pick 1, 3, 5 or 10 minutes'
if ($EveryMin -eq 0.5) { [Console]::Error.WriteLine($noHalf); exit 2 }
if (-not $EveryMin) {
    $EveryMin = 3
    $cfg = Join-Path $env:USERPROFILE '.shipfloor\factory\shipfloor-config.sh'
    if (Test-Path $cfg) {
        try {
            $got = & 'C:\Program Files\Git\usr\bin\bash.exe' -l $cfg machine values dispatcher.every_min 2>$null
            if ($LASTEXITCODE -eq 0 -and ("$got".Trim([char]0, ' ', "`r", "`n") -in '1', '3', '5', '10')) { $EveryMin = [int]"$got".Trim([char]0, ' ', "`r", "`n") }
            elseif ($LASTEXITCODE -eq 0 -and "$got".Trim([char]0, ' ', "`r", "`n") -eq '0.5') { [Console]::Error.WriteLine($noHalf); exit 2 }
        } catch { }  # no readable config: the default pace
    }
}
$cfgLimits = Join-Path $env:USERPROFILE '.shipfloor\factory\shipfloor-config.sh'
if (Test-Path $cfgLimits) {
    try {
        $lim = & 'C:\Program Files\Git\usr\bin\bash.exe' -l $cfgLimits machine limits 2>$null
        if ($LASTEXITCODE -eq 0 -and "$lim".Trim([char]0, ' ', "`r", "`n")) {
            Write-Warning 'CPU and memory limits are not supported on Windows (only systemd): the task is registered without them.'
        }
    } catch { }
}
if ($DryRun) { Write-Output "ShipfloorDispatcher: every $EveryMin minutes"; return }
$mintty = 'C:\Program Files\Git\usr\bin\mintty.exe'
if (-not (Test-Path $mintty)) { throw "Git for Windows mintty not found at $mintty" }
$entry = Join-Path $env:USERPROFILE '.shipfloor\factory\run-dispatcher.sh'
if (-not (Test-Path $entry)) { throw "run 'shipfloor install' first ($entry not found)" }
$action = New-ScheduledTaskAction -Execute $mintty -Argument '-w hide /usr/bin/bash -l ~/.shipfloor/factory/run-dispatcher.sh'
# One trigger: its repetition goes on across logons and restarts. A second one at logon, repeating too,
# started two cycles every 3 minutes: mintty hands off to a hidden process, so IgnoreNew never sees the first.
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $EveryMin) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName 'ShipfloorDispatcher' -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Write-Output "ShipfloorDispatcher registered: every $EveryMin minutes, hidden. Pause with: shipfloor pause [project]."
