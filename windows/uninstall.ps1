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

Step 'Icons'
# Seelen UI stays stopped until its settings and layouts are all back (it writes them when it closes)
$seelenOn = Invoke-SeelenStopped {
    Set-SeelenIconPack $false
    Restore-SeelenLook
    # its two layout files, as they were (they are in the list Restore-Files puts back below too)
    foreach ($e in (Read-Json (Join-Path $Original 'files.json'))) {
        if ($e.Path -notlike "$SeelenRoot\*") { continue }
        if ($e.Backup -and (Test-Path -LiteralPath $e.Backup)) { Copy-Item -LiteralPath $e.Backup -Destination $e.Path -Force }
        elseif (Test-Path -LiteralPath $e.Path) { Remove-Item -LiteralPath $e.Path -Force }
    }
}
Ok 'dock icon pack switched off; top bar and dock settings as they were'
if (Test-Path (Join-Path $State 'machine-icons.txt')) {
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $PSScriptRoot 'lib\machine-icons.ps1') + '"'), '-Remove')
    try {
        $p = Start-Process -FilePath (Get-Command powershell.exe).Source -ArgumentList $psArgs -Verb RunAs -WindowStyle Hidden -Wait -PassThru
        if ($p.ExitCode -eq 0) { Ok 'folder, drive and shared shortcut icons back as they were' }
        else { Warn "folder and drive icons: exit code $($p.ExitCode), see $(Join-Path $env:ProgramData 'macstyle\machine-icons.log')" }
    } catch {
        Warn 'folder and drive icons stay: administrator was not approved (run the uninstall again to retry)'
    }
}

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
# Folders that became read-only for their icon (Windows reads desktop.ini only then)
$ro = Join-Path $Original 'readonly-folders.txt'
if (Test-Path $ro) {
    foreach ($f in @(Get-Content $ro | Select-Object -Unique)) {
        try {
            $d = Get-Item -LiteralPath $f -Force -ErrorAction Stop
            if (-not (Test-Path -LiteralPath (Join-Path $f 'desktop.ini'))) { $d.Attributes = $d.Attributes -band -bnot [IO.FileAttributes]::ReadOnly }
        } catch { }
    }
}
if ($seelenOn) { Start-Seelen }   # the dock and top bar as they were before
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
# The old lock screen picture first: setting a picture switches Windows Spotlight off, and the
# registry, restored next, switches it back on if it was on
$lock = Get-SavedLockScreen
if ($lock) {
    try { Set-LockScreenImage $lock; Ok 'lock screen picture as before' } catch { Warn "lock screen picture: $($_.Exception.Message)" }
}
Restore-Registry
$pt = @(Get-Process -Name 'PowerToys' -ErrorAction SilentlyContinue)
if ($pt) { $exe = $pt[0].Path; $pt | Stop-Process -Force; Start-Sleep -Seconds 2; if ($exe) { Start-Process -FilePath $exe } }   # rereads its restored settings
Update-Icons
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
