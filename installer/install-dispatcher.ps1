# Registers the mylos dispatcher (serves every registered project): at logon, then every 3 minutes,
# only while the user is logged on. Runs hidden (mintty -w hide) so no console window appears.
# Run `mylos install` first: the task starts the installed copy in ~/.mylos/factory.
$ErrorActionPreference = 'Stop'
$mintty = 'C:\Program Files\Git\usr\bin\mintty.exe'
if (-not (Test-Path $mintty)) { throw "Git for Windows mintty not found at $mintty" }
$entry = Join-Path $env:USERPROFILE '.mylos\factory\run-dispatcher.sh'
if (-not (Test-Path $entry)) { throw "run 'mylos install' first ($entry not found)" }
$action = New-ScheduledTaskAction -Execute $mintty -Argument '-w hide /usr/bin/bash -l ~/.mylos/factory/run-dispatcher.sh'
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
Register-ScheduledTask -TaskName 'MylosDispatcher' -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Write-Output 'MylosDispatcher registered: at logon, every 3 minutes, hidden. Pause with: mylos pause [project].'
