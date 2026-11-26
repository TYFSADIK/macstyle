# >>> macstyle: the prompt, suggestions, z jumps, ls with icons (remove with uninstall.ps1) >>>
$env:STARSHIP_CONFIG = Join-Path $HOME '.config\macstyle\starship.toml'
if (Get-Command starship -ErrorAction SilentlyContinue) { Invoke-Expression (& starship init powershell --print-full-init | Out-String) }
if (Get-Command zoxide -ErrorAction SilentlyContinue) { Invoke-Expression (& { (zoxide init powershell | Out-String) }) }
if ((Get-Module PSReadLine).Version -ge [version]'2.1') {
    # A grey suggestion from your history as you type: press the right arrow to take it
    Set-PSReadLineOption -PredictionSource History -PredictionViewStyle InlineView
    $esc = [char]27   # (the `e escape is PowerShell 7 only)
    Set-PSReadLineOption -Colors @{ InlinePrediction = "$esc[38;2;142;142;147m"; Command = "$esc[38;2;31;160;80m" }
}
if (Get-Command lsd -ErrorAction SilentlyContinue) {
    Remove-Item Alias:ls -Force -ErrorAction SilentlyContinue
    function ls { lsd @args }
    function ll { lsd -l @args }
    function la { lsd -A @args }
    function lt { lsd --tree --depth=2 @args }
}
if ($env:WT_SESSION -and -not $env:MACSTYLE_FETCHED -and (Get-Command fastfetch -ErrorAction SilentlyContinue)) {
    $env:MACSTYLE_FETCHED = 1
    fastfetch
}
# <<< macstyle <<<
