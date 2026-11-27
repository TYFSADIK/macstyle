<#
.SYNOPSIS
    macstyle: the macOS icons Windows keeps for the whole computer.

.DESCRIPTION
    Every folder (open and closed), the C: drive, and the Start menu and desktop shortcuts shared by
    all users. Windows allows these only machine-wide, so install.ps1 and uninstall.ps1 start this
    script as administrator (one approval). The icons are copied to %ProgramData%\macstyle\icons,
    where every account can read them; what it changes is saved first in %ProgramData%\macstyle\original.

        machine-icons.ps1 -Source <folder with the .ico files>    apply
        machine-icons.ps1 -Remove                                  put everything back
#>
[CmdletBinding()]
param([string]$Source, [switch]$Remove)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
. (Join-Path $PSScriptRoot 'common.ps1')

# The same save-and-restore helpers as the per-user install, kept in ProgramData instead
$State = Join-Path $env:ProgramData 'macstyle'
$Original = Join-Path $State 'original'
$Icons = Join-Path $State 'icons'
New-Item -ItemType Directory -Force -Path $State | Out-Null
Start-Transcript -Path (Join-Path $State 'machine-icons.log') -Append | Out-Null

$Explorer = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'
$Values = @(
    @("$Explorer\Shell Icons", '3', 'folder'),
    @("$Explorer\Shell Icons", '4', 'folder-open'),
    @("$Explorer\DriveIcons\C\DefaultIcon", '', 'drive')
)
$SharedShortcuts = @(
    (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
    (Join-Path $env:PUBLIC 'Desktop')
)

try {
    if ($Remove) {
        Restore-Registry   # first: the folder and drive icons matter most
        Restore-Files
        $list = Join-Path $State 'installed.txt'
        if (Test-Path $list) {
            $paths = @(Get-Content $list)
            [array]::Reverse($paths)
            foreach ($p in $paths) { if ($p -and (Test-Path $p)) { Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue } }
        }
        Update-Icons
        Stop-Transcript | Out-Null
        Remove-Item -Path $State -Recurse -Force
        exit 0
    }

    if (-not $Source -or -not (Test-Path (Join-Path $Source 'folder.ico'))) { Fail "no icons in '$Source'" }
    if (-not (Test-Path (Join-Path $Original 'date.txt'))) {
        New-Item -ItemType Directory -Force -Path $Original | Out-Null
        Get-Date -Format o | Set-Content (Join-Path $Original 'date.txt')
    }
    New-Item -ItemType Directory -Force -Path $Icons | Out-Null
    Copy-Item (Join-Path $Source '*.ico') $Icons -Force
    foreach ($v in $Values) { Set-RegValue $v[0] $v[1] ((Join-Path $Icons "$($v[2]).ico") + ',0') 'String' }
    $n = Set-ShortcutIcons $SharedShortcuts $Icons
    Update-Icons
    Write-Host "folders, C: drive and $n shared shortcuts"
} catch {
    Write-Host "Error: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    Stop-Transcript | Out-Null
    exit 1
}
Stop-Transcript | Out-Null
exit 0
