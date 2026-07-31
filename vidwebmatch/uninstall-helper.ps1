param(
    [Parameter(Mandatory = $false)]
    [string]$NativeHostName,

    [Parameter(Mandatory = $false)]
    [string]$ManifestDir,

    [Parameter(Mandatory = $false)]
    [switch]$RemoveOptions,

    [Parameter(Mandatory = $false)]
    [string]$OptionsFile,

    [Parameter(Mandatory = $false)]
    [switch]$RemoveLogs
)

$ErrorActionPreference = "Stop"

$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $PSCommandPath
}
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = (Get-Location).Path
}

$resolvedNativeHostName = if ($PSBoundParameters.ContainsKey("NativeHostName")) {
    $NativeHostName
}
else {
    "com.theoctonaut.vidwebmatch"
}

$resolvedManifestDir = if ($PSBoundParameters.ContainsKey("ManifestDir")) {
    $ManifestDir
}
else {
    Join-Path $env:APPDATA "Mozilla\NativeMessagingHosts"
}

$resolvedOptionsFile = if ($PSBoundParameters.ContainsKey("OptionsFile")) {
    $OptionsFile
}
else {
    Join-Path $scriptRoot "options.json"
}

$manifestPath = Join-Path $resolvedManifestDir ($resolvedNativeHostName + ".json")
$regKeyPath = "HKCU:\Software\Mozilla\NativeMessagingHosts\$resolvedNativeHostName"

$removedManifest = $false
$removedRegistry = $false
$removedOptions = $false
$removedLogs = $false

if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    Remove-Item -LiteralPath $manifestPath -Force
    $removedManifest = $true
}

if (Test-Path -LiteralPath $regKeyPath) {
    Remove-Item -Path $regKeyPath -Force
    $removedRegistry = $true
}

if ($RemoveOptions -and (Test-Path -LiteralPath $resolvedOptionsFile -PathType Leaf)) {
    Remove-Item -LiteralPath $resolvedOptionsFile -Force
    $removedOptions = $true
}

if ($RemoveLogs) {
    $logDir = Join-Path $scriptRoot "logs"
    if (Test-Path -LiteralPath $logDir -PathType Container) {
        Remove-Item -LiteralPath $logDir -Recurse -Force
        $removedLogs = $true
    }
}

Write-Host "Uninstalled native messaging host registration."
Write-Host "Removed registry: $removedRegistry"
Write-Host "Removed manifest: $removedManifest"
Write-Host "Removed options:  $removedOptions"
Write-Host "Removed logs:     $removedLogs"
Write-Host ("SUMMARY|tool=vidwebmatch-uninstall|status=ok|host_name={0}|removed_registry={1}|removed_manifest={2}|removed_options={3}|removed_logs={4}" -f $resolvedNativeHostName, $removedRegistry.ToString().ToLowerInvariant(), $removedManifest.ToString().ToLowerInvariant(), $removedOptions.ToString().ToLowerInvariant(), $removedLogs.ToString().ToLowerInvariant())
