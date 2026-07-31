param(
    [Parameter(Mandatory = $false)]
    [string[]]$InputNames,

    [Parameter(Mandatory = $false)]
    [string]$InputNamesFile,

    [Parameter(Mandatory = $false)]
    [string]$OptionsFile,

    [Parameter(Mandatory = $false)]
    [string]$SearchRoot,

    [Parameter(Mandatory = $false)]
    [string[]]$MatchExtensions,

    [Parameter(Mandatory = $false)]
    [switch]$CaseSensitive,

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
    MatchExtensions = @(".avi", ".mp4")
    CaseInsensitive = $true
}

function Get-OptionValue {
    param(
        [Parameter(Mandatory = $true)][object]$Options,
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
    $items = if ($Value -is [System.Array]) { $Value } else { @($Value) }
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($item in $items) {
        $n = Normalize-Extension $item
        if ($null -ne $n) { $list.Add($n) }
    }
    if ($list.Count -eq 0) { return @() }
    return @($list | Select-Object -Unique)
}

function Get-NormalizedBaseName {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$CaseInsensitive
    )
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    if ([string]::IsNullOrWhiteSpace($baseName)) { return $null }
    if ($CaseInsensitive) { return $baseName.ToLowerInvariant() }
    return $baseName
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

if ([string]::IsNullOrWhiteSpace($resolvedSearchRoot)) {
    throw "SearchRoot is required. Set it in options.json or pass -SearchRoot."
}
if (-not (Test-Path -LiteralPath $resolvedSearchRoot -PathType Container)) {
    throw "SearchRoot does not exist or is not a directory: $resolvedSearchRoot"
}
if ($resolvedMatchExtensions.Count -eq 0) {
    throw "MatchExtensions must contain at least one extension."
}

$nameList = New-Object System.Collections.Generic.List[string]
if ($null -ne $InputNames) {
    foreach ($name in $InputNames) {
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $nameList.Add($name.Trim())
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($InputNamesFile)) {
    if (-not (Test-Path -LiteralPath $InputNamesFile -PathType Leaf)) {
        throw "InputNamesFile not found: $InputNamesFile"
    }
    foreach ($line in (Get-Content -LiteralPath $InputNamesFile)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $nameList.Add($line.Trim())
        }
    }
}

if ($nameList.Count -eq 0) {
    throw "Provide at least one filename via -InputNames or -InputNamesFile."
}

$matchSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($ext in $resolvedMatchExtensions) {
    [void]$matchSet.Add((Normalize-Extension $ext))
}

$index = @{}
$enumerationOptions = New-Object System.IO.EnumerationOptions
$enumerationOptions.RecurseSubdirectories = $true
$enumerationOptions.IgnoreInaccessible = $true
$enumerationOptions.AttributesToSkip = [System.IO.FileAttributes]::ReparsePoint

foreach ($file in [System.IO.Directory]::EnumerateFiles($resolvedSearchRoot, "*", $enumerationOptions)) {
    $ext = Normalize-Extension ([System.IO.Path]::GetExtension($file))
    if (-not $matchSet.Contains($ext)) { continue }

    $baseName = Get-NormalizedBaseName -Name $file -CaseInsensitive $resolvedCaseInsensitive
    if ($null -eq $baseName) { continue }
    if (-not $index.ContainsKey($baseName)) {
        $index[$baseName] = @{ has_avi = $false; has_mp4 = $false }
    }
    if ($ext -eq ".avi") { $index[$baseName].has_avi = $true }
    if ($ext -eq ".mp4") { $index[$baseName].has_mp4 = $true }
}

$missingCount = 0
$aviOnlyCount = 0
$mp4OnlyCount = 0
$bothCount = 0

$rows = New-Object System.Collections.Generic.List[object]
foreach ($inputName in $nameList) {
    $baseName = Get-NormalizedBaseName -Name $inputName -CaseInsensitive $resolvedCaseInsensitive
    if ($null -eq $baseName) { continue }

    $hasAvi = $false
    $hasMp4 = $false
    if ($index.ContainsKey($baseName)) {
        $hasAvi = [bool]$index[$baseName].has_avi
        $hasMp4 = [bool]$index[$baseName].has_mp4
    }

    $status = "missing"
    if ($hasAvi -and $hasMp4) {
        $status = "both"
        $bothCount++
    }
    elseif ($hasAvi) {
        $status = "avi_only"
        $aviOnlyCount++
    }
    elseif ($hasMp4) {
        $status = "mp4_only"
        $mp4OnlyCount++
    }
    else {
        $missingCount++
    }

    $rows.Add([PSCustomObject]@{
        Input    = $inputName
        Basename = $baseName
        Status   = $status
        HasAvi   = $hasAvi
        HasMp4   = $hasMp4
    })
}

$rows | Format-Table -AutoSize

Write-Host ("SUMMARY|tool=vidwebmatch|status=ok|requested={0}|missing={1}|avi_only={2}|mp4_only={3}|both={4}" -f $rows.Count, $missingCount, $aviOnlyCount, $mp4OnlyCount, $bothCount)
