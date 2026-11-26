<#
.SYNOPSIS
    macstyle: the day picture in light mode, the night picture in dark mode.

.DESCRIPTION
    Started at sign-in from the Startup folder (hidden). Checks every two seconds whether Windows
    apps are in light or dark mode and sets the matching picture of the chosen pair, only when it
    changes. -Once sets it and stops. The pair is in %LOCALAPPDATA%\macstyle\config.json.
#>
param([switch]$Once)

$state = Join-Path $env:LOCALAPPDATA 'macstyle'
if (-not ('MacstyleWallpaper' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class MacstyleWallpaper {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool SystemParametersInfo(uint action, uint param, string vparam, uint winIni);
}
'@
}

function Get-Mode {
    $v = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction SilentlyContinue
    if ($v -and $v.AppsUseLightTheme -eq 0) { return 'd' }
    return 'l'
}

$last = ''
while ($true) {
    $name = 'mountain'
    $cfg = Join-Path $state 'config.json'
    if (Test-Path $cfg) {
        try { $c = Get-Content -Raw $cfg | ConvertFrom-Json; if ($c.wallpaper) { $name = $c.wallpaper } } catch { }
    }
    $pic = Join-Path $state ("wallpapers\{0}-{1}.jpg" -f $name, (Get-Mode))
    if ($pic -ne $last -and (Test-Path $pic)) {
        # SPI_SETDESKWALLPAPER, saved and announced to the desktop
        [void][MacstyleWallpaper]::SystemParametersInfo(0x0014, 0, $pic, 3)
        $last = $pic
    }
    if ($Once) { break }
    Start-Sleep -Seconds 2
}
