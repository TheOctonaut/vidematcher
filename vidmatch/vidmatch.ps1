param(
    [Parameter(Mandatory = $false)]
    [string]$SourceDir,

    [Parameter(Mandatory = $false)]
    [string]$TargetDir,

    [Parameter(Mandatory = $false)]
    [string]$OptionsFile,

    [Parameter(Mandatory = $false)]
    [switch]$NoRecurse,

    [Parameter(Mandatory = $false)]
    [switch]$ShowRelativePaths,

    [Parameter(Mandatory = $false)]
    [string]$CsvOutputPath,

    [Parameter(Mandatory = $false)]
    [string[]]$SourceExtensions,

    [Parameter(Mandatory = $false)]
    [string[]]$TargetExtensions
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

$exampleOptionsFileName = "options.json.example"

function Get-NormalizedBaseName {
    param([Parameter(Mandatory = $true)][string]$Name)
    return $Name.ToLowerInvariant()
}

function Get-OptionValue {
    param(
        [Parameter(Mandatory = $true)][object]$Options,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Options) {
        return $null
    }

    if ($Options.PSObject.Properties.Name -contains $Name) {
        return $Options.$Name
    }

    return $null
}

function Normalize-OptionalString {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $stringValue = [string]$Value
    if ([string]::IsNullOrWhiteSpace($stringValue)) {
        return $null
    }

    return $stringValue
}

function Normalize-Extension {
    param([object]$Extension)

    if ($null -eq $Extension) {
        return $null
    }

    $normalized = ([string]$Extension).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $null
    }

    if (-not $normalized.StartsWith(".")) {
        $normalized = "." + $normalized
    }

    return $normalized
}

function ConvertTo-NormalizedExtensionArray {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $items = @()
    if ($Value -is [System.Array]) {
        $items = $Value
    }
    else {
        $items = @($Value)
    }

    $result = New-Object System.Collections.Generic.List[string]
    foreach ($item in $items) {
        $normalized = Normalize-Extension $item
        if ($null -ne $normalized) {
            $result.Add($normalized)
        }
    }

    if ($result.Count -eq 0) {
        return @()
    }

    return @($result | Select-Object -Unique)
}

function New-ExtensionSet {
    param([string[]]$Extensions)

    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ext in $Extensions) {
        [void]$set.Add($ext)
    }

    return $set
}

$defaults = [PSCustomObject]@{
    Recurse = $true
    ShowRelativePaths = $false
    CsvOutputPath = $null
    SourceExtensions = @(".avi", ".mp4")
    TargetExtensions = @(".avi", ".mp4")
}

$exampleOptionsFile = Join-Path $scriptRoot $exampleOptionsFileName

if (-not (Test-Path -LiteralPath $OptionsFile -PathType Leaf)) {
    Write-Host "Options file not found: $OptionsFile"
    $response = Read-Host "Create it now? (Y/N)"

    if ($response -match '^[Yy]') {
        if (Test-Path -LiteralPath $exampleOptionsFile -PathType Leaf) {
            Copy-Item -LiteralPath $exampleOptionsFile -Destination $OptionsFile -Force
            Write-Host "Created options file from template: $OptionsFile"
        }
        else {
            $defaultOptions = [ordered]@{
                SourceDir = $null
                TargetDir = $null
                Recurse = $defaults.Recurse
                ShowRelativePaths = $defaults.ShowRelativePaths
                CsvOutputPath = $defaults.CsvOutputPath
                SourceExtensions = $defaults.SourceExtensions
                TargetExtensions = $defaults.TargetExtensions
            }

            $defaultOptions | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OptionsFile -Encoding UTF8
            Write-Host "Created options file with default values: $OptionsFile"
        }
    }
    else {
        Write-Host "Continuing without options file."
    }
}

$fileOptions = $null
if (Test-Path -LiteralPath $OptionsFile -PathType Leaf) {
    try {
        $rawOptions = Get-Content -LiteralPath $OptionsFile -Raw
        if (-not [string]::IsNullOrWhiteSpace($rawOptions)) {
            $fileOptions = $rawOptions | ConvertFrom-Json
        }
    }
    catch {
        throw "Failed to read options file '$OptionsFile': $($_.Exception.Message)"
    }
}

$resolvedSourceDir = if ($PSBoundParameters.ContainsKey("SourceDir")) {
    $SourceDir
}
else {
    $optionSourceDir = Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "SourceDir")
    if ($null -ne $optionSourceDir) { $optionSourceDir } else { $null }
}

$resolvedTargetDir = if ($PSBoundParameters.ContainsKey("TargetDir")) {
    $TargetDir
}
else {
    $optionTargetDir = Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "TargetDir")
    if ($null -ne $optionTargetDir) { $optionTargetDir } else { $null }
}

$recurse = if ($PSBoundParameters.ContainsKey("NoRecurse")) {
    $false
}
else {
    $optionRecurse = Get-OptionValue -Options $fileOptions -Name "Recurse"
    if ($null -ne $optionRecurse) { [bool]$optionRecurse } else { $defaults.Recurse }
}

