<#
.SYNOPSIS
    macstyle for Windows: a macOS-like Windows 10 or 11, in one command.

.DESCRIPTION
    Run it as your normal user (not "Run as administrator"), from the macstyle folder:

        powershell -ExecutionPolicy Bypass -File .\windows\install.ps1

    It installs free, open-source tools with winget (a dock and a top bar, Quick Look, a Spotlight-
    like search, automatic dark mode), the macOS cursor, the Inter and JetBrains Mono fonts,
    day-and-night wallpapers that follow dark mode, and a terminal with the macstyle prompt. Before
    changing anything it saves what it changes; .\windows\uninstall.ps1 puts it all back.

.PARAMETER Yes
    Answer every question with its default (no prompts).
.PARAMETER NoApps
    Do not install the dock, top bar, Quick Look, search and dark-mode apps.
.PARAMETER NoTerminal
    Leave the terminal and PowerShell alone.
#>
[CmdletBinding()]
param([switch]$Yes, [switch]$NoApps, [switch]$NoTerminal)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
. (Join-Path $PSScriptRoot 'lib\common.ps1')

$FontNerdUrl = 'https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/JetBrainsMono.zip'
$FontInterUrl = 'https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip'
$CursorUrl = 'https://github.com/ful1e5/apple_cursor/releases/download/v2.0.1/macOS-Windows.zip'
$DefaultWallpaper = 'mountain'

# winget packages: id, what it is
$Apps = @(
    @('Seelen.SeelenUI', 'Seelen UI: a dock and a top bar'),
    @('QL-Win.QuickLook', 'QuickLook: press Space on a file to preview it'),
    @('Microsoft.PowerToys', 'PowerToys: Alt+Space searches apps and files, like Spotlight')
)
$StoreApps = @(
    @('XP8JK4HZBVF435', 'Auto Dark Mode: dark mode at sunset, and a tray switch')
)
$TerminalApps = @(
    @('Starship.Starship', 'Starship: the prompt'),
    @('Fastfetch-cli.Fastfetch', 'fastfetch: system summary in new windows'),
    @('ajeetdsouza.zoxide', 'zoxide: z NAME jumps to a folder'),
    @('junegunn.fzf', 'fzf: fuzzy search'),
    @('lsd-rs.lsd', 'lsd: ls with icons')
)

# ---------------------------------------------------------------------------------------- steps

function Test-Preflight {
    Step 'Checking this computer'
    if ($PSVersionTable.PSVersion.Major -lt 5) { Fail 'PowerShell 5.1 or newer is needed.' }
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 17763) { Fail "Windows 10 1809 or newer is needed (this is build $build)." }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ((New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -and -not $env:MACSTYLE_ALLOW_ADMIN) {
        Fail 'run it as your normal user, not "Run as administrator": the settings would go to the wrong account.'
    }
    $script:HaveWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
    $edition = if ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' }
    Ok "$edition (build $build), PowerShell $($PSVersionTable.PSVersion)"
    if (-not $HaveWinget) { Warn 'winget is missing (install "App Installer" from the Microsoft Store): apps and terminal tools are skipped' }
}

function Install-WingetApp([string]$Id, [string]$What, [string]$Source = 'winget') {
    $listed = winget list --id $Id -e --source $Source --accept-source-agreements 2>$null | Out-String
    if ($listed -match [regex]::Escape($Id)) { Ok "$What (already installed)"; return }
    Info "installing $What..."
    winget install --id $Id -e --source $Source --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Add-Content -Path (Join-Path $State 'winget.txt') -Value $Id
        Ok $What
    } else {
        Warn "$What did not install (winget exit code $LASTEXITCODE)"
    }
}

function Install-Apps {
    Step 'Apps: dock and top bar, Quick Look, search, dark mode'
    if ($NoApps) { Warn 'skipped (-NoApps)'; return }
    if (-not $HaveWinget) { Warn 'skipped: no winget'; return }
    foreach ($a in $Apps) { Install-WingetApp $a[0] $a[1] }
    foreach ($a in $StoreApps) { Install-WingetApp $a[0] $a[1] 'msstore' }
}

