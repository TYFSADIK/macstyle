# CI: install macstyle on Windows, check every result, uninstall and check that it is all back.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "PASS  $Name $Detail" } else { Write-Host "FAIL  $Name $Detail" -ForegroundColor Red; $script:fail++ }
}
function RegVal([string]$Key, [string]$Name) {
    $i = Get-ItemProperty $Key -ErrorAction SilentlyContinue
    if ($i -and ($i.PSObject.Properties.Name -contains $Name)) { return [string]$i.$Name }
    return '<none>'
}
$watch = @(
    @('HKCU:\Control Panel\Cursors', 'Arrow'), @('HKCU:\Control Panel\Cursors', 'IBeam'),
    @('HKCU:\Control Panel\Desktop', 'WallpaperStyle'), @('HKCU:\Software\Microsoft\Windows\DWM', 'AccentColor'),
    @('HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts', 'JetBrainsMonoNerdFont Regular (TrueType)')
)
$before = @{}; foreach ($w in $watch) { $before["$($w[0])|$($w[1])"] = RegVal $w[0] $w[1] }
$docs = [Environment]::GetFolderPath('MyDocuments')
$profiles = @((Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'), (Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1'))

$env:MACSTYLE_ALLOW_ADMIN = '1'   # CI runners are administrators; real installs refuse that
$installLog = Join-Path $env:TEMP 'macstyle-install.log'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'windows\install.ps1') -Yes *>&1 | Tee-Object -FilePath $installLog
Check 'install.ps1 finished' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
$installText = Get-Content -Raw $installLog

$state = Join-Path $env:LOCALAPPDATA 'macstyle'
$arrow = RegVal 'HKCU:\Control Panel\Cursors' 'Arrow'
Check 'macOS cursor' (($arrow -like '*macstyle*Pointer.cur') -and (Test-Path ([Environment]::ExpandEnvironmentVariables($arrow)))) $arrow
$font = RegVal 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts' 'JetBrainsMonoNerdFont Regular (TrueType)'
Check 'JetBrains Mono Nerd Font' (Test-Path $font) $font
Check 'Inter font' ((RegVal 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts' 'InterVariable (TrueType)') -ne '<none>')
$wall = RegVal 'HKCU:\Control Panel\Desktop' 'WallPaper'
Check 'wallpaper (day picture in light mode)' ($wall -like '*macstyle*mountain-l.jpg' -or $wall -like '*macstyle*mountain-d.jpg') $wall
Check 'dark-mode watcher at sign-in' (Test-Path (Join-Path ([Environment]::GetFolderPath('Startup')) 'macstyle dark mode.lnk'))
Check 'accent colour' ((RegVal 'HKCU:\Software\Microsoft\Windows\DWM' 'AccentColor') -ne $before['HKCU:\Software\Microsoft\Windows\DWM|AccentColor'])
foreach ($p in $profiles) { Check "profile block $(Split-Path $p -Leaf) in $(Split-Path (Split-Path $p) -Leaf)" ((Test-Path $p) -and ((Get-Content -Raw $p) -match 'macstyle')) }
Check 'starship config' (Test-Path (Join-Path $HOME '.config\macstyle\starship.toml'))
$frag = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\macstyle\macstyle.json'
$fragOk = $false; try { $j = Get-Content -Raw $frag | ConvertFrom-Json; $fragOk = ($j.schemes.Count -eq 2 -and $j.profiles[0].font.face -eq 'JetBrainsMono Nerd Font') } catch { }
Check 'Windows Terminal profile and colours' $fragOk $frag
if (Get-Command winget -ErrorAction SilentlyContinue) {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine')
    foreach ($t in @('starship', 'fastfetch', 'lsd', 'zoxide', 'fzf')) { Check "terminal tool $t" ([bool](Get-Command $t -ErrorAction SilentlyContinue)) }
    foreach ($app in @(@('Seelen.SeelenUI', 'Seelen UI (dock and top bar)'), @('QL-Win.QuickLook', 'QuickLook'), @('Microsoft.PowerToys', 'PowerToys'))) {
        $listed = winget list --id $app[0] -e --accept-source-agreements | Out-String
        Check $app[1] ($listed -match [regex]::Escape($app[0]))
    }
    # Auto Dark Mode comes from the Microsoft Store, which a Windows Server runner may not have:
    # it must at least be tried by name (once, it was silently skipped)
    $adm = $installText -match '\[ok\] Auto Dark Mode' -or $installText -match 'Auto Dark Mode: dark mode at sunset, and a tray switch did not install'
    Check 'Auto Dark Mode installed or tried' $adm (($installText -split "`n" | Select-String 'Auto Dark Mode') -join ' ').Trim()
    # The prompt itself renders in a fresh PowerShell with the profile
    # (native stderr is an error under Stop in Windows PowerShell 5.1, so not here)
    $ErrorActionPreference = 'Continue'
    $prompt = & powershell.exe -NoLogo -Command '. $PROFILE; starship prompt' 2>$null | Out-String
    $ErrorActionPreference = 'Stop'
    Check 'the prompt renders' ($prompt.Length -gt 10) ($prompt -replace '\x1b\[[0-9;]*m', '').Trim()
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'windows\uninstall.ps1') -Yes
Check 'uninstall.ps1 finished' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
$diff = @()
foreach ($w in $watch) { $k = "$($w[0])|$($w[1])"; $now = RegVal $w[0] $w[1]; if ($now -ne $before[$k]) { $diff += "$k : $($before[$k]) -> $now" } }
Check 'registry back as before' ($diff.Count -eq 0) ($diff -join '; ')
Check 'font files removed' (-not (Test-Path $font))
Check 'watcher removed' (-not (Test-Path (Join-Path ([Environment]::GetFolderPath('Startup')) 'macstyle dark mode.lnk')))
foreach ($p in $profiles) { Check "profile block removed from $(Split-Path (Split-Path $p) -Leaf)" (-not ((Test-Path $p) -and ((Get-Content -Raw $p) -match '# >>> macstyle'))) }
Check 'Windows Terminal profile removed' (-not (Test-Path $frag))
Write-Host ''
Write-Host "$fail failed"
exit $fail
