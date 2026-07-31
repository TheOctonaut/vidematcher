param(
    [Parameter(Mandatory = $false)]
    [string]$HelperExePath,

    [Parameter(Mandatory = $false)]
    [string]$OptionsFile,

    [Parameter(Mandatory = $false)]
    [string]$SearchRoot,

    [Parameter(Mandatory = $false)]
    [string[]]$MatchExtensions,

    [Parameter(Mandatory = $false)]
    [switch]$CaseSensitive,

    [Parameter(Mandatory = $false)]
    [int]$MaxBatchSize,

    [Parameter(Mandatory = $false)]
    [int]$CacheTtlSeconds,

    [Parameter(Mandatory = $false)]
    [string]$LogPath,

    [Parameter(Mandatory = $false)]
    [string]$NativeHostName,

    [Parameter(Mandatory = $false)]
    [string]$ExtensionId,

    [Parameter(Mandatory = $false)]
    [string]$ManifestDir,

    [Parameter(Mandatory = $false)]
    [switch]$NoConfirm
)

$ErrorActionPreference = "Stop"

$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $PSCommandPath
}
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($OptionsFile)) {
    $OptionsFile = Join-Path $scriptRoot "options.json"
}

$defaults = [PSCustomObject]@{
    NativeHostName  = "com.theoctonaut.vidwebmatch"
    ExtensionId     = "vidwebmatch@theoctonaut.local"
    ManifestDir     = Join-Path $env:APPDATA "Mozilla\NativeMessagingHosts"
    MatchExtensions = @(".avi", ".mp4")
    CaseInsensitive = $true
    MaxBatchSize    = 200
    CacheTtlSeconds = 30
    HelperExePath   = Join-Path $scriptRoot "native-host\bin\Release\netcoreapp3.1\VidWebMatch.NativeHost.exe"
    LogPath         = Join-Path $scriptRoot "logs\native-host.log"
}

function Get-OptionValue {
    param(
        [Parameter(Mandatory = $false)][object]$Options,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Options) { return $null }
    if ($Options.PSObject.Properties.Name -contains $Name) { return $Options.$Name }
    return $null
}

function Normalize-OptionalString {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    return $s
}

function Normalize-Extension {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    $s = ([string]$Value).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    if (-not $s.StartsWith(".")) { $s = "." + $s }
    return $s
}

function ConvertTo-NormalizedExtensionArray {
    param([object]$Value)
    if ($null -eq $Value) { return $null }

    $items = @()
    if ($Value -is [System.Array]) { $items = $Value } else { $items = @($Value) }

    $list = New-Object System.Collections.Generic.List[string]
    foreach ($item in $items) {
        $normalized = Normalize-Extension $item
        if ($null -ne $normalized) { $list.Add($normalized) }
    }

    if ($list.Count -eq 0) { return @() }
    return @($list | Select-Object -Unique)
}

$exampleOptionsFile = Join-Path $scriptRoot "options.json.example"
if (-not (Test-Path -LiteralPath $OptionsFile -PathType Leaf)) {
    if ($NoConfirm) {
        Write-Host "Options file not found: $OptionsFile (continuing without it)"
    }
    else {
        Write-Host "Options file not found: $OptionsFile"
        $response = Read-Host "Create it now? (Y/N)"
        if ($response -match '^[Yy]') {
            if (Test-Path -LiteralPath $exampleOptionsFile -PathType Leaf) {
                Copy-Item -LiteralPath $exampleOptionsFile -Destination $OptionsFile -Force
                Write-Host "Created options file from template: $OptionsFile"
            }
            else {
                $fallback = [ordered]@{
                    SearchRoot      = "C:/path/to/video-library"
                    MatchExtensions = $defaults.MatchExtensions
                    CaseInsensitive = $defaults.CaseInsensitive
                    MaxBatchSize    = $defaults.MaxBatchSize
                    CacheTtlSeconds = $defaults.CacheTtlSeconds
                    LogPath         = "C:/path/to/vidwebmatch/logs/native-host.log"
                }
                $fallback | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OptionsFile -Encoding UTF8
                Write-Host "Created options file with default values: $OptionsFile"
            }
        }
    }
}

