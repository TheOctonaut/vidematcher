param(
    [Parameter(Mandatory = $false)]
    [string]$SourceDir,

    [Parameter(Mandatory = $false)]
    [string]$DestDir,

    [Parameter(Mandatory = $false)]
    [string]$OptionsFile,

    [Parameter(Mandatory = $false)]
    [string[]]$InputFiles,

    [Parameter(Mandatory = $false)]
    [string]$InputFilesListFile,

    [Parameter(Mandatory = $false)]
    [string]$PresetName,

    [Parameter(Mandatory = $false)]
    [string]$PresetImportFile,

    [Parameter(Mandatory = $false)]
    [string]$HandBrakeCliPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputExtension,

    [Parameter(Mandatory = $false)]
    [string[]]$SourceExtensions,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

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

$exampleOptionsFileName = "options.json.example"
$exampleOptionsFile = Join-Path $scriptRoot $exampleOptionsFileName

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
    param([object]$Extension)

    if ($null -eq $Extension) { return $null }
    $n = ([string]$Extension).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($n)) { return $null }
    if (-not $n.StartsWith(".")) { $n = "." + $n }
    return $n
}

function ConvertTo-NormalizedExtensionArray {
    param([object]$Value)

    if ($null -eq $Value) { return $null }
    $items = if ($Value -is [System.Array]) { $Value } else { @($Value) }
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($item in $items) {
        $n = Normalize-Extension $item
        if ($null -ne $n) { $result.Add($n) }
    }
    if ($result.Count -eq 0) { return @() }
    return @($result | Select-Object -Unique)
}

function Get-NormalizedBaseName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    return $Name.Trim().ToLowerInvariant()
}

function Resolve-InputFilePath {
    param(
        [Parameter(Mandatory = $true)][string]$Item,
        [Parameter(Mandatory = $true)][string]$SourceRoot
    )

    if ([System.IO.Path]::IsPathRooted($Item)) {
        return [System.IO.Path]::GetFullPath($Item)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $SourceRoot $Item))
}

$defaults = [PSCustomObject]@{
    HandBrakeCliPath = "HandBrakeCLI"
    OutputExtension  = ".mp4"
    SourceExtensions = @(".avi", ".mp4", ".mkv")
}

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
                SourceDir        = "C:/path/to/handbrake-input"
                DestDir          = "C:/path/to/final-destination"
                PresetName       = "My Custom Preset"
                PresetImportFile = "C:/path/to/custom-presets.json"
                HandBrakeCliPath = $defaults.HandBrakeCliPath
                OutputExtension  = $defaults.OutputExtension
                SourceExtensions = $defaults.SourceExtensions
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
    Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "SourceDir")
}

$resolvedDestDir = if ($PSBoundParameters.ContainsKey("DestDir")) {
    $DestDir
}
else {
    Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "DestDir")
}

$resolvedPresetName = if ($PSBoundParameters.ContainsKey("PresetName")) {
    $PresetName
}
else {
    Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "PresetName")
}

$resolvedPresetImportFile = if ($PSBoundParameters.ContainsKey("PresetImportFile")) {
    $PresetImportFile
}
else {
    Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "PresetImportFile")
}

$resolvedHandBrakeCliPath = if ($PSBoundParameters.ContainsKey("HandBrakeCliPath")) {
    Normalize-OptionalString $HandBrakeCliPath
}
else {
    $v = Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "HandBrakeCliPath")
    if ($null -ne $v) { $v } else { $defaults.HandBrakeCliPath }
}

$resolvedOutputExtension = if ($PSBoundParameters.ContainsKey("OutputExtension")) {
    Normalize-Extension $OutputExtension
}
else {
    $v = Normalize-Extension (Get-OptionValue -Options $fileOptions -Name "OutputExtension")
    if ($null -ne $v) { $v } else { $defaults.OutputExtension }
}

