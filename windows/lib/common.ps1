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
$TerminalProfileGuid = '{4c3b0f1e-5a6d-4d2b-9a3e-6d61637374796c}'
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

function Read-Json([string]$Path) {
    if (Test-Path $Path) { return @(Get-Content -Raw $Path | ConvertFrom-Json) }
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
    if (-not (Test-Path $Key)) { New-Item -Path $Key -Force | Out-Null }
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
    foreach ($e in (Read-Json (Join-Path $Original 'files.json'))) {
        if ($e.Backup -and (Test-Path $e.Backup)) {
            New-Item -ItemType Directory -Force -Path (Split-Path $e.Path) | Out-Null
            Copy-Item -Path $e.Backup -Destination $e.Path -Recurse -Force
        } elseif (Test-Path $e.Path) {
            Remove-Item -Path $e.Path -Recurse -Force
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
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*macstyle-darkswitch.ps1*' -and $_.CommandLine -notlike '*-Once*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
