<#
.SYNOPSIS
    macstyle for Windows: put everything back as it was before the first install.

.DESCRIPTION
        powershell -ExecutionPolicy Bypass -File .\windows\uninstall.ps1 [-Yes] [-KeepApps]

    Restores the registry values and files install.ps1 changed, removes what it added (fonts,
    cursor, wallpapers, the dark-mode watcher, the PowerShell profile lines, the Windows Terminal
    profile) and, unless -KeepApps, uninstalls the apps it installed with winget.
#>
[CmdletBinding()]
param([switch]$Yes, [switch]$KeepApps)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
. (Join-Path $PSScriptRoot 'lib\common.ps1')

if (-not (Test-Path $Original)) { Write-Host 'Nothing to undo: install.ps1 has not run for this user.'; exit 0 }
$when = Get-Content (Join-Path $Original 'date.txt') -ErrorAction SilentlyContinue
if (-not $Yes) {
    $a = Read-Host "Put Windows back as it was on $when? [y/N]"
    if ($a -notmatch '^[yY]') { Write-Host 'Nothing changed.'; exit 0 }
}

Step 'Stopping the dark-mode watcher'
Stop-DarkSwitch
Ok 'stopped'

Step 'PowerShell profiles'
$docs = [Environment]::GetFolderPath('MyDocuments')
foreach ($p in @((Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'), (Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1'))) {
    if (Test-Path $p) {
        $text = Get-Content -Raw $p
        if ($text -and $text.Contains($Marker)) { Set-Content -Path $p -Value (Remove-Block $text) -Encoding UTF8 -NoNewline }
    }
}
Ok 'the macstyle lines are out (your own lines stay)'
$policy = Get-SavedValue 'executionpolicy'
if ($policy) {
    try { Set-ExecutionPolicy $policy -Scope CurrentUser -Force } catch [System.Security.SecurityException] { }
    Ok "execution policy back to $policy"
}

Step 'Files and settings'
Restore-Files
$fontDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
$list = Join-Path $State 'installed.txt'
$removed = 0
if (Test-Path $list) {
    $paths = @(Get-Content $list)
    [array]::Reverse($paths)
    foreach ($p in $paths) {
        if (-not $p -or -not (Test-Path $p)) { continue }
        if ($p.StartsWith($fontDir)) { [void][Native]::RemoveFontResource($p) }
        Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue
        $removed++
    }
}
Restore-Registry
[void][Native]::SystemParametersInfo(0x0057, 0, $null, 3)   # the cursors as they were
$wall = (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -Name WallPaper -ErrorAction SilentlyContinue).WallPaper
if ($wall) { [void][Native]::SystemParametersInfo(0x0014, 0, $wall, 3) }
Ok "$removed added files and folders removed; registry values and files as they were"

if (-not $KeepApps -and (Test-Path (Join-Path $State 'winget.txt')) -and (Get-Command winget -ErrorAction SilentlyContinue)) {
    Step 'Apps macstyle installed'
    foreach ($id in (Get-Content (Join-Path $State 'winget.txt') | Select-Object -Unique)) {
        if (-not $Yes) {
            $a = Read-Host "Uninstall $id? [Y/n]"
            if ($a -match '^[nN]') { continue }
        }
        winget uninstall --id $id -e --silent --disable-interactivity | Out-Null
        if ($LASTEXITCODE -eq 0) { Ok "$id uninstalled" } else { Warn "${id}: winget exit code $LASTEXITCODE" }
    }
}

$keep = Join-Path (Split-Path $State) ("macstyle-uninstalled-{0:yyyyMMdd-HHmmss}" -f (Get-Date))
Move-Item -Path $State -Destination $keep
Step 'Done'
Write-Host @"
    Sign out and back in once to finish.
    The saved copy of your old settings stays in $keep (delete it when you are happy).
"@