$resolvedSourceExtensions = if ($PSBoundParameters.ContainsKey("SourceExtensions")) {
    ConvertTo-NormalizedExtensionArray $SourceExtensions
}
else {
    $v = ConvertTo-NormalizedExtensionArray (Get-OptionValue -Options $fileOptions -Name "SourceExtensions")
    if ($null -ne $v -and $v.Count -gt 0) { $v } else { $defaults.SourceExtensions }
}

if ([string]::IsNullOrWhiteSpace($resolvedSourceDir)) {
    throw "SourceDir is required. Provide -SourceDir or set SourceDir in options.json."
}

if ([string]::IsNullOrWhiteSpace($resolvedDestDir)) {
    throw "DestDir is required. Provide -DestDir or set DestDir in options.json."
}

if ([string]::IsNullOrWhiteSpace($resolvedPresetName)) {
    throw "PresetName is required. Provide -PresetName or set PresetName in options.json."
}

if (-not (Test-Path -LiteralPath $resolvedSourceDir -PathType Container)) {
    throw "Source directory does not exist: $resolvedSourceDir"
}

$sourceRoot = (Resolve-Path -LiteralPath $resolvedSourceDir).Path
$destResolved = Resolve-Path -LiteralPath $resolvedDestDir -ErrorAction SilentlyContinue
$destRoot = if ($null -ne $destResolved) { $destResolved.Path } else { $null }

if ([string]::IsNullOrWhiteSpace($destRoot)) {
    if ($DryRun) {
        $destRoot = $resolvedDestDir
        Write-Host "Dry run: destination folder does not exist yet: $destRoot"
    }
    else {
        New-Item -ItemType Directory -Path $resolvedDestDir -Force | Out-Null
        $destRoot = (Resolve-Path -LiteralPath $resolvedDestDir).Path
        Write-Host "Created destination folder: $destRoot"
    }
}

if ($null -ne $resolvedPresetImportFile) {
    if (-not [System.IO.Path]::IsPathRooted($resolvedPresetImportFile)) {
        $resolvedPresetImportFile = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot $resolvedPresetImportFile))
    }
    if (-not (Test-Path -LiteralPath $resolvedPresetImportFile -PathType Leaf)) {
        throw "PresetImportFile does not exist: $resolvedPresetImportFile"
    }
}

if (-not [System.IO.Path]::IsPathRooted($resolvedHandBrakeCliPath) -and $resolvedHandBrakeCliPath -notmatch '[\\/]') {
    $hbCommand = Get-Command $resolvedHandBrakeCliPath -ErrorAction SilentlyContinue
    if ($null -eq $hbCommand) {
        throw "HandBrakeCLI not found in PATH: $resolvedHandBrakeCliPath"
    }
    $resolvedHandBrakeCliPath = $hbCommand.Source
}
elseif (-not (Test-Path -LiteralPath $resolvedHandBrakeCliPath -PathType Leaf)) {
    throw "HandBrakeCLI path does not exist: $resolvedHandBrakeCliPath"
}

Write-Host "Scanning destination folder: $destRoot"
$destBaseNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$destFiles = Get-ChildItem -LiteralPath $destRoot -File -Recurse -ErrorAction SilentlyContinue
foreach ($file in $destFiles) {
    $normalized = Get-NormalizedBaseName -Name $file.BaseName
    if ($null -ne $normalized) {
        [void]$destBaseNames.Add($normalized)
    }
}

$extensionSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($ext in $resolvedSourceExtensions) {
    [void]$extensionSet.Add($ext)
}

$candidateFiles = New-Object System.Collections.Generic.List[System.IO.FileInfo]
$candidateWarnings = 0

$inputItems = New-Object System.Collections.Generic.List[string]
if ($PSBoundParameters.ContainsKey("InputFiles") -and $null -ne $InputFiles -and $InputFiles.Count -gt 0) {
    foreach ($item in $InputFiles) {
        if (-not [string]::IsNullOrWhiteSpace($item)) {
            $inputItems.Add($item)
        }
    }
}