$fileOptions = $null
if (Test-Path -LiteralPath $OptionsFile -PathType Leaf) {
    try {
        $raw = Get-Content -LiteralPath $OptionsFile -Raw
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $fileOptions = $raw | ConvertFrom-Json
        }
    }
    catch {
        throw "Failed to read options file '$OptionsFile': $($_.Exception.Message)"
    }
}

$resolvedHelperExePath = if ($PSBoundParameters.ContainsKey("HelperExePath")) {
    Normalize-OptionalString $HelperExePath
}
else {
    $opt = Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "HelperExePath")
    if ($null -ne $opt) { $opt } else { $defaults.HelperExePath }
}

$resolvedSearchRoot = if ($PSBoundParameters.ContainsKey("SearchRoot")) {
    Normalize-OptionalString $SearchRoot
}
else {
    Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "SearchRoot")
}

$resolvedMatchExtensions = if ($PSBoundParameters.ContainsKey("MatchExtensions")) {
    ConvertTo-NormalizedExtensionArray $MatchExtensions
}
else {
    $opt = ConvertTo-NormalizedExtensionArray (Get-OptionValue -Options $fileOptions -Name "MatchExtensions")
    if ($null -ne $opt) { $opt } else { $defaults.MatchExtensions }
}

$resolvedCaseInsensitive = if ($PSBoundParameters.ContainsKey("CaseSensitive")) {
    $false
}
else {
    $opt = Get-OptionValue -Options $fileOptions -Name "CaseInsensitive"
    if ($null -ne $opt) { [bool]$opt } else { $defaults.CaseInsensitive }
}

$resolvedMaxBatchSize = if ($PSBoundParameters.ContainsKey("MaxBatchSize")) {
    $MaxBatchSize
}
else {
    $opt = Get-OptionValue -Options $fileOptions -Name "MaxBatchSize"
    if ($null -ne $opt) { [int]$opt } else { $defaults.MaxBatchSize }
}

$resolvedCacheTtlSeconds = if ($PSBoundParameters.ContainsKey("CacheTtlSeconds")) {
    $CacheTtlSeconds
}
else {
    $opt = Get-OptionValue -Options $fileOptions -Name "CacheTtlSeconds"
    if ($null -ne $opt) { [int]$opt } else { $defaults.CacheTtlSeconds }
}

$resolvedLogPath = if ($PSBoundParameters.ContainsKey("LogPath")) {
    Normalize-OptionalString $LogPath
}
else {
    $opt = Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "LogPath")
    if ($null -ne $opt) { $opt } else { $defaults.LogPath }
}

$resolvedNativeHostName = if ($PSBoundParameters.ContainsKey("NativeHostName")) {
    Normalize-OptionalString $NativeHostName
}
else {
    $defaults.NativeHostName
}

$resolvedExtensionId = if ($PSBoundParameters.ContainsKey("ExtensionId")) {
    Normalize-OptionalString $ExtensionId
}
else {
    $defaults.ExtensionId
}

$resolvedManifestDir = if ($PSBoundParameters.ContainsKey("ManifestDir")) {
    Normalize-OptionalString $ManifestDir
}
else {
    $defaults.ManifestDir
}

