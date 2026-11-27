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
    @('HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts', 'JetBrainsMonoNerdFont Regular (TrueType)'),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CLSID\{20D04FE0-3AEA-1069-A2D8-08002B30309D}\DefaultIcon', '(default)'),
    @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons', '3'),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'HideFileExt'),
    @('HKCU:\Software\Classes\CLSID\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}', 'System.IsPinnedToNameSpaceTree'),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'RotatingLockScreenEnabled'),
    @('HKCU:\AppEvents\Schemes\Apps\Explorer\Navigating\.Current', '(default)'),
    @('HKCU:\AppEvents\Schemes\Apps\.Default\Notification.Default\.Current', '(default)')
)
$before = @{}; foreach ($w in $watch) { $before["$($w[0])|$($w[1])"] = RegVal $w[0] $w[1] }
$docs = [Environment]::GetFolderPath('MyDocuments')
$docsIni = Join-Path $docs 'desktop.ini'
$docsIniBefore = if (Test-Path $docsIni) { Get-Content -Raw $docsIni } else { '<none>' }
# A folder with a file in it on the desktop: Windows 11 draws those from their contents, so it needs its own icon
$deskFolder = Join-Path ([Environment]::GetFolderPath('Desktop')) 'macstyle-ci-folder'
New-Item -ItemType Directory -Force -Path $deskFolder | Out-Null
'note' | Set-Content (Join-Path $deskFolder 'note.txt')
$deskFolderAttr = [string](Get-Item $deskFolder).Attributes
$seelenRoot = Join-Path $env:APPDATA 'com.seelen.seelen-ui'
$seelenState = @{}
foreach ($f in @('data\seelen-fancy-toolbar\state.yml', 'data\seelen-weg\state.yml')) { $x = Join-Path $seelenRoot $f; $seelenState[$f] = if (Test-Path $x) { (Get-FileHash $x).Hash } else { '<none>' } }
function SeelenSetting([string[]]$Path) {
    $f = Join-Path $seelenRoot 'settings.json'
    if (-not (Test-Path $f)) { return '<none>' }
    $o = Get-Content -Raw $f | ConvertFrom-Json
    foreach ($n in $Path) { if ($null -eq $o -or -not $o.PSObject.Properties[$n]) { return '<none>' }; $o = $o.$n }
    return [string]$o
}
$wallMgrBefore = SeelenSetting @('byWidget', '@seelen/wallpaper-manager', 'enabled')
$profiles = @((Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'), (Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1'))