if ($PSBoundParameters.ContainsKey("InputFilesListFile") -and -not [string]::IsNullOrWhiteSpace($InputFilesListFile)) {
    if (-not (Test-Path -LiteralPath $InputFilesListFile -PathType Leaf)) {
        throw "InputFilesListFile does not exist: $InputFilesListFile"
    }

    $fileItems = Get-Content -LiteralPath $InputFilesListFile -ErrorAction Stop
    foreach ($item in $fileItems) {
        if (-not [string]::IsNullOrWhiteSpace($item)) {
            $inputItems.Add($item)
        }
    }
}

if ($inputItems.Count -gt 0) {
    foreach ($item in $inputItems) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }

        $fullPath = Resolve-InputFilePath -Item $item -SourceRoot $sourceRoot
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            Write-Warning "Input file not found: $item"
            $candidateWarnings++
            continue
        }

        $file = Get-Item -LiteralPath $fullPath
        if (-not $extensionSet.Contains(($file.Extension).ToLowerInvariant())) {
            Write-Warning "Input file skipped due to extension filter: $($file.FullName)"
            $candidateWarnings++
            continue
        }

        $candidateFiles.Add($file)
    }
}
else {
    Write-Host "Scanning source folder: $sourceRoot"
    $scanned = Get-ChildItem -LiteralPath $sourceRoot -File -Recurse |
        Where-Object { $extensionSet.Contains(($_.Extension).ToLowerInvariant()) }

    foreach ($file in $scanned) {
        $candidateFiles.Add($file)
    }
}

if ($candidateFiles.Count -eq 0) {
    Write-Host "No candidate files found."
    Write-Host ("SUMMARY|tool=videncode|status=noop|dry_run={0}|candidates=0|selected=0|encoded=0|encode_failed=0|moved=0|move_failed=0|skipped_existing=0|skipped_conflicts=0|warnings={1}" -f ($(if ($DryRun) { "true" } else { "false" }), $candidateWarnings))
    exit 0
}

$selected = New-Object System.Collections.Generic.List[System.IO.FileInfo]
$skippedExisting = 0
$skippedConflicts = 0
$plannedOutputNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($file in $candidateFiles) {
    $normalizedBase = Get-NormalizedBaseName -Name $file.BaseName
    if ($null -eq $normalizedBase) {
        Write-Warning "Skipping file with empty basename: $($file.FullName)"
        $candidateWarnings++
        continue
    }

    if ($destBaseNames.Contains($normalizedBase)) {
        $skippedExisting++
        continue
    }

    $outName = $file.BaseName + $resolvedOutputExtension
    if ($plannedOutputNames.Contains($outName)) {
        Write-Warning "Multiple inputs map to same output name; skipping: $($file.FullName)"
        $skippedConflicts++
        continue
    }

    [void]$plannedOutputNames.Add($outName)
    $selected.Add($file)
}

if ($selected.Count -eq 0) {
    Write-Host "No files selected after filtering destination matches/conflicts."
    Write-Host ("SUMMARY|tool=videncode|status=noop|dry_run={0}|candidates={1}|selected=0|encoded=0|encode_failed=0|moved=0|move_failed=0|skipped_existing={2}|skipped_conflicts={3}|warnings={4}" -f ($(if ($DryRun) { "true" } else { "false" }), $candidateFiles.Count, $skippedExisting, $skippedConflicts, $candidateWarnings))
    exit 0
}

Write-Host ""
Write-Host "HandBrakeCLI: $resolvedHandBrakeCliPath"
Write-Host "Preset: $resolvedPresetName"
if ($null -ne $resolvedPresetImportFile) {
    Write-Host "Preset import file: $resolvedPresetImportFile"
}
Write-Host "Selected files: $($selected.Count)"
Write-Host "Skipped existing matches in destination: $skippedExisting"
Write-Host "Skipped output-name conflicts: $skippedConflicts"

$tempOutDir = Join-Path $sourceRoot ".videncode-temp"

