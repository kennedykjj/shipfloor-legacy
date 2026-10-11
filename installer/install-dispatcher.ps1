# Registers the aghanim dispatcher (serves every registered project): every 3 minutes,
# only while the user is logged on. Runs hidden (mintty -w hide) so no console window appears.
# Run `aghanim install` first: the task starts the installed copy in ~/.aghanim/factory.
$ErrorActionPreference = 'Stop'
$mintty = 'C:\Program Files\Git\usr\bin\mintty.exe'
if (-not (Test-Path $mintty)) { throw "Git for Windows mintty not found at $mintty" }
$entry = Join-Path $env:USERPROFILE '.aghanim\factory\run-dispatcher.sh'
if (-not (Test-Path $entry)) { throw "run 'aghanim install' first ($entry not found)" }
$action = New-ScheduledTaskAction -Execute $mintty -Argument '-w hide /usr/bin/bash -l ~/.aghanim/factory/run-dispatcher.sh'
# One trigger: its repetition goes on across logons and restarts. A second one at logon, repeating too,
# started two cycles every 3 minutes: mintty hands off to a hidden process, so IgnoreNew never sees the first.
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 3) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
# The task was called MylosDispatcher before the rename (legacy mylos); it would run a script that no longer exists.
if (Get-ScheduledTask -TaskName 'MylosDispatcher' -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName 'MylosDispatcher' -Confirm:$false }  # legacy mylos
Register-ScheduledTask -TaskName 'AghanimDispatcher' -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Write-Output 'AghanimDispatcher registered: every 3 minutes, hidden. Pause with: aghanim pause [project].'