$env:MACSTYLE_ALLOW_ADMIN = '1'   # CI runners are administrators; real installs refuse that
$installLog = Join-Path $env:TEMP 'macstyle-install.log'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'windows\install.ps1') -Yes *>&1 | Tee-Object -FilePath $installLog
Check 'install.ps1 finished' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
$machineLog = Join-Path $env:ProgramData 'macstyle\machine-icons.log'
if ((Test-Path $machineLog) -and ((Get-Content -Raw $machineLog) -match 'Error:')) { Write-Host '--- machine-icons.log'; Get-Content $machineLog | Write-Host }
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
# the Mac window buttons are opt-in (-WindowButtons): by default nothing is drawn over app windows
Check 'no window buttons by default' (-not (Get-Process macstyle-buttons -ErrorAction SilentlyContinue))
Check 'window buttons not at sign-in' (-not (Test-Path (Join-Path ([Environment]::GetFolderPath('Startup')) 'macstyle window buttons.lnk')))
$dsExe = Join-Path $state 'bin\macstyle-darkswitch.exe'
Check 'dark-mode watcher built (no PowerShell loop)' ((Test-Path $dsExe) -and [bool](Get-Process macstyle-darkswitch -ErrorAction SilentlyContinue))
Check 'accent colour' ((RegVal 'HKCU:\Software\Microsoft\Windows\DWM' 'AccentColor') -ne $before['HKCU:\Software\Microsoft\Windows\DWM|AccentColor'])
foreach ($p in $profiles) { Check "profile block $(Split-Path $p -Leaf) in $(Split-Path (Split-Path $p) -Leaf)" ((Test-Path $p) -and ((Get-Content -Raw $p) -match 'macstyle')) }
$pc = RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CLSID\{20D04FE0-3AEA-1069-A2D8-08002B30309D}\DefaultIcon' '(default)'
Check 'This PC icon' (($pc -like '*macstyle*computer.ico,0') -and (Test-Path ($pc -replace ',0$', ''))) $pc
Check 'Documents folder icon' ((Test-Path $docsIni) -and ((Get-Content -Raw $docsIni) -match 'IconResource=.*macstyle.*folder-documents\.ico'))
$folderIcon = RegVal 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons' '3'
Check 'every folder icon (administrator step)' (($folderIcon -like '*ProgramData*macstyle*folder.ico,0') -and (Test-Path ($folderIcon -replace ',0$', ''))) $folderIcon
$orig = Join-Path $env:LOCALAPPDATA 'macstyle\original'
if ($installText -match 'picture on the lock screen') { Check 'lock screen picture saved for the uninstall' ([bool](Get-ChildItem $orig -Filter 'lockscreen*' -ErrorAction SilentlyContinue)) }
else { Write-Host "note  lock screen: $((($installText -split "`n") | Select-String 'lock screen' | Select-Object -Last 1))" }
$ciIni = Join-Path $deskFolder 'desktop.ini'
Check 'a desktop folder with files gets the macOS folder' ((Test-Path $ciIni) -and ((Get-Content -Raw $ciIni) -match 'IconResource=.*folder\.ico'))
Check 'Finder: file extensions hidden' ((RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt') -eq 1)
Check 'Finder: Gallery out of the sidebar' ((RegVal 'HKCU:\Software\Classes\CLSID\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}' 'System.IsPinnedToNameSpaceTree') -eq 0)
$nav = $before['HKCU:\AppEvents\Schemes\Apps\Explorer\Navigating\.Current|(default)']
if ($nav -and $nav -ne '<none>') { Check 'quiet: no click sound in File Explorer' (-not (RegVal 'HKCU:\AppEvents\Schemes\Apps\Explorer\Navigating\.Current' '(default)')) }
Check 'quiet: notifications keep their sound' ((RegVal 'HKCU:\AppEvents\Schemes\Apps\.Default\Notification.Default\.Current' '(default)') -eq $before['HKCU:\AppEvents\Schemes\Apps\.Default\Notification.Default\.Current|(default)'])
Check 'starship config' (Test-Path (Join-Path $HOME '.config\macstyle\starship.toml'))
$frag = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\macstyle\macstyle.json'
$fragOk = $false; try { $j = Get-Content -Raw $frag | ConvertFrom-Json; $fragOk = ($j.schemes.Count -eq 2 -and $j.profiles[0].font.face -eq 'JetBrainsMono Nerd Font' -and [bool]([guid]$j.profiles[0].guid)) } catch { }
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
    $startup = [Environment]::GetFolderPath('Startup')
    foreach ($n in @('Seelen UI', 'QuickLook')) {
        if ($installText -match [regex]::Escape("[ok] $n (starts at sign-in)")) { Check "$n starts at sign-in" (Test-Path (Join-Path $startup "$n (macstyle).lnk")) }
    }
    $kbm = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\Keyboard Manager\default.json'
    if ($installText -match 'work like Cmd') {
        Check 'Mac shortcuts: Alt+C copies (PowerToys Keyboard Manager)' ((Test-Path $kbm) -and ((Get-Content -Raw $kbm) -match '"18;67"'))
    } else { Write-Host "note  Mac shortcuts not set here: $((($installText -split "`n") | Select-String 'Keyboard|PowerToys is not' | Select-Object -Last 1))" }
    if ($installText -match '\[ok\] top bar') {
        Check "Seelen UI: its own wallpaper off (macstyle's shows)" ((SeelenSetting @('byWidget', '@seelen/wallpaper-manager', 'enabled')) -eq 'False')
        Check 'Seelen UI: clock like the macOS menu bar' ((SeelenSetting @('dateFormat')) -eq 'ddd D MMM  h:mm A')
        Check 'dock theme on (magnification)' ((SeelenSetting @('activeThemes')) -match '@macstyle/dock')
        Check 'dock theme files' (Test-Path (Join-Path $seelenRoot 'themes\macstyle-dock\styles\weg.css'))
        Check 'a dock on every screen' ((SeelenSetting @('byWidget', '@seelen/weg', 'temporalItemsVisibility')) -eq 'OnMonitor')
        $tb = Get-Content -Raw (Join-Path $seelenRoot 'data\seelen-fancy-toolbar\state.yml') | ConvertFrom-Json
        Check 'top bar: system menu at the left, the clock at the right' (($tb.left[0].onClick -match 'power-menu') -and ($tb.right[-1] -eq '@seelen/tb-calendar-popup'))
        $dk = (Get-Content -Raw (Join-Path $seelenRoot 'data\seelen-weg\state.yml')) -replace "`r", ''
        Check 'dock: Finder, then Launchpad, the Trash at the end' (($dk -match "center:\n- type: AppOrFile\n  id: [^\n]+\n  displayName: '?Finder'?\n(  [^\n]*\n)*- type: Plugin\n  id: [^\n]+\n  plugin: '?@default/weg-start-menu'?") -and ($dk.TrimEnd() -match "plugin: '?@default/weg-trash-bin'?$"))
        if (-not ($dk -match 'weg-trash-bin')) { Write-Host $dk }
    } else { Check 'top bar and dock step ran' $false ((($installText -split "`n") | Select-String 'Top bar and dock' -Context 0, 2 | Out-String).Trim()) }
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
$machineLog = Join-Path $env:ProgramData 'macstyle\machine-icons.log'
if (Test-Path $machineLog) { Write-Host '--- machine-icons.log after uninstall'; Get-Content $machineLog | Select-Object -Last 40 | Write-Host }
$diff = @()
foreach ($w in $watch) { $k = "$($w[0])|$($w[1])"; $now = RegVal $w[0] $w[1]; if ($now -ne $before[$k]) { $diff += "$k : $($before[$k]) -> $now" } }
Check 'registry back as before' ($diff.Count -eq 0) ($diff -join '; ')
if ($kbm -and (Test-Path $kbm)) { Check 'Mac shortcuts removed' (-not ((Get-Content -Raw $kbm) -match '"18;67"')) }
Check 'desktop folder: its icon gone, attributes as before' ((-not (Test-Path (Join-Path $deskFolder 'desktop.ini'))) -and ([string](Get-Item $deskFolder).Attributes -eq $deskFolderAttr)) ([string](Get-Item $deskFolder).Attributes)
Remove-Item $deskFolder -Recurse -Force
# (Seelen UI, started again, may write its own defaults where there was nothing: not macstyle's)
foreach ($f in $seelenState.Keys) {
    $x = Join-Path $seelenRoot $f
    if ($seelenState[$f] -ne '<none>') { Check "Seelen UI $f as before" ((Test-Path $x) -and (Get-FileHash $x).Hash -eq $seelenState[$f]) }
    else { Check "Seelen UI ${f}: macstyle's layout gone" (-not ((Test-Path $x) -and ((Get-Content -Raw $x) -match "Shut down, restart, sleep|displayName: '?Finder'?\s*$|(?m)displayName: '?Finder'?\r?$"))) }
}
$wallMgr = SeelenSetting @('byWidget', '@seelen/wallpaper-manager', 'enabled')
Check 'Seelen UI wallpaper setting as before' ($wallMgr -eq $wallMgrBefore -or ($wallMgrBefore -eq '<none>' -and $wallMgr -ne 'False')) "$wallMgrBefore -> $wallMgr"
Check 'font files removed' (-not (Test-Path $font))
$docsIniAfter = if (Test-Path $docsIni) { Get-Content -Raw $docsIni } else { '<none>' }
Check 'Documents desktop.ini back as before' ($docsIniAfter -eq $docsIniBefore)
Check 'shared icons removed' (-not (Test-Path (Join-Path $env:ProgramData 'macstyle')))
Check 'watcher removed' (-not (Test-Path (Join-Path ([Environment]::GetFolderPath('Startup')) 'macstyle dark mode.lnk')))
foreach ($p in $profiles) { Check "profile block removed from $(Split-Path (Split-Path $p) -Leaf)" (-not ((Test-Path $p) -and ((Get-Content -Raw $p) -match '# >>> macstyle'))) }
Check 'window buttons stopped' (-not (Get-Process macstyle-buttons -ErrorAction SilentlyContinue))
Check 'dark-mode watcher stopped' (-not (Get-Process macstyle-darkswitch -ErrorAction SilentlyContinue))
Check 'dock theme removed' (-not (Test-Path (Join-Path $seelenRoot 'themes\macstyle-dock')))
Check 'dock theme switched off' (-not ((SeelenSetting @('activeThemes')) -match '@macstyle/dock'))
Check 'window buttons removed from sign-in' (-not (Test-Path (Join-Path ([Environment]::GetFolderPath('Startup')) 'macstyle window buttons.lnk')))
Check 'Windows Terminal profile removed' (-not (Test-Path $frag))
$left = @(Get-ChildItem ([Environment]::GetFolderPath('Startup')) -Filter '*(macstyle).lnk' -ErrorAction SilentlyContinue)
Check 'sign-in shortcuts removed' ($left.Count -eq 0) (($left | ForEach-Object Name) -join ', ')
Write-Host ''
Write-Host "$fail failed"
exit $fail