if ($DryRun) {
    Write-Host ""
    Write-Host "[DRY RUN] Planned encodes:"
    foreach ($file in $selected) {
        $tempOutput = Join-Path $tempOutDir ($file.BaseName + $resolvedOutputExtension)
        $destOutput = Join-Path $destRoot ($file.BaseName + $resolvedOutputExtension)
        Write-Host "  $($file.FullName)"
        Write-Host "    -> encode temp: $tempOutput"
        Write-Host "    -> move to:    $destOutput"
    }
    Write-Host "SUMMARY|tool=videncode|status=noop|dry_run=true|candidates=$($candidateFiles.Count)|selected=$($selected.Count)|encoded=0|encode_failed=0|moved=0|move_failed=0|skipped_existing=$skippedExisting|skipped_conflicts=$skippedConflicts|warnings=$candidateWarnings"
    exit 0
}

if (-not $NoConfirm) {
    Write-Host ""
    $confirm = Read-Host "Proceed? (Y/N)"
    if ($confirm -notmatch '^[Yy]') {
        Write-Host "Aborted."
        Write-Host "SUMMARY|tool=videncode|status=aborted|dry_run=false|candidates=$($candidateFiles.Count)|selected=$($selected.Count)|encoded=0|encode_failed=0|moved=0|move_failed=0|skipped_existing=$skippedExisting|skipped_conflicts=$skippedConflicts|warnings=$candidateWarnings"
        exit 0
    }
}

if (-not (Test-Path -LiteralPath $tempOutDir -PathType Container)) {
    New-Item -ItemType Directory -Path $tempOutDir -Force | Out-Null
}

$encoded = 0
$encodeFailed = 0
$moved = 0
$moveFailed = 0

foreach ($file in $selected) {
    $outName = $file.BaseName + $resolvedOutputExtension
    $tempOutput = Join-Path $tempOutDir $outName
    $destOutput = Join-Path $destRoot $outName

    if (Test-Path -LiteralPath $tempOutput -PathType Leaf) {
        Remove-Item -LiteralPath $tempOutput -Force
    }

    $argList = New-Object System.Collections.Generic.List[string]
    $argList.Add("--input")
    $argList.Add($file.FullName)
    $argList.Add("--output")
    $argList.Add($tempOutput)
    if ($null -ne $resolvedPresetImportFile) {
        $argList.Add("--preset-import-file")
        $argList.Add($resolvedPresetImportFile)
    }
    $argList.Add("--preset")
    $argList.Add($resolvedPresetName)

    Write-Host ""
    Write-Host "Encoding: $($file.FullName)"

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $resolvedHandBrakeCliPath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($arg in $argList) {
        [void]$psi.ArgumentList.Add($arg)
    }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi

    [void]$proc.Start()
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()

    $exitCode = $proc.ExitCode
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $tempOutput -PathType Leaf)) {
        $encodeFailed++
        Write-Warning "HandBrakeCLI failed for '$($file.FullName)' (ExitCode: $exitCode)"
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            Write-Warning ($stderr.TrimEnd() -replace "\r?\n", [Environment]::NewLine)
        }
        continue
    }

    $encoded++

    try {
        Move-Item -LiteralPath $tempOutput -Destination $destOutput -Force
        $moved++
        Write-Host "Moved output to: $destOutput"
    }
    catch {
        $moveFailed++
        Write-Warning "Failed to move encoded output to destination: $($_.Exception.Message)"
    }
}

$status = if ($encodeFailed -gt 0 -or $moveFailed -gt 0) { "failed" } else { "ok" }

Write-Host ""
Write-Host "Done."
Write-Host "SUMMARY|tool=videncode|status=$status|dry_run=false|candidates=$($candidateFiles.Count)|selected=$($selected.Count)|encoded=$encoded|encode_failed=$encodeFailed|moved=$moved|move_failed=$moveFailed|skipped_existing=$skippedExisting|skipped_conflicts=$skippedConflicts|warnings=$candidateWarnings"

if ($status -eq "failed") {
    exit 1
}

exit 0
