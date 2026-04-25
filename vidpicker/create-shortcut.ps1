# Creates a Windows shortcut (.lnk) that launches the vidpicker UI with no console window.
# Run this once after cloning or copying the project folder.

$scriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDir)) {
    $scriptDir = Split-Path -Parent $PSCommandPath
}
if ([string]::IsNullOrWhiteSpace($scriptDir)) {
    $scriptDir = (Get-Location).Path
}

$uiScript = Join-Path $scriptDir "vidpicker-ui.ps1"
$lnkPath  = Join-Path $scriptDir "vidpicker.lnk"

$psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) {
    $psExe = (Get-Command powershell -ErrorAction SilentlyContinue).Source
}

if ([string]::IsNullOrWhiteSpace($psExe) -or -not (Test-Path -LiteralPath $psExe -PathType Leaf)) {
    throw "Could not locate powershell.exe"
}

$arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$uiScript`""

$wsh      = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($lnkPath)
$shortcut.TargetPath       = $psExe
$shortcut.Arguments        = $arguments
$shortcut.WorkingDirectory = $scriptDir
$shortcut.WindowStyle      = 7   # minimised / hidden
$shortcut.Description      = "vidpicker UI"
$shortcut.Save()

Write-Host "Shortcut created: $lnkPath"
Write-Host "Double-click vidpicker.lnk to launch the UI with no console window."
