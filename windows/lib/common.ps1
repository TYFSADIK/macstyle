# Shared by install.ps1 and uninstall.ps1. Dot-sourced, not run.
#
# What macstyle changes is recorded before it changes it, once (on the first install):
#   original\registry.json  each registry value as it was, or that it did not exist
#   original\files.json     each file as it was (a copy in original\files\), or that it did not exist
#   original\values.json    anything else (the PowerShell execution policy)
#   installed.txt           files and folders macstyle added
#   winget.txt              apps macstyle installed (uninstall.ps1 offers to remove them)

$Repo = Split-Path -Parent $PSScriptRoot | Split-Path -Parent
$State = Join-Path $env:LOCALAPPDATA 'macstyle'
$Original = Join-Path $State 'original'
$TerminalProfileGuid = '{4c3b0f1e-5a6d-4d2b-9a3e-6d6163737479}'   # must be a valid GUID (8-4-4-4-12), or Windows Terminal ignores the profile
$Marker = '# >>> macstyle'
$MarkerEnd = '# <<< macstyle'

function Step([string]$t) { Write-Host ''; Write-Host "==> $t" -ForegroundColor White }
function Ok([string]$t) { Write-Host "  [ok] $t" -ForegroundColor Green }
function Info([string]$t) { Write-Host "       $t" }
function Warn([string]$t) { Write-Host "  [!]  $t" -ForegroundColor Yellow }
function Fail([string]$t) { throw $t }

if (-not ('Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Native {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool SystemParametersInfo(uint action, uint param, string vparam, uint winIni);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    public static extern int AddFontResource(string file);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    public static extern bool RemoveFontResource(string file);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);
}
'@
}

function New-TempDir {
    $d = Join-Path ([IO.Path]::GetTempPath()) ('macstyle-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d | Out-Null
    return $d
}

function Get-Download([string]$Url, [string]$Dest) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'   # 10x faster in 5.1
    try {
        for ($i = 1; $i -le 3; $i++) {
            try { Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing; return }
            catch { if ($i -eq 3) { Fail "could not download $Url ($($_.Exception.Message)). Check the internet connection and run it again." } }
            Start-Sleep -Seconds 2
        }
    } finally { $ProgressPreference = $old }
}

function Expand-Items($Items) {
    # Windows PowerShell 5.1 hands a JSON array over as one item (an array inside an array):
    # flatten it, also for lists saved in that shape before
    foreach ($i in @($Items)) { if ($i -is [array]) { Expand-Items $i } elseif ($null -ne $i) { $i } }
}

function Read-Json([string]$Path) {
    if (Test-Path $Path) { return @(Expand-Items (Get-Content -Raw $Path | ConvertFrom-Json)) }
    return @()
}

function Write-Json([string]$Path, $Data) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    ConvertTo-Json -InputObject @($Data) -Depth 5 | Set-Content -Path $Path -Encoding UTF8
}

function Add-Installed([string]$Path) {
    $list = Join-Path $State 'installed.txt'
    if (-not ((Test-Path $list) -and (Get-Content $list) -contains $Path)) { Add-Content -Path $list -Value $Path }
}

# ------------------------------------------------------------------------------------- registry

function Save-RegValue([string]$Key, [string]$Name) {
    $file = Join-Path $Original 'registry.json'
    $all = Read-Json $file
    foreach ($e in $all) { if ($e.Key -eq $Key -and $e.Name -eq $Name) { return } }   # saved before
    $prop = if ($Name) { $Name } else { '(default)' }
    $entry = [ordered]@{ Key = $Key; Name = $Name; Exists = $false; Value = $null; Kind = $null }
    if (Test-Path $Key) {
        $item = Get-Item $Key
        if ($item.GetValueNames() -contains $Name) {
            $entry.Exists = $true
            $entry.Value = $item.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
            $entry.Kind = [string]$item.GetValueKind($Name)
        }
    }
    $all = @($all) + (New-Object psobject -Property $entry)
    Write-Json $file $all
}

function Set-RegValue([string]$Key, [string]$Name, $Value, [string]$Kind) {
    Save-RegValue $Key $Name
    if (-not (Test-Path $Key)) {
        # Remember the highest key macstyle creates, so the uninstall removes it again
        $top = $Key
        while ((Split-Path $top) -and -not (Test-Path (Split-Path $top))) { $top = Split-Path $top }
        Add-Installed $top
        New-Item -Path $Key -Force | Out-Null
    }
    $prop = if ($Name) { $Name } else { '(default)' }
    New-ItemProperty -Path $Key -Name $prop -Value $Value -PropertyType $Kind -Force | Out-Null
}