function Install-Fonts {
    Step 'Fonts: Inter (like SF Pro) and JetBrains Mono with icons'
    $dir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $tmp = New-TempDir
    try {
        $sets = @(
            @($FontInterUrl, @('InterVariable.ttf', 'InterVariable-Italic.ttf')),
            @($FontNerdUrl, @('JetBrainsMonoNerdFont-Regular.ttf', 'JetBrainsMonoNerdFont-Bold.ttf', 'JetBrainsMonoNerdFont-Italic.ttf', 'JetBrainsMonoNerdFont-BoldItalic.ttf'))
        )
        foreach ($set in $sets) {
            $zip = Join-Path $tmp ([IO.Path]::GetFileName($set[0]))
            Get-Download $set[0] $zip
            $out = Join-Path $tmp ([IO.Path]::GetFileNameWithoutExtension($zip))
            Expand-Archive -Path $zip -DestinationPath $out -Force
            foreach ($name in $set[1]) {
                $src = Get-ChildItem -Path $out -Recurse -Filter $name | Select-Object -First 1
                if (-not $src) { Warn "$name is not in $($set[0])"; continue }
                $dest = Join-Path $dir $name
                if (-not (Test-Path $dest)) {
                    Copy-Item $src.FullName $dest
                    Add-Installed $dest
                }
                $reg = ([IO.Path]::GetFileNameWithoutExtension($name) -replace '-', ' ') + ' (TrueType)'
                Set-RegValue 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts' $reg $dest 'String'
                [void][Native]::AddFontResource($dest)
            }
        }
    } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    [void][Native]::SendMessageTimeout([IntPtr]0xffff, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero, 2, 1000, [ref][IntPtr]::Zero)
    Ok 'Inter and JetBrainsMono Nerd Font (for you only, no administrator needed)'
}

