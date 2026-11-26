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
.PARAMETER NoIcons
    Leave all icons alone.
.PARAMETER NoAdmin
    Skip the one step that needs administrator: the icons of every folder, the C: drive and the
    shortcuts shared by all users.
#>
[CmdletBinding()]
param([switch]$Yes, [switch]$NoApps, [switch]$NoTerminal, [switch]$NoIcons, [switch]$NoAdmin)

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
# (the leading comma keeps a one-item list a list: PowerShell would flatten it into its two strings)
$StoreApps = @(
    ,@('XP8JK4HZBVF435', 'Auto Dark Mode: dark mode at sunset, and a tray switch')
)
# How each app starts at sign-in: Start menu name, text that identifies its own startup entry,
# 'shortcut' (macstyle puts one in the Startup folder) or 'self' (the app registers itself the
# first time it runs; a shortcut is added only if it does not), its process, arguments
$Autostart = @(
    @('Seelen UI', 'Seelen', 'shortcut', 'seelen-ui', ''),
    @('QuickLook', 'QuickLook', 'shortcut', 'QuickLook', '/autorun'),
    @('PowerToys', 'PowerToys', 'self', 'PowerToys', ''),
    @('Auto Dark Mode', 'AutoDarkMode', 'self', 'AutoDarkModeSvc', '')
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

function Test-SelfAutostart([string]$Match) {
    $run = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
    if ($run) {
        foreach ($p in $run.PSObject.Properties) {
            if ($p.Name -notlike 'PS*' -and "$($p.Name) $($p.Value)" -like "*$Match*") { return $true }
        }
    }
    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        $exe = @($t.Actions | ForEach-Object { $x = $_.PSObject.Properties['Execute']; if ($x) { $x.Value } }) -join ' '
        if ("$($t.TaskPath)$($t.TaskName) $exe" -like "*$Match*") { return $true }
    }
    return $false
}

function Start-AppsAtSignIn {
    Step 'Apps: running now and at every sign-in'
    if ($NoApps) { Warn 'skipped (-NoApps)'; return }
    try { $startApps = @(Get-StartApps) } catch { Warn "the Start menu list is not available, so the apps were not set to start: $($_.Exception.Message)"; return }
    $startup = [Environment]::GetFolderPath('Startup')
    $explorer = Join-Path $env:WINDIR 'explorer.exe'
    foreach ($a in $Autostart) {
        $name = $a[0]; $match = $a[1]; $how = $a[2]; $proc = $a[3]; $arg = $a[4]
        $app = $startApps | Where-Object { $_.Name -like "$name*" } | Select-Object -First 1
        if (-not $app) { Warn "$name is not installed: skipped"; continue }

        # A desktop app is started by its file, a Store app through the Apps folder
        if (Test-Path -LiteralPath $app.AppID -PathType Leaf) {
            $target = $app.AppID
            if ($proc -eq 'AutoDarkModeSvc') {
                $svc = Join-Path (Split-Path (Split-Path $target)) 'core\AutoDarkModeSvc.exe'
                if (Test-Path $svc) { $target = $svc }
            }
        } else {
            $target = $explorer; $arg = "shell:AppsFolder\$($app.AppID)"
        }

        if (-not (Get-Process -Name $proc -ErrorAction SilentlyContinue)) {
            if ($arg) { Start-Process -FilePath $target -ArgumentList $arg } else { Start-Process -FilePath $target }
        }

        $self = Test-SelfAutostart $match
        if ($how -eq 'self' -and -not $self) {
            for ($i = 0; $i -lt 15 -and -not $self; $i++) { Start-Sleep -Seconds 1; $self = Test-SelfAutostart $match }
        }
        if ($self) { Ok "$name (starts at sign-in by itself)"; continue }

        $lnk = Join-Path $startup "$name (macstyle).lnk"
        $shell = New-Object -ComObject WScript.Shell
        $s = $shell.CreateShortcut($lnk)
        $s.TargetPath = $target
        $s.Arguments = $arg
        $s.WindowStyle = 7
        $s.Description = "macstyle: starts $name at sign-in"
        $s.Save()
        Add-Installed $lnk
        Ok "$name (starts at sign-in)"
    }
}

