# Registers the shipfloor dispatcher (serves every registered project): every 1, 3, 5 or 10 minutes
# (-EveryMin, else dispatcher.every_min of the machine config, else 3), only while the user is logged on.
# Runs hidden (mintty -w hide) so no console window appears.
# Run `shipfloor install` first: the task starts the installed copy in ~/.shipfloor/factory.
# -DryRun prints the pace and registers nothing.
param([ValidateSet(1, 3, 5, 10)][int]$EveryMin = 0, [switch]$DryRun)
$ErrorActionPreference = 'Stop'
if (-not $EveryMin) {
    $EveryMin = 3
    $cfg = Join-Path $env:USERPROFILE '.shipfloor\factory\shipfloor-config.sh'
    if (Test-Path $cfg) {
        try {
            $got = & 'C:\Program Files\Git\usr\bin\bash.exe' -l $cfg machine values dispatcher.every_min 2>$null
            if ($LASTEXITCODE -eq 0 -and ("$got".Trim([char]0, ' ', "`r", "`n") -in '1', '3', '5', '10')) { $EveryMin = [int]"$got".Trim([char]0, ' ', "`r", "`n") }
        } catch { }  # no readable config: the default pace
    }
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
# The task was called AghanimDispatcher before the rename (legacy aghanim); it would run a script that no longer exists.
if (Get-ScheduledTask -TaskName 'AghanimDispatcher' -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName 'AghanimDispatcher' -Confirm:$false }  # legacy aghanim
Register-ScheduledTask -TaskName 'ShipfloorDispatcher' -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Write-Output "ShipfloorDispatcher registered: every $EveryMin minutes, hidden. Pause with: shipfloor pause [project]."