if ([string]::IsNullOrWhiteSpace($resolvedHelperExePath)) {
    throw "HelperExePath is required."
}
if ([string]::IsNullOrWhiteSpace($resolvedSearchRoot)) {
    throw "SearchRoot is required. Set it in options.json or pass -SearchRoot."
}
if (-not (Test-Path -LiteralPath $resolvedSearchRoot -PathType Container)) {
    throw "SearchRoot does not exist or is not a directory: $resolvedSearchRoot"
}
if (-not (Test-Path -LiteralPath $resolvedHelperExePath -PathType Leaf)) {
    throw "Helper executable not found: $resolvedHelperExePath"
}
if ($resolvedMatchExtensions.Count -eq 0) {
    throw "MatchExtensions must contain at least one extension."
}
if ($resolvedMaxBatchSize -lt 1) {
    throw "MaxBatchSize must be >= 1."
}
if ($resolvedCacheTtlSeconds -lt 0) {
    throw "CacheTtlSeconds must be >= 0."
}
if ([string]::IsNullOrWhiteSpace($resolvedNativeHostName)) {
    throw "NativeHostName is required."
}
if ([string]::IsNullOrWhiteSpace($resolvedExtensionId)) {
    throw "ExtensionId is required."
}
if ([string]::IsNullOrWhiteSpace($resolvedManifestDir)) {
    throw "ManifestDir is required."
}

$resolvedOptionsFilePath = [System.IO.Path]::GetFullPath($OptionsFile)
$resolvedSearchRoot = [System.IO.Path]::GetFullPath($resolvedSearchRoot)
$resolvedHelperExePath = [System.IO.Path]::GetFullPath($resolvedHelperExePath)
$resolvedManifestDir = [System.IO.Path]::GetFullPath($resolvedManifestDir)

$resolvedOptions = [ordered]@{
    SearchRoot      = $resolvedSearchRoot
    MatchExtensions = $resolvedMatchExtensions
    CaseInsensitive = $resolvedCaseInsensitive
    MaxBatchSize    = $resolvedMaxBatchSize
    CacheTtlSeconds = $resolvedCacheTtlSeconds
    LogPath         = $resolvedLogPath
}

$optionsDir = Split-Path -Parent $resolvedOptionsFilePath
if (-not [string]::IsNullOrWhiteSpace($optionsDir)) {
    New-Item -ItemType Directory -Path $optionsDir -Force | Out-Null
}
$resolvedOptions | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $resolvedOptionsFilePath -Encoding UTF8

New-Item -ItemType Directory -Path $resolvedManifestDir -Force | Out-Null
$manifestPath = Join-Path $resolvedManifestDir ($resolvedNativeHostName + ".json")
$helperOptionsPath = Join-Path (Split-Path -Parent $resolvedHelperExePath) "options.json"
$helperOptionsDir = Split-Path -Parent $helperOptionsPath
if (-not [string]::IsNullOrWhiteSpace($helperOptionsDir)) {
    New-Item -ItemType Directory -Path $helperOptionsDir -Force | Out-Null
}
Copy-Item -LiteralPath $resolvedOptionsFilePath -Destination $helperOptionsPath -Force

$manifest = [ordered]@{
    name               = $resolvedNativeHostName
    description        = "Native helper for vidwebmatch extension"
    path               = $resolvedHelperExePath
    type               = "stdio"
    allowed_extensions = @($resolvedExtensionId)
}

$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

$regKeyPath = "HKCU:\Software\Mozilla\NativeMessagingHosts\$resolvedNativeHostName"
New-Item -Path $regKeyPath -Force | Out-Null
New-ItemProperty -Path $regKeyPath -Name "(default)" -PropertyType String -Value $manifestPath -Force | Out-Null

Write-Host "Installed native messaging host registration."
Write-Host "Host name: $resolvedNativeHostName"
Write-Host "Manifest: $manifestPath"
Write-Host "Options:  $resolvedOptionsFilePath"
Write-Host "Helper options copy: $helperOptionsPath"
Write-Host ("SUMMARY|tool=vidwebmatch-install|status=ok|host_name={0}|manifest={1}|options={2}" -f $resolvedNativeHostName, ($manifestPath -replace "\|", "/"), ($resolvedOptionsFilePath -replace "\|", "/"))