$resolvedShowRelativePaths = if ($PSBoundParameters.ContainsKey("ShowRelativePaths")) {
    $ShowRelativePaths.IsPresent
}
else {
    $optionShowRelativePaths = Get-OptionValue -Options $fileOptions -Name "ShowRelativePaths"
    if ($null -ne $optionShowRelativePaths) { [bool]$optionShowRelativePaths } else { $defaults.ShowRelativePaths }
}

$resolvedCsvOutputPath = if ($PSBoundParameters.ContainsKey("CsvOutputPath")) {
    Normalize-OptionalString $CsvOutputPath
}
else {
    $optionCsvOutputPath = Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "CsvOutputPath")
    if ($null -ne $optionCsvOutputPath) { $optionCsvOutputPath } else { $defaults.CsvOutputPath }
}

$resolvedSourceExtensions = if ($PSBoundParameters.ContainsKey("SourceExtensions")) {
    ConvertTo-NormalizedExtensionArray $SourceExtensions
}
else {
    $optionSourceExtensions = ConvertTo-NormalizedExtensionArray (Get-OptionValue -Options $fileOptions -Name "SourceExtensions")
    if ($null -ne $optionSourceExtensions) { $optionSourceExtensions } else { $defaults.SourceExtensions }
}

$resolvedTargetExtensions = if ($PSBoundParameters.ContainsKey("TargetExtensions")) {
    ConvertTo-NormalizedExtensionArray $TargetExtensions
}
else {
    $optionTargetExtensions = ConvertTo-NormalizedExtensionArray (Get-OptionValue -Options $fileOptions -Name "TargetExtensions")
    if ($null -ne $optionTargetExtensions) { $optionTargetExtensions } else { $defaults.TargetExtensions }
}

if ([string]::IsNullOrWhiteSpace($resolvedSourceDir)) {
    throw "SourceDir is required. Provide -SourceDir or set SourceDir in options.json."
}

if ([string]::IsNullOrWhiteSpace($resolvedTargetDir)) {
    throw "TargetDir is required. Provide -TargetDir or set TargetDir in options.json."
}

if (-not (Test-Path -LiteralPath $resolvedSourceDir -PathType Container)) {
    throw "Source directory does not exist: $resolvedSourceDir"
}

if (-not (Test-Path -LiteralPath $resolvedTargetDir -PathType Container)) {
    throw "Target directory does not exist: $resolvedTargetDir"
}

$sourceRoot = (Resolve-Path -LiteralPath $resolvedSourceDir).Path
$targetRoot = (Resolve-Path -LiteralPath $resolvedTargetDir).Path

if ($null -ne $resolvedCsvOutputPath) {
    $resolvedCsvOutputPath = [System.IO.Path]::GetFullPath($resolvedCsvOutputPath)
}

Write-Host "Scanning target folder: $targetRoot"
$targetExtensionSet = New-ExtensionSet $resolvedTargetExtensions
$targetFiles = Get-ChildItem -LiteralPath $targetRoot -File -Recurse:$recurse |
    Where-Object { $targetExtensionSet.Contains(($_.Extension).ToLowerInvariant()) }

$targetBaseNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($file in $targetFiles) {
    [void]$targetBaseNames.Add((Get-NormalizedBaseName -Name $file.BaseName))
}

Write-Host "Scanning source folder: $sourceRoot"
$sourceExtensionSet = New-ExtensionSet $resolvedSourceExtensions
$sourceFiles = Get-ChildItem -LiteralPath $sourceRoot -File -Recurse:$recurse |
    Where-Object { $sourceExtensionSet.Contains(($_.Extension).ToLowerInvariant()) }

$unmatched = foreach ($file in $sourceFiles) {
    $baseName = Get-NormalizedBaseName -Name $file.BaseName
    if (-not $targetBaseNames.Contains($baseName)) {
        if ($resolvedShowRelativePaths) {
            [PSCustomObject]@{
                BaseName = $file.BaseName
                FilePath = [System.IO.Path]::GetRelativePath($sourceRoot, $file.FullName)
            }
        }
        else {
            [PSCustomObject]@{
                BaseName = $file.BaseName
                FilePath = $file.FullName
            }
        }
    }
}

$sortedUnmatched = $unmatched | Sort-Object BaseName, FilePath

if ($null -ne $resolvedCsvOutputPath) {
    $csvDir = Split-Path -Parent $resolvedCsvOutputPath
    if (-not [string]::IsNullOrWhiteSpace($csvDir) -and -not (Test-Path -LiteralPath $csvDir -PathType Container)) {
        New-Item -ItemType Directory -Path $csvDir -Force | Out-Null
    }

    $sortedUnmatched | Export-Csv -LiteralPath $resolvedCsvOutputPath -NoTypeInformation -Encoding UTF8
    Write-Host "CSV written to: $resolvedCsvOutputPath"
}

if (-not $sortedUnmatched) {
    Write-Host "All source files have a filename match in target (ignoring extension)."
    exit 0
}

Write-Host ""
Write-Host "Unmatched source files:"
$sortedUnmatched | Format-Table -AutoSize

Write-Host ""
Write-Host ("Total unmatched: {0}" -f ($sortedUnmatched | Measure-Object).Count)