function Set-FolderIcon([string]$Folder, [string]$Icon) {
    # A folder's own icon lives in its hidden desktop.ini ([.ShellClassInfo] IconResource=...)
    $ini = Join-Path $Folder 'desktop.ini'
    Save-File $ini
    $lines = @()
    if (Test-Path -LiteralPath $ini) {
        $lines = @(Get-Content -LiteralPath $ini)
        (Get-Item -LiteralPath $ini -Force).Attributes = 'Normal'
    }
    $out = New-Object System.Collections.Generic.List[string]
    $inSection = $false; $done = $false
    foreach ($l in $lines) {
        if ($l -match '^\s*\[') {
            if ($inSection -and -not $done) { $out.Add("IconResource=$Icon,0"); $done = $true }
            $inSection = $l -match '^\s*\[\.ShellClassInfo\]'
        } elseif ($inSection -and $l -match '^\s*(IconResource|IconFile|IconIndex)\s*=') { continue }
        $out.Add($l)
    }
    if (-not $done) {
        if (-not $inSection) { $out.Add('[.ShellClassInfo]') }
        $out.Add("IconResource=$Icon,0")
    }
    [IO.File]::WriteAllLines($ini, $out, [Text.Encoding]::Unicode)
    (Get-Item -LiteralPath $ini -Force).Attributes = 'Hidden, System'
    # Explorer reads desktop.ini only in read-only or system folders
    $d = Get-Item -LiteralPath $Folder -Force
    if (-not ($d.Attributes -band ([IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::System))) {
        $d.Attributes = $d.Attributes -bor [IO.FileAttributes]::ReadOnly
    }
}

function Install-SeelenIcons([string]$SvgDir) {
    # An icon pack for the Seelen UI dock, switched on in its settings
    $root = Join-Path $env:APPDATA 'com.seelen.seelen-ui'
    $seelen = $null
    try { $seelen = Get-StartApps | Where-Object { $_.Name -eq 'Seelen UI' } | Select-Object -First 1 } catch { }
    if (-not $seelen -and -not (Test-Path $root)) { Warn 'Seelen UI is not installed: dock icons skipped'; return }

    $pack = Join-Path $root 'iconpacks\macstyle'
    New-Item -ItemType Directory -Force -Path (Join-Path $pack 'icons') | Out-Null
    Copy-Item (Join-Path $SvgDir '*.svg') (Join-Path $pack 'icons') -Force
    Add-Installed $pack

    $entries = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $add = {
        param([string]$Kind, [string]$Value, [string]$Icon)
        if (-not $Value -or $seen.ContainsKey("$Kind|$Value")) { return }
        $seen["$Kind|$Value"] = $true
        $e = [ordered]@{ type = 'unique' }
        $e[$Kind] = $Value
        $e['icon'] = [ordered]@{ base = "icons/$Icon.svg" }
        $entries.Add($e)
    }
    try {
        foreach ($app in @(Get-StartApps)) {
            $icon = Get-IconFor $app.Name
            if (-not $icon) { continue }
            if (Test-Path -LiteralPath $app.AppID -PathType Leaf) { & $add 'path' $app.AppID $icon } else { & $add 'umid' $app.AppID $icon }
        }
    } catch { }
    $shell = New-Object -ComObject WScript.Shell
    $menus = @((Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'), (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'))
    foreach ($lnk in @(Get-ChildItem -LiteralPath $menus -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue)) {
        $icon = Get-IconFor $lnk.BaseName
        if (-not $icon) { continue }
        & $add 'path' $lnk.FullName $icon
        try { $t = $shell.CreateShortcut($lnk.FullName).TargetPath; if ($t -like '*.exe') { & $add 'path' $t $icon } } catch { }
    }
    & $add 'path' (Join-Path $env:WINDIR 'explorer.exe') 'finder'
    & $add 'umid' 'Microsoft.Windows.Explorer' 'finder'
    $entries.Add([ordered]@{ type = 'custom'; key = '@seelen/weg::folder'; icon = [ordered]@{ base = 'icons/folder.svg' } })

    $meta = [ordered]@{
        id       = '@macstyle/icons'
        metadata = [ordered]@{ displayName = 'macstyle'; description = 'macOS icons (MacTahoe) for the dock' }
        entries  = $entries.ToArray()
    }
    # JSON is valid YAML; written without a byte order mark
    $utf8 = New-Object Text.UTF8Encoding $false
    [IO.File]::WriteAllText((Join-Path $pack 'metadata.yml'), (ConvertTo-Json -InputObject $meta -Depth 6), $utf8)

    # Switch the pack on. Seelen UI writes its settings when it closes, so it is stopped first.
    $running = @(Get-Process -Name 'seelen-ui' -ErrorAction SilentlyContinue)
    if ($running) { $running | Stop-Process -Force; Start-Sleep -Seconds 2 }
    $settings = Join-Path $root 'settings.json'
    $keep = Join-Path $Original 'seelen-settings.json'
    if ((Test-Path $settings) -and -not (Test-Path $keep)) { Copy-Item $settings $keep }   # a copy, just in case
    Set-SeelenIconPack $true
    if ($seelen) { Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList "shell:AppsFolder\$($seelen.AppID)" }
    Ok "dock: $($entries.Count) apps and places with macOS icons (Seelen UI icon pack)"
}

function Install-Icons {
    Step 'macOS icons: desktop, your folders, shortcuts and the dock'
    if ($NoIcons) { Warn 'skipped (-NoIcons)'; return }
    $dir = Join-Path $State 'icons'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'icons\*') $dir -Recurse -Force
    $ico = Join-Path $dir 'ico'

    # Desktop icons, for you only (what Settings > Desktop icon settings > Change Icon does)
    $clsid = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CLSID'
    $desk = [ordered]@{
        '{20D04FE0-3AEA-1069-A2D8-08002B30309D}' = 'computer'        # This PC
        '{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}' = 'network'         # Network
        '{59031a47-3f72-44a7-89c5-5595fe6b30ee}' = 'folder-home'     # your user folder
        '{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}' = 'control-panel'   # Control Panel
    }
    foreach ($k in $desk.Keys) { Set-RegValue "$clsid\$k\DefaultIcon" '' ((Join-Path $ico "$($desk[$k]).ico") + ',0') 'String' }
    $bin = "$clsid\{645FF040-5081-101B-9F08-00AA002F954E}\DefaultIcon"
    Set-RegValue $bin '' ((Join-Path $ico 'trash-empty.ico') + ',0') 'String'
    Set-RegValue $bin 'empty' ((Join-Path $ico 'trash-empty.ico') + ',0') 'String'
    Set-RegValue $bin 'full' ((Join-Path $ico 'trash-full.ico') + ',0') 'String'
    Ok 'desktop: This PC, Recycle Bin, Network, your folder, Control Panel'

    # Your own folders
    $folders = [ordered]@{}
    $folders[[Environment]::GetFolderPath('Desktop')] = 'folder-desktop'
    $folders[[Environment]::GetFolderPath('MyDocuments')] = 'folder-documents'
    $folders[[Environment]::GetFolderPath('MyMusic')] = 'folder-music'
    $folders[[Environment]::GetFolderPath('MyPictures')] = 'folder-pictures'
    $folders[[Environment]::GetFolderPath('MyVideos')] = 'folder-videos'
    $dlName = '{374DE290-123F-4565-9164-B4BA2B7A4F2B}'
    $dl = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' -Name $dlName -ErrorAction SilentlyContinue
    if ($dl) { $folders[$dl.$dlName] = 'folder-downloads' } else { $folders[(Join-Path $HOME 'Downloads')] = 'folder-downloads' }
    foreach ($od in @($env:OneDrive, $env:OneDriveCommercial)) { if ($od) { $folders[$od] = 'folder-cloud' } }
    $done = @()
    foreach ($f in $folders.Keys) {
        if (-not $f -or -not (Test-Path -LiteralPath $f -PathType Container)) { continue }
        try { Set-FolderIcon $f (Join-Path $ico "$($folders[$f]).ico"); $done += (Split-Path $f -Leaf) }
        catch { Warn "${f}: $($_.Exception.Message)" }
    }
    Ok "your folders: $($done -join ', ')"

    # Shortcuts: your Start menu, desktop and taskbar pins
    $n = Set-ShortcutIcons @(
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        [Environment]::GetFolderPath('Desktop'),
        (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar')
    ) $ico
    Ok "$n app shortcuts in your Start menu, desktop and taskbar"

    if (-not $NoApps) { Install-SeelenIcons (Join-Path $dir 'svg') }
    Update-Icons
}

function Install-MachineIcons {
    Step 'macOS icons for every folder, the C: drive and shared shortcuts (administrator, once)'
    if ($NoIcons -or $NoAdmin) { Warn 'skipped'; return }
    if (-not $Yes) {
        $a = Read-Host '       Windows allows these only for the whole computer and will ask for administrator. Go ahead? [Y/n]'
        if ($a -match '^[nN]') { Warn 'skipped'; return }
    }
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $PSScriptRoot 'lib\machine-icons.ps1') + '"'),
        '-Source', ('"' + (Join-Path $State 'icons\ico') + '"'))
    # Recorded before it runs: if it stops halfway, uninstall.ps1 still undoes what it changed
    $marker = Join-Path $State 'machine-icons.txt'
    $hadMarker = Test-Path $marker
    Set-Content -Path $marker -Value (Get-Date -Format o)
    try {
        $p = Start-Process -FilePath (Get-Command powershell.exe).Source -ArgumentList $psArgs -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    } catch {
        if (-not $hadMarker) { Remove-Item $marker -Force }   # nothing ran
        Warn 'skipped: administrator was not approved (run the install again to try once more)'
        return
    }
    if ($p.ExitCode -ne 0) {
        Warn "did not finish (exit code $($p.ExitCode)); see $(Join-Path $env:ProgramData 'macstyle\machine-icons.log')"
        return
    }
    Update-Icons
    Ok 'every folder, the C: drive and the Start menu shortcuts shared by all users'
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
        # Throws even on success when a narrower scope (this run's -ExecutionPolicy Bypass) overrides it
        try { Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force } catch [System.Security.SecurityException] { }
        if ((Get-ExecutionPolicy -Scope CurrentUser) -ne 'RemoteSigned') { Fail 'could not let PowerShell run your profile (execution policy).' }
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
        It, QuickLook, PowerToys and Auto Dark Mode start by themselves at every sign-in.
      - Icons: some apps and taskbar pins show the new icon only after signing in again.
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
    Start-AppsAtSignIn
    Install-Icons
    Install-MachineIcons
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