function Restore-Registry {
    foreach ($e in (Read-Json (Join-Path $Original 'registry.json'))) {
        $prop = if ($e.Name) { $e.Name } else { '(default)' }
        if ($e.Exists) {
            if (-not (Test-Path $e.Key)) { New-Item -Path $e.Key -Force | Out-Null }
            $v = $e.Value
            if ($e.Kind -eq 'DWord') { $v = [int32]$v } elseif ($e.Kind -eq 'QWord') { $v = [int64]$v }
            New-ItemProperty -Path $e.Key -Name $prop -Value $v -PropertyType $e.Kind -Force | Out-Null
        } elseif (Test-Path $e.Key) {
            Remove-ItemProperty -Path $e.Key -Name $prop -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------------------- files

function Save-File([string]$Path) {
    $file = Join-Path $Original 'files.json'
    $all = Read-Json $file
    foreach ($e in $all) { if ($e.Path -eq $Path) { return } }
    $entry = [ordered]@{ Path = $Path; Backup = $null }
    if (Test-Path $Path) {
        $backup = Join-Path $Original ('files\' + [guid]::NewGuid().ToString('N') + '-' + (Split-Path $Path -Leaf))
        New-Item -ItemType Directory -Force -Path (Split-Path $backup) | Out-Null
        Copy-Item -Path $Path -Destination $backup -Recurse -Force
        $entry.Backup = $backup
    }
    $all = @($all) + (New-Object psobject -Property $entry)
    Write-Json $file $all
}

function Put-File([string]$Src, [string]$Dest) {
    Save-File $Dest
    New-Item -ItemType Directory -Force -Path (Split-Path $Dest) | Out-Null
    Copy-Item -Path $Src -Destination $Dest -Force
}

function Restore-Files {
    # One file Windows will not let us write (some shared shortcuts belong to Windows itself) is
    # reported and skipped: the others, and the registry after them, are still put back
    foreach ($e in (Read-Json (Join-Path $Original 'files.json'))) {
        try {
            if ($e.Backup -and (Test-Path -LiteralPath $e.Backup)) {
                New-Item -ItemType Directory -Force -Path (Split-Path $e.Path) | Out-Null
                # Hidden or system files (desktop.ini) cannot be overwritten until they are normal files
                if (Test-Path -LiteralPath $e.Path -PathType Leaf) {
                    $item = Get-Item -LiteralPath $e.Path -Force
                    if ($item.Attributes -band ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System -bor [IO.FileAttributes]::ReadOnly)) {
                        $item.Attributes = 'Normal'
                    }
                }
                Copy-Item -LiteralPath $e.Backup -Destination $e.Path -Recurse -Force
            } elseif (Test-Path -LiteralPath $e.Path) {
                Remove-Item -LiteralPath $e.Path -Recurse -Force
            }
        } catch {
            Warn "$($e.Path) could not be put back: $($_.Exception.Message)"
        }
    }
}

function Save-Value([string]$Name, [string]$Value) {
    $file = Join-Path $Original 'values.json'
    $all = Read-Json $file
    foreach ($e in $all) { if ($e.Name -eq $Name) { return } }
    $all = @($all) + (New-Object psobject -Property ([ordered]@{ Name = $Name; Value = $Value }))
    Write-Json $file $all
}

function Get-SavedValue([string]$Name) {
    foreach ($e in (Read-Json (Join-Path $Original 'values.json'))) { if ($e.Name -eq $Name) { return $e.Value } }
    return $null
}

# ------------------------------------------------------------------------- PowerShell profiles

function Add-ProfileBlock([string]$Path, [string]$Block) {
    Save-File $Path
    $text = ''
    if (Test-Path $Path) { $text = Get-Content -Raw $Path; if ($null -eq $text) { $text = '' } }
    $text = Remove-Block $text
    if ($text -and -not $text.EndsWith("`n")) { $text += "`r`n" }
    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    Set-Content -Path $Path -Value ($text + $Block) -Encoding UTF8
}

function Remove-Block([string]$Text) {
    $pattern = '(?s)' + [regex]::Escape($Marker) + '.*?' + [regex]::Escape($MarkerEnd) + '[^\r\n]*\r?\n?'
    return [regex]::Replace($Text, $pattern, '')
}

# ---------------------------------------------------------------------------- Windows Terminal

function New-TerminalFragment([string]$PaletteFile) {
    # The macstyle palette (shared with Linux) as two Windows Terminal colour schemes
    $sections = @{}; $cur = $null
    foreach ($line in Get-Content $PaletteFile) {
        if ($line -match '^\[(.+)\]$') { $cur = $Matches[1]; $sections[$cur] = @{}; continue }
        if ($cur -and $line -match '^([^=]+)=(.*)$') { $sections[$cur][$Matches[1]] = $Matches[2] }
    }
    $names = @('black', 'red', 'green', 'yellow', 'blue', 'purple', 'cyan', 'white',
        'brightBlack', 'brightRed', 'brightGreen', 'brightYellow', 'brightBlue', 'brightPurple', 'brightCyan', 'brightWhite')
    $schemes = @()
    foreach ($mode in @('Light', 'Dark')) {
        $s = $sections[$mode]
        $scheme = [ordered]@{ name = "macstyle $mode"; background = $s['Background']; foreground = $s['Foreground'];
            cursorColor = $s['Cursor']; selectionBackground = $s['Color4'] }
        for ($i = 0; $i -lt 16; $i++) { $scheme[$names[$i]] = $s["Color$i"] }
        $schemes += $scheme
    }
    $shell = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe -NoLogo' } else { 'powershell.exe -NoLogo' }
    $frag = [ordered]@{
        profiles = @([ordered]@{
                guid = $TerminalProfileGuid; name = 'macstyle'; commandline = $shell; hidden = $false
                font = [ordered]@{ face = 'JetBrainsMono Nerd Font'; size = 11 }
                colorScheme = [ordered]@{ light = 'macstyle Light'; dark = 'macstyle Dark' }
                opacity = 88; useAcrylic = $true; padding = '12'; cursorShape = 'bar'
            })
        schemes  = $schemes
    }
    return (ConvertTo-Json -InputObject $frag -Depth 6)
}

function Stop-DarkSwitch {
    Get-Process -Name 'macstyle-darkswitch' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*macstyle-darkswitch.ps1*' -and $_.CommandLine -notlike '*-Once*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Get-Csc {
    # The C# compiler that is part of Windows (.NET Framework 4)
    @((Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'), (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')) |
        Where-Object { Test-Path $_ } | Select-Object -First 1
}

function Stop-WindowButtons {
    $p = @(Get-Process -Name 'macstyle-buttons' -ErrorAction SilentlyContinue)
    if ($p) { $p | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500 }
}

# ------------------------------------------------------------------------------------- icons

# Start menu or shortcut name (regular expression) -> icon in windows\icons (MacTahoe, GPL-3.0)
$AppIcons = @(
    @('^Google Chrome$', 'chrome'), @('^Microsoft Edge$', 'edge'), @('Firefox', 'firefox'), @('^Brave', 'brave'),
    @('^Opera', 'opera'), @('^Visual Studio Code', 'vscode'), @('^(Windows )?Terminal$', 'terminal'),
    @('^(Windows )?PowerShell', 'terminal'), @('^Command Prompt$', 'terminal'), @('^File Explorer$', 'finder'),
    @('^Settings$', 'settings'), @('^Control Panel$', 'control-panel'), @('^(Microsoft )?Teams', 'teams'),
    @('^Outlook', 'outlook'), @('^Word$', 'word'), @('^Excel$', 'excel'), @('^PowerPoint$', 'powerpoint'),
    @('^OneNote', 'onenote'), @('^Notepad', 'notepad'), @('^Calculator$', 'calculator'), @('^Photos$', 'photos'),
    @('^Snipping Tool$', 'screenshot'), @('^Calendar$', 'calendar'), @('^Mail$', 'mail'),
    @('^(Clock|Alarms)', 'clock'), @('^Microsoft Store$', 'store'), @('^Camera$', 'camera'),
    @('^Task Manager$', 'task-manager'), @('^Paint$', 'paint'), @('^(MSN )?Weather$', 'weather'), @('^Maps$', 'maps'),
    @('^Spotify', 'spotify'), @('^Discord', 'discord'), @('^Slack', 'slack'), @('^Zoom', 'zoom'),
    @('^WhatsApp', 'whatsapp'), @('^Telegram', 'telegram'), @('^Steam$', 'steam'), @('^VLC', 'vlc'),
    @('^OBS', 'obs'), @('^GIMP', 'gimp'), @('^Postman', 'postman'), @('^GitHub Desktop', 'github-desktop'),
    @('^(Adobe )?Acrobat', 'acrobat'), @('^AnyDesk', 'anydesk'), @('^TeamViewer', 'teamviewer'),
    @('^KeePassXC', 'keepassxc'), @('^1Password', '1password'), @('^Bitwarden', 'bitwarden'), @('^Notion', 'notion'),
    @('^Obsidian', 'obsidian'), @('^FileZilla', 'filezilla'), @('^PuTTY', 'putty'), @('^Wireshark', 'wireshark'),
    @('^Docker Desktop', 'docker'), @('VirtualBox', 'virtualbox'), @('^VMware Workstation', 'vmware'),
    @('^7-Zip', '7zip'), @('^FortiClient', 'forticlient'), @('^Cisco (Secure Client|AnyConnect)', 'cisco-vpn'),
    @('^PyCharm', 'pycharm'), @('^IntelliJ', 'intellij'), @('^Sublime Text', 'sublime'), @('^Python', 'python'),
    @('^Git (Bash|CMD|GUI)', 'git'), @('^Remote Desktop Connection$', 'remote-desktop')
)

function Get-IconFor([string]$Name) {
    foreach ($m in $AppIcons) { if ($Name -match $m[0]) { return $m[1] } }
    return $null
}

function Set-ShortcutIcons([string[]]$Dirs, [string]$IcoDir) {
    # Shortcuts (Start menu, desktop, taskbar pins) whose name is in $AppIcons get the macOS icon
    $shell = New-Object -ComObject WScript.Shell
    $n = 0
    foreach ($d in $Dirs) {
        if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter '*.lnk' -Recurse -Force -ErrorAction SilentlyContinue)) {
            $icon = Get-IconFor $f.BaseName
            if (-not $icon) { continue }
            $want = (Join-Path $IcoDir "$icon.ico") + ',0'
            try {
                $s = $shell.CreateShortcut($f.FullName)
                if ($s.IconLocation -eq $want) { continue }
                # Some shared shortcuts belong to Windows itself and cannot be changed: leave them
                try { [IO.File]::Open($f.FullName, 'Open', 'ReadWrite', 'ReadWrite').Close() } catch { continue }
                Save-File $f.FullName
                $s.IconLocation = $want
                $s.Save()
                $n++
            } catch { Warn "$($f.FullName): $($_.Exception.Message)" }
        }
    }
    return $n
}

function Update-Icons {
    # Tell Explorer the icons changed (SHCNE_ASSOCCHANGED) and refresh its icon cache
    [Native]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
    $ie4 = Join-Path $env:WINDIR 'System32\ie4uinit.exe'
    if (Test-Path $ie4) { & $ie4 -show 2>$null | Out-Null }
}

function Set-SeelenIconPack([bool]$On) {
    # Adds or removes the macstyle icon pack in Seelen UI's settings (activeIconPacks), keeping
    # every other setting as it is. Seelen UI must not be running while this writes.
    $file = Join-Path $env:APPDATA 'com.seelen.seelen-ui\settings.json'
    $id = '@macstyle/icons'
    $cfg = New-Object psobject
    if (Test-Path $file) { $cfg = Get-Content -Raw $file | ConvertFrom-Json }
    elseif (-not $On) { return }
    $packs = @()
    if ($cfg.PSObject.Properties['activeIconPacks']) { $packs = @($cfg.activeIconPacks) }
    $packs = @($packs | Where-Object { $_ -and $_ -ne $id })
    if ($On) {
        if ($packs -notcontains '@system/icon-pack') { $packs = @('@system/icon-pack') + $packs }
        $packs += $id
    }
    if ($cfg.PSObject.Properties['activeIconPacks']) { $cfg.activeIconPacks = $packs }
    else { $cfg | Add-Member -NotePropertyName 'activeIconPacks' -NotePropertyValue $packs }
    New-Item -ItemType Directory -Force -Path (Split-Path $file) | Out-Null
    $utf8 = New-Object Text.UTF8Encoding $false
    [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $cfg -Depth 30), $utf8)
}

# ------------------------------------------------------------------------------- lock screen

function Invoke-WinRT($Operation, [Type]$ResultType) {
    # Windows PowerShell 5.1 awaits a Windows Runtime operation through a .NET Task
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $methods = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 }
    if ($ResultType) {
        $m = ($methods | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0].MakeGenericMethod($ResultType)
    } else {
        $m = ($methods | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' })[0]
    }
    $task = $m.Invoke($null, @($Operation))
    $task.Wait(-1) | Out-Null
    if ($ResultType) { return $task.Result }
}

function Set-LockScreenImage([string]$Path) {
    [void][Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
    [void][Windows.System.UserProfile.LockScreen, Windows.System.UserProfile, ContentType = WindowsRuntime]
    $file = Invoke-WinRT ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
    Invoke-WinRT ([Windows.System.UserProfile.LockScreen]::SetImageFileAsync($file)) $null
}

function Save-LockScreenImage([string]$Dest) {
    # The picture on the lock screen now, kept so the uninstall can put it back. $Dest has no
    # extension: .png or .jpg is added from what the picture really is. Returns the file, or $null.
    # (Read through a DataReader: Windows PowerShell 5.1 cannot pick the AsStreamForRead overload
    # for the Windows Runtime stream, which failed on real Windows 11 machines.)
    [void][Windows.System.UserProfile.LockScreen, Windows.System.UserProfile, ContentType = WindowsRuntime]
    [void][Windows.Storage.Streams.DataReader, Windows.Storage.Streams, ContentType = WindowsRuntime]
    $stream = [Windows.System.UserProfile.LockScreen]::GetImageStream()
    if (-not $stream) { return $null }
    $reader = New-Object Windows.Storage.Streams.DataReader ($stream.GetInputStreamAt(0))
    try {
        $got = Invoke-WinRT ($reader.LoadAsync([uint32]$stream.Size)) ([uint32])
        if (-not $got) { return $null }
        $bytes = New-Object byte[] $got
        $reader.ReadBytes($bytes)
    } finally { $reader.Dispose(); $stream.Dispose() }
    $ext = if ($bytes.Length -gt 4 -and $bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50) { '.png' } else { '.jpg' }
    New-Item -ItemType Directory -Force -Path (Split-Path $Dest) | Out-Null
    [IO.File]::WriteAllBytes("$Dest$ext", $bytes)
    return "$Dest$ext"
}

function Get-SavedLockScreen {
    # The lock screen picture saved by the install (lockscreen.png or .jpg), or $null
    Get-ChildItem -Path $Original -Filter 'lockscreen.*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.png', '.jpg' } | Select-Object -First 1 -ExpandProperty FullName
}

# ------------------------------------------------------------------------- Seelen UI: bar and dock

$SeelenRoot = Join-Path $env:APPDATA 'com.seelen.seelen-ui'

function Get-Seelen {
    # Seelen UI's Start menu entry, or $null
    try { return Get-StartApps | Where-Object { $_.Name -eq 'Seelen UI' } | Select-Object -First 1 } catch { return $null }
}

function Stop-Seelen {
    # Seelen UI keeps its settings and layouts in memory and writes them back, and its service (which
    # runs as administrator) starts it again when it is killed: it is asked to quit (slu quit), and
    # only stopped by force if it does not
    $running = @(Get-Process -Name 'seelen-ui' -ErrorAction SilentlyContinue)
    if (-not $running) { return $false }
    $slu = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\slu.exe'
    if (-not (Test-Path $slu)) { $c = Get-Command slu.exe -ErrorAction SilentlyContinue; if ($c) { $slu = $c.Source } }
    if (Test-Path $slu) { try { & $slu quit 2>$null | Out-Null } catch { } }
    for ($i = 0; $i -lt 15 -and (Get-Process -Name 'seelen-ui' -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 1 }
    $left = @(Get-Process -Name 'seelen-ui' -ErrorAction SilentlyContinue)
    if ($left) { $left | Stop-Process -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
    return $true
}

function Invoke-SeelenStopped([scriptblock]$Write) {
    # Runs $Write while Seelen UI is not running, and again if something (its service) started it
    # in between, so the files it writes are the ones Seelen UI reads next. Returns whether Seelen
    # UI was running before.
    $was = $false
    for ($i = 0; $i -lt 3; $i++) {
        if (Stop-Seelen) { $was = $true }
        & $Write | Out-Null
        Start-Sleep -Seconds 3
        if (-not (Get-Process -Name 'seelen-ui' -ErrorAction SilentlyContinue)) { break }
    }
    return $was
}

function Start-Seelen {
    $seelen = Get-Seelen
    if ($seelen -and -not (Get-Process -Name 'seelen-ui' -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList "shell:AppsFolder\$($seelen.AppID)"
    }
}

function Set-JsonPath($Object, [string[]]$Path, $Value) {
    # Sets $Object.a.b.c = $Value, creating the objects on the way
    $o = $Object
    for ($i = 0; $i -lt $Path.Count - 1; $i++) {
        $n = $Path[$i]
        if (-not $o.PSObject.Properties[$n] -or $null -eq $o.$n) {
            if ($o.PSObject.Properties[$n]) { $o.$n = New-Object psobject } else { $o | Add-Member -NotePropertyName $n -NotePropertyValue (New-Object psobject) }
        }
        $o = $o.$n
    }
    $last = $Path[-1]
    if ($o.PSObject.Properties[$last]) { $o.$last = $Value } else { $o | Add-Member -NotePropertyName $last -NotePropertyValue $Value }
}

function Get-JsonPath($Object, [string[]]$Path) {
    # @{ Exists; Value } of $Object.a.b.c
    $o = $Object
    foreach ($n in $Path) {
        if ($null -eq $o -or -not ($o -is [psobject]) -or -not $o.PSObject.Properties[$n]) { return @{ Exists = $false; Value = $null } }
        $o = $o.$n
    }
    return @{ Exists = $true; Value = $o }
}

# Seelen UI settings macstyle sets: the bar and dock look, the clock like the macOS menu bar, and
# Seelen's own wallpaper off (it covered the macstyle wallpaper, and stops with an error whenever
# File Explorer restarts)
$SeelenSettings = @(
    @(@('byWidget', '@seelen/wallpaper-manager', 'enabled'), $false),
    @(@('byWidget', '@seelen/fancy-toolbar', 'enabled'), $true),
    @(@('byWidget', '@seelen/fancy-toolbar', 'position'), 'Top'),
    @(@('byWidget', '@seelen/fancy-toolbar', 'hideMode'), 'Never'),
    @(@('byWidget', '@seelen/weg', 'enabled'), $true),
    @(@('byWidget', '@seelen/weg', 'position'), 'Bottom'),
    @(@('byWidget', '@seelen/weg', 'size'), 48),
    @(@('byWidget', '@seelen/weg', 'spaceBetweenItems'), 6),
    @(@('byWidget', '@seelen/weg', 'hideMode'), 'OnOverlap'),
    # every screen has a dock: the main one with the pinned apps, the others with the windows open on them
    @(@('byWidget', '@seelen/weg', 'pinnedItemsVisibility'), 'WhenPrimary'),
    @(@('byWidget', '@seelen/weg', 'temporalItemsVisibility'), 'OnMonitor'),
    @(@('byWidget', '@seelen/weg', 'showInstanceCounter'), $false),
    @(@('byWidget', '@seelen/weg', 'showWindowTitle'), $false),
    @(@('dateFormat'), 'ddd D MMM  h:mm A')
)

# The macstyle dock theme (windows\seelen-theme): icons without tiles, magnified under the pointer
$SeelenThemeId = '@macstyle/dock'

function New-SeelenId { [guid]::NewGuid().ToString() }

function New-ToolbarLayout {
    # The macOS menu bar: the system menu (sleep, restart, shut down, lock, sign out) behind the
    # Windows logo where the Apple menu is, the name of the app in front in bold ("Finder" for the
    # desktop and File Explorer); on the right the status icons, Control Centre, notifications and
    # the date and time
    $logo = [ordered]@{
        id = (New-SeelenId); scopes = @(); template = 'return Icon({ name: "BsWindows" })'; render = $null; canvasSize = $null
        tooltip = 'return "Shut down, restart, sleep, lock, sign out"'; badge = $null
        onClick = 'trigger("@seelen/power-menu")'; onWheelUp = $null; onWheelDown = $null
        style = [ordered]@{ paddingLeft = '6px'; paddingRight = '10px' }; remoteData = [ordered]@{}
    }
    # the app in front, with its icon and its name in bold
    return [ordered]@{
        isReorderDisabled = $false
        left              = @($logo, '@default/focused-app')
        center            = @()
        right             = @('@seelen/tb-system-tray', '@seelen/tb-keyboard-selector', '@seelen/tb-bluetooth-popup',
            '@seelen/tb-network-popup', '@seelen/tb-media-popup', '@default/power', '@seelen/tb-notifications',
            '@seelen/tb-quick-settings', '@seelen/tb-calendar-popup')
    }
}

function Get-DockPinnedBlocks([string]$Path) {
    # The apps pinned in Seelen UI's dock, each as its YAML text, in order (File Explorer left out:
    # it is Finder, first). Seelen writes state.yml as YAML: an item starts with "- type:" at the
    # start of a line and its fields follow, indented. A file macstyle wrote itself is JSON.
    $blocks = New-Object System.Collections.Generic.List[string]
    if (-not $Path -or -not (Test-Path $Path)) { return ,$blocks }
    $text = Get-Content -Raw $Path
    if ($text -match '^\s*\{') {
        try {
            $j = $text | ConvertFrom-Json
            foreach ($side in 'left', 'center', 'right') {
                foreach ($i in @($j.$side)) {
                    if (-not $i -or $i.type -ne 'AppOrFile' -or -not $i.pinned) { continue }
                    if ([IO.Path]::GetFileName([string]$i.path) -eq 'explorer.exe') { continue }
                    $blocks.Add((ConvertTo-DockYaml $i))
                }
            }
        } catch { }
        return ,$blocks
    }
    $cur = $null
    $flush = {
        if ($cur -and $cur -match '^- type: (AppOrFile|PinnedApp|Pinned)\b' -and $cur -match '(?m)^  pinned: true' -and
            $cur -notmatch "(?mi)^  path: '?.*\\explorer\.exe'?\s*$") { $blocks.Add($cur.TrimEnd()) }
    }
    foreach ($l in ($text -split "`r?`n")) {
        if ($l -match '^- ') { & $flush; $cur = $l + "`n" }
        elseif ($l -match '^\s' -and $cur) { $cur += $l + "`n" }
        else { & $flush; $cur = $null }
    }
    & $flush
    return ,$blocks
}

function ConvertTo-YamlScalar($v) {
    if ($null -eq $v) { return 'null' }
    if ($v -is [bool]) { return $v.ToString().ToLower() }
    return "'" + ([string]$v).Replace("'", "''") + "'"
}

function ConvertTo-DockYaml($Item) {
    # One dock item (type, id, and an app's fields) as Seelen UI writes it
    $o = "- type: $($Item.type)`n  id: $($Item.id)"
    foreach ($k in 'displayName', 'umid', 'path', 'pinned', 'preventPinning', 'plugin') {
        if ($Item -is [System.Collections.IDictionary]) { if (-not $Item.Contains($k)) { continue }; $v = $Item[$k] }
        else { if (-not $Item.PSObject.Properties[$k]) { continue }; $v = $Item.$k }
        $o += "`n  ${k}: $(ConvertTo-YamlScalar $v)"
    }
    if ($Item.type -eq 'AppOrFile') { $o += "`n  relaunch: null" }
    return $o
}

function New-DockLayout([string]$Current) {
    # The macOS dock: Finder first, then Launchpad (all apps), the apps already pinned (kept, in
    # their order); the Trash at the end, after a divider. Returns @{ Yaml; Count }.
    $pinned = Get-DockPinnedBlocks $Current
    $center = New-Object System.Collections.Generic.List[string]
    $center.Add((ConvertTo-DockYaml ([ordered]@{ type = 'AppOrFile'; id = (New-SeelenId); displayName = 'Finder'; umid = $null; path = (Join-Path $env:WINDIR 'explorer.exe'); pinned = $true; preventPinning = $false })))
    $center.Add((ConvertTo-DockYaml ([ordered]@{ type = 'Plugin'; id = (New-SeelenId); plugin = '@default/weg-start-menu' })))
    foreach ($b in $pinned) { $center.Add($b) }
    $right = @((ConvertTo-DockYaml ([ordered]@{ type = 'Separator'; id = (New-SeelenId) })),
        (ConvertTo-DockYaml ([ordered]@{ type = 'Plugin'; id = (New-SeelenId); plugin = '@default/weg-trash-bin' })))
    $yaml = "isReorderDisabled: false`nleft: []`ncenter:`n" + ($center -join "`n") + "`nright:`n" + ($right -join "`n") + "`n"
    return @{ Yaml = $yaml; Count = $center.Count }
}

function Set-SeelenLook {
    # Writes the macOS layout of the top bar and the dock, and the settings above. What was there
    # is kept first: the two layout files with Save-File, each setting in original\seelen.json.
    # Seelen UI must not be running while this writes.
    $utf8 = New-Object Text.UTF8Encoding $false
    $file = Join-Path $SeelenRoot 'settings.json'
    $cfg = New-Object psobject
    if (Test-Path $file) { $cfg = Get-Content -Raw $file | ConvertFrom-Json }
    $savedFile = Join-Path $Original 'seelen.json'
    if (-not (Test-Path $savedFile)) {
        $saved = @()
        foreach ($s in @($SeelenSettings) + ,@(@('activeThemes'), $null)) {
            $now = Get-JsonPath $cfg $s[0]
            $saved += [ordered]@{ Path = $s[0]; Exists = $now.Exists; Value = $now.Value }
        }
        New-Item -ItemType Directory -Force -Path $Original | Out-Null
        [IO.File]::WriteAllText($savedFile, (ConvertTo-Json -InputObject @($saved) -Depth 10), $utf8)
    }
    foreach ($s in $SeelenSettings) { Set-JsonPath $cfg $s[0] $s[1] }
    # the dock theme: its files, then switched on after Seelen's own (activeThemes was saved above)
    $themeDir = Join-Path $SeelenRoot 'themes\macstyle-dock'
    New-Item -ItemType Directory -Force -Path (Join-Path $themeDir 'styles') | Out-Null
    Copy-Item (Join-Path $Repo 'windows\seelen-theme\metadata.yml') $themeDir -Force
    Copy-Item (Join-Path $Repo 'windows\seelen-theme\styles\weg.css') (Join-Path $themeDir 'styles') -Force
    Add-Installed $themeDir
    $themes = @((Get-JsonPath $cfg @('activeThemes')).Value | Where-Object { $_ -and $_ -ne $SeelenThemeId })
    if (-not $themes) { $themes = @('@default/theme') }
    Set-JsonPath $cfg @('activeThemes') @($themes + $SeelenThemeId)
    New-Item -ItemType Directory -Force -Path $SeelenRoot | Out-Null
    [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $cfg -Depth 30), $utf8)

    # The layouts (JSON is valid YAML)
    $toolbar = Join-Path $SeelenRoot 'data\seelen-fancy-toolbar\state.yml'
    $dock = Join-Path $SeelenRoot 'data\seelen-weg\state.yml'
    Save-File $toolbar
    Save-File $dock
    $dockLayout = New-DockLayout $dock
    New-Item -ItemType Directory -Force -Path (Split-Path $toolbar), (Split-Path $dock) | Out-Null
    [IO.File]::WriteAllText($toolbar, (ConvertTo-Json -InputObject (New-ToolbarLayout) -Depth 10), $utf8)
    [IO.File]::WriteAllText($dock, $dockLayout.Yaml, $utf8)
    return $dockLayout.Count
}

function Restore-SeelenLook {
    # The settings Set-SeelenLook changed, as they were (the layout files come back with Restore-Files)
    $savedFile = Join-Path $Original 'seelen.json'
    $file = Join-Path $SeelenRoot 'settings.json'
    if (-not (Test-Path $savedFile) -or -not (Test-Path $file)) { return }
    $cfg = Get-Content -Raw $file | ConvertFrom-Json
    # (assigned first: Windows PowerShell 5.1 passes a JSON array down the pipeline as one item)
    $saved = Get-Content -Raw $savedFile | ConvertFrom-Json
    foreach ($s in $saved) {
        $path = @($s.Path)
        if ($s.Exists) { Set-JsonPath $cfg $path $s.Value; continue }
        if ($path.Count -eq 1) { $cfg.PSObject.Properties.Remove($path[0]); continue }
        $parent = Get-JsonPath $cfg $path[0..($path.Count - 2)]
        if ($parent.Exists -and $null -ne $parent.Value) {
            $parent.Value.PSObject.Properties.Remove($path[-1])
            # a section macstyle made for it, now empty, goes too
            if ($path.Count -ge 3 -and @($parent.Value.PSObject.Properties).Count -eq 0) {
                $gp = Get-JsonPath $cfg $path[0..($path.Count - 3)]
                if ($gp.Exists -and $null -ne $gp.Value) { $gp.Value.PSObject.Properties.Remove($path[-2]) }
            }
        }
    }
    $utf8 = New-Object Text.UTF8Encoding $false
    [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $cfg -Depth 30), $utf8)
}