function Install-Cursor {
    Step 'The macOS cursor'
    $dest = Join-Path $State 'cursors'
    if (-not (Test-Path (Join-Path $dest 'Pointer.cur'))) {
        $tmp = New-TempDir
        try {
            Get-Download $CursorUrl (Join-Path $tmp 'cursor.zip')
            Expand-Archive -Path (Join-Path $tmp 'cursor.zip') -DestinationPath $tmp -Force
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            Copy-Item (Join-Path $tmp 'macOS-Regular-Windows\*') $dest -Recurse -Force
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }
    $key = 'HKCU:\Control Panel\Cursors'
    $map = [ordered]@{
        'Arrow' = 'Pointer.cur'; 'Help' = 'Help.cur'; 'AppStarting' = 'Work.ani'; 'Wait' = 'Busy.ani';
        'Crosshair' = 'Cross.cur'; 'IBeam' = 'Text.cur'; 'NWPen' = 'Handwriting.cur'; 'No' = 'Unavailiable.cur';
        'SizeNS' = 'Vert.cur'; 'SizeWE' = 'Horz.cur'; 'SizeNWSE' = 'Dng1.cur'; 'SizeNESW' = 'Dng2.cur';
        'SizeAll' = 'Move.cur'; 'UpArrow' = 'Alternate.cur'; 'Hand' = 'Link.cur'; 'Pin' = 'Pin.cur'; 'Person' = 'Person.cur'
    }
    Set-RegValue $key '' 'macOS (macstyle)' 'String'
    foreach ($k in $map.Keys) { Set-RegValue $key $k (Join-Path $dest $map[$k]) 'ExpandString' }
    Set-RegValue $key 'Scheme Source' 1 'DWord'
    [void][Native]::SystemParametersInfo(0x0057, 0, $null, 3)   # SPI_SETCURSORS: load them now
    Ok 'macOS cursor (by ful1e5, apple_cursor)'
}

function Install-Wallpapers {
    Step 'Wallpapers that follow dark mode'
    $dest = Join-Path $State 'wallpapers'
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item (Join-Path $Repo 'wallpapers\*.jpg') $dest -Force
    Copy-Item (Join-Path $Repo 'wallpapers\CREDITS.txt') $dest -Force
    $cfg = Join-Path $State 'config.json'
    if (-not (Test-Path $cfg)) { @{ wallpaper = $DefaultWallpaper } | ConvertTo-Json | Set-Content -Path $cfg -Encoding UTF8 }
    Set-RegValue 'HKCU:\Control Panel\Desktop' 'WallpaperStyle' '10' 'String'   # fill
    Set-RegValue 'HKCU:\Control Panel\Desktop' 'TileWallpaper' '0' 'String'
    Save-RegValue 'HKCU:\Control Panel\Desktop' 'WallPaper'

    # The dark-mode watcher: picks the day or night picture now and whenever dark mode changes,
    # started at every sign-in from the Startup folder.
    $bin = Join-Path $State 'bin'
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'lib\macstyle-darkswitch.ps1') $bin -Force
    $script = Join-Path $bin 'macstyle-darkswitch.ps1'
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'macstyle dark mode.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $s = $shell.CreateShortcut($lnk)
    $s.TargetPath = (Get-Command powershell.exe).Source
    $s.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
    $s.WindowStyle = 7
    $s.Description = 'macstyle: wallpapers that follow dark mode'
    $s.Save()
    Add-Installed $lnk
    Stop-DarkSwitch
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Once
    Start-Process -WindowStyle Hidden -FilePath (Get-Command powershell.exe).Source -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"")
    Ok "six day-and-night pairs in $dest; `"$DefaultWallpaper`" set"
}

function Set-Desktop {
    Step 'Desktop settings'
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    if ([Environment]::OSVersion.Version.Build -ge 22000) {
        Set-RegValue $adv 'TaskbarAl' 1 'DWord'   # taskbar icons in the middle, like a dock
    }
    # Accent colour: the macOS blue (ABGR), on title bars and the Start menu off
    $dwm = 'HKCU:\Software\Microsoft\Windows\DWM'
    Set-RegValue $dwm 'AccentColor' 0xFFFF840A 'DWord'
    Set-RegValue $dwm 'ColorizationColor' 0xC40A84FF 'DWord'
    Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' 'AccentColorMenu' 0xFFFF840A 'DWord'
    Ok 'taskbar centred, accent colour blue'
}

function Install-Terminal {
    Step 'Terminal: the macstyle prompt, colours, font and a see-through window'
    if ($NoTerminal) { Warn 'skipped (-NoTerminal)'; return }
    if ($HaveWinget) {
        foreach ($a in $TerminalApps) { Install-WingetApp $a[0] $a[1] }
        if (-not (Get-Command wt.exe -ErrorAction SilentlyContinue)) { Install-WingetApp 'Microsoft.WindowsTerminal' 'Windows Terminal' }
    }
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine')

    # Configs: the prompt, fastfetch and lsd
    $cfg = Join-Path $HOME '.config'
    Put-File (Join-Path $PSScriptRoot 'terminal\starship.toml') (Join-Path $cfg 'macstyle\starship.toml')
    Put-File (Join-Path $Repo 'terminal\fastfetch.jsonc') (Join-Path $cfg 'fastfetch\config.jsonc')
    Put-File (Join-Path $Repo 'terminal\lsd\config.yaml') (Join-Path $env:APPDATA 'lsd\config.yaml')
    Put-File (Join-Path $Repo 'terminal\lsd\colors.yaml') (Join-Path $env:APPDATA 'lsd\colors.yaml')

    # PowerShell runs profile scripts only with this policy (for you only)
    $policy = Get-ExecutionPolicy -Scope CurrentUser
    if ($policy -notin @('RemoteSigned', 'Unrestricted', 'Bypass')) {
        Save-Value 'executionpolicy' ([string]$policy)
        Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
        Ok 'PowerShell may run your profile (RemoteSigned, for you only)'
    }

    # Grey suggestions as you type need PSReadLine 2.1 or newer (Windows PowerShell 5.1 has 2.0)
    if (-not (Get-Module -ListAvailable PSReadLine | Where-Object { $_.Version -ge [version]'2.1' })) {
        try {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
            Install-Module PSReadLine -Scope CurrentUser -Force -SkipPublisherCheck -AllowClobber
            Ok 'PSReadLine updated (suggestions from your history as you type)'
        } catch { Warn "PSReadLine was not updated: $($_.Exception.Message)" }
    }

    # The profile block, in Windows PowerShell's and PowerShell 7's profiles
    $block = Get-Content -Raw (Join-Path $PSScriptRoot 'terminal\profile.ps1')
    $docs = [Environment]::GetFolderPath('MyDocuments')
    foreach ($p in @((Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'), (Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1'))) {
        Add-ProfileBlock $p $block
    }
    Ok 'PowerShell: the prompt, suggestions, z jumps, ls with icons, fastfetch in new windows'

    # Windows Terminal: the macstyle colours (light and dark), the font, see-through, as default
    $wtDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\macstyle'
    New-Item -ItemType Directory -Force -Path $wtDir | Out-Null
    $frag = Join-Path $wtDir 'macstyle.json'
    New-TerminalFragment (Join-Path $Repo 'terminal\macstyle.palette') | Set-Content -Path $frag -Encoding UTF8
    Add-Installed $wtDir
    $settings = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Packages') -Filter 'settings.json' -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like '*Microsoft.WindowsTerminal*\LocalState\settings.json' } | Select-Object -First 1
    if ($settings) {
        Save-File $settings.FullName
        $text = Get-Content -Raw $settings.FullName
        if ($text -match '"defaultProfile"\s*:\s*"[^"]*"') {
            $text = $text -replace '"defaultProfile"\s*:\s*"[^"]*"', ('"defaultProfile": "' + $TerminalProfileGuid + '"')
        } else {
            $text = $text -replace '^\s*\{', ('{' + "`n" + '    "defaultProfile": "' + $TerminalProfileGuid + '",')
        }
        Set-Content -Path $settings.FullName -Value $text -Encoding UTF8
        Ok 'Windows Terminal: the macstyle profile opens by default'
    } else {
        Ok 'Windows Terminal: the macstyle profile is ready (choose it as default in its settings after the first start)'
    }
}

