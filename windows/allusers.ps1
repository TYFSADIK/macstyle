<#
.SYNOPSIS
    macstyle for every account on this computer, now and for people who sign in later.

.DESCRIPTION
    Run it once as administrator, from the macstyle folder:

        powershell -ExecutionPolicy Bypass -File .\windows\allusers.ps1

    It copies macstyle to C:\Program Files\macstyle, sets the icons Windows keeps for the whole
    computer (every folder, the C: drive, shared shortcuts) and registers the scheduled task
    \macstyle\macstyle. That task starts at every sign-in, as the person signing in, and runs the
    normal install for them in the background, once for each macstyle version. A person who runs
    uninstall.ps1 themselves is not set up again.

        allusers.ps1 -Remove          each person is put back as they were at their next sign-in
        allusers.ps1 -Remove -Purge   also deletes the task and C:\Program Files\macstyle (run it
                                      after everyone has signed in once, or they keep the look)
#>
[CmdletBinding()]
param([switch]$Remove, [switch]$Purge)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
. (Join-Path $PSScriptRoot 'lib\common.ps1')

$App = Join-Path $env:ProgramFiles 'macstyle'
$TaskPath = '\macstyle\'
$TaskName = 'macstyle'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Run it as administrator: right-click PowerShell, "Run as administrator".' -ForegroundColor Red
    exit 1
}

if ($Remove) {
    Step 'Putting every account back'
    if (Test-Path $App) {
        Set-Content -Path (Join-Path $App 'remove.txt') -Value (Get-Date -Format o)
        Ok 'each person gets their own settings back at their next sign-in'
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'lib\machine-icons.ps1') -Remove
    if ($LASTEXITCODE -eq 0) { Ok 'folder, drive and shared shortcut icons back as they were' } else { Warn "machine icons: exit code $LASTEXITCODE" }
    if ($Purge) {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false -ErrorAction SilentlyContinue
        if (Test-Path $App) { Remove-Item -Path $App -Recurse -Force }
        Ok 'sign-in task and C:\Program Files\macstyle removed'
    }
    exit 0
}

Step 'Copying macstyle to C:\Program Files\macstyle'
$repo = Split-Path -Parent $PSScriptRoot
if ((Resolve-Path $repo).Path -ne $App) {
    if (Test-Path $App) { Remove-Item -Path $App -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $App | Out-Null
    foreach ($part in @('windows', 'wallpapers', 'terminal', 'LICENSE', 'CREDITS.md')) {
        $src = Join-Path $repo $part
        if (Test-Path $src) { Copy-Item -Path $src -Destination $App -Recurse -Force }
    }
}
# A new version makes everyone's sign-in task run the install again
$version = (Get-ChildItem -Path $App -Recurse -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc.ToString('o')
Set-Content -Path (Join-Path $App 'version.txt') -Value $version
Remove-Item -Path (Join-Path $App 'remove.txt') -ErrorAction SilentlyContinue
Ok $App

Step 'Icons for every folder, the C: drive and shared shortcuts'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $App 'windows\lib\machine-icons.ps1') -Source (Join-Path $App 'windows\icons\ico')
if ($LASTEXITCODE -eq 0) { Ok 'done' } else { Warn "exit code $LASTEXITCODE, see $(Join-Path $env:ProgramData 'macstyle\machine-icons.log')" }

Step 'Sign-in task for every account'
$ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action = New-ScheduledTaskAction -Execute $ps -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $App 'windows\lib\allusers-logon.ps1') + '"')
$trigger = New-ScheduledTaskTrigger -AtLogOn
$trigger.Delay = 'PT20S'
$principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited   # BUILTIN\Users: whoever signs in
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Description 'macstyle: sets up the macOS look for each person at sign-in' -Force | Out-Null
Ok "task $TaskPath${TaskName}: runs at every sign-in, as that person"

Step 'Done'
Write-Host @"
    Everyone who signs in from now on gets macstyle, set up in the background in a minute or two
    (the first time it also installs the apps for them). They see it fully after signing in again.

    Undo for everyone:  .\windows\allusers.ps1 -Remove   (then later -Remove -Purge)
    Each person's log:  %LOCALAPPDATA%\macstyle-allusers.log
"@
