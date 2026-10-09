# Registers the aghanim dispatcher (serves every registered project): at logon, then every 3 minutes,
# only while the user is logged on. Runs hidden (mintty -w hide) so no console window appears.
# Run `aghanim install` first: the task starts the installed copy in ~/.aghanim/factory.
$ErrorActionPreference = 'Stop'
$mintty = 'C:\Program Files\Git\usr\bin\mintty.exe'
if (-not (Test-Path $mintty)) { throw "Git for Windows mintty not found at $mintty" }
$entry = Join-Path $env:USERPROFILE '.aghanim\factory\run-dispatcher.sh'
if (-not (Test-Path $entry)) { throw "run 'aghanim install' first ($entry not found)" }
$action = New-ScheduledTaskAction -Execute $mintty -Argument '-w hide /usr/bin/bash -l ~/.aghanim/factory/run-dispatcher.sh'
# Two triggers: repetition on an AtLogOn trigger only starts at the next logon,
# so a second one starts the 3-minute cycle right away.
$every = New-TimeSpan -Minutes 3
$forever = New-TimeSpan -Days 3650
$atLogon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$atLogon.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval $every -RepetitionDuration $forever).Repetition
$fromNow = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval $every -RepetitionDuration $forever
$trigger = @($atLogon, $fromNow)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
# The task was called MylosDispatcher before the rename (legacy mylos); it would run a script that no longer exists.
if (Get-ScheduledTask -TaskName 'MylosDispatcher' -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName 'MylosDispatcher' -Confirm:$false }  # legacy mylos
Register-ScheduledTask -TaskName 'AghanimDispatcher' -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Write-Output 'AghanimDispatcher registered: at logon, every 3 minutes, hidden. Pause with: aghanim pause [project].'
