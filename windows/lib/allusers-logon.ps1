<#
.SYNOPSIS
    macstyle: run by the \macstyle\macstyle task at every sign-in, as the person signing in.

.DESCRIPTION
    Sets macstyle up for this person once for each version in C:\Program Files\macstyle (or puts
    them back when allusers.ps1 -Remove was run). Does nothing for a person who ran uninstall.ps1.
#>
$ErrorActionPreference = 'Stop'
$App = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Marker = Join-Path $env:LOCALAPPDATA 'macstyle-allusers.txt'   # outside %LOCALAPPDATA%\macstyle: uninstall moves that folder
$Log = Join-Path $env:LOCALAPPDATA 'macstyle-allusers.log'
$ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Say([string]$t) { Add-Content -Path $Log -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $t) }

try {
    $version = (Get-Content -Path (Join-Path $App 'version.txt') -ErrorAction Stop | Select-Object -First 1)
    $had = if (Test-Path $Marker) { (Get-Content -Path $Marker | Select-Object -First 1) } else { $null }

    if (Test-Path (Join-Path $App 'remove.txt')) {
        if (-not $had) { exit 0 }
        Say 'putting this account back (allusers.ps1 -Remove)'
        & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $App 'windows\uninstall.ps1') -Yes *>> $Log
        Say "uninstall finished with exit code $LASTEXITCODE"
        Remove-Item -Path $Marker -Force
        exit 0
    }

    if ($had -eq $version) { exit 0 }
    # Set up before, then removed by this person: leave them alone until there is a new version
    $state = Join-Path $env:LOCALAPPDATA 'macstyle'
    if ($had -and -not (Test-Path (Join-Path $state 'original'))) {
        Set-Content -Path $Marker -Value $version
        Say 'this account ran uninstall.ps1: not set up again'
        exit 0
    }

    # On a brand-new account winget can need a few minutes to register
    for ($i = 0; $i -lt 30 -and -not (Get-Command winget -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 10 }

    Say "setting up macstyle $version"
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $App 'windows\install.ps1') -Yes -NoAdmin *>> $Log
    $code = $LASTEXITCODE
    Say "install finished with exit code $code"
    if ($code -eq 0 -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        Set-Content -Path $Marker -Value $version   # without winget the apps were skipped: try again next sign-in
    }
} catch {
    Say "error: $($_.Exception.Message)"
    exit 1
}
exit 0