function Write-Finish {
    Step 'Done'
    Write-Host @"
    Sign out and back in once, so every app picks up the fonts and the cursor.

    After that:
      - The dock and top bar run from Seelen UI (its settings: right-click the top bar).
      - Press Space on a file in File Explorer to preview it; Alt+Space to search.
      - Dark mode (Settings > Personalization > Colors, or Auto Dark Mode's tray icon)
        switches the wallpaper too.
      - Open Windows Terminal for the macstyle prompt.

    Undo everything:  .\windows\uninstall.ps1
    Log of this run:  $Log
"@
}

# ---------------------------------------------------------------------------------------- main

New-Item -ItemType Directory -Force -Path $State | Out-Null
$Log = Join-Path $State ("install-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $Log -Append | Out-Null
try {
    Write-Host 'macstyle: a macOS-like Windows' -ForegroundColor Cyan
    Test-Preflight
    if (-not (Test-Path (Join-Path $Original 'date.txt'))) {
        New-Item -ItemType Directory -Force -Path $Original | Out-Null
        Get-Date -Format o | Set-Content (Join-Path $Original 'date.txt')
    }
    Install-Apps
    Install-Fonts
    Install-Cursor
    Install-Wallpapers
    Set-Desktop
    Install-Terminal
    Write-Finish
} catch {
    Write-Host ''
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Your desktop is half set up: run .\windows\install.ps1 again, or .\windows\uninstall.ps1 to go back.'
    Stop-Transcript | Out-Null
    exit 1
}
Stop-Transcript | Out-Null
