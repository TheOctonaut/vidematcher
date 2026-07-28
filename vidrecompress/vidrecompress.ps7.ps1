param(
    [Parameter(Mandatory = $false)]
    [string]$SourceDir,

    [Parameter(Mandatory = $false)]
    [string]$TempDir,

    [Parameter(Mandatory = $false)]
    [string]$OptionsFile,

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
    [switch]$Recurse,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$NoConfirm,

    [Parameter(Mandatory = $false)]
    [switch]$VerboseConsole
)

$ErrorActionPreference = "Stop"

$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $PSCommandPath
}
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = (Get-Location).Path
}

$optionsFileExplicit = -not [string]::IsNullOrWhiteSpace($OptionsFile)
if (-not $optionsFileExplicit) {
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

function ConvertTo-ProgressValue {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    return (($Value -replace "\|", "/") -replace "\r?\n", " ")
}

function Format-Eta {
    param([double]$Seconds)
    if ($Seconds -le 0) { return "0s" }
    $h = [math]::Floor($Seconds / 3600)
    $m = [math]::Floor(($Seconds % 3600) / 60)
    $s = [math]::Floor($Seconds % 60)
    if ($h -gt 0) { return "${h}h ${m}m" }
    if ($m -gt 0) { return "${m}m ${s}s" }
    return "${s}s"
}

function Get-DriveFreeBytes {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $root = [System.IO.Path]::GetPathRoot($Path)
        if ([string]::IsNullOrWhiteSpace($root)) { return $null }
        return ([System.IO.DriveInfo]::new($root)).AvailableFreeSpace
    }
    catch { return $null }
}

$defaults = [PSCustomObject]@{
    HandBrakeCliPath = "HandBrakeCLI"
    OutputExtension  = ".mp4"
    SourceExtensions = @(".avi")
    Recurse          = $false
}

if (-not (Test-Path -LiteralPath $OptionsFile -PathType Leaf)) {
    if ($NoConfirm -and -not $optionsFileExplicit) {
        Write-Host "Options file not found: $OptionsFile (continuing without it)"
    }
    elseif ($optionsFileExplicit) {
        throw "Options file not found: $OptionsFile"
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
                $defaultOptions = [ordered]@{
                    SourceDir        = "Z:/"
                    TempDir          = "C:/path/to/temp-encode"
                    PresetName       = "My Custom Preset"
                    PresetImportFile = "C:/path/to/custom-presets.json"
                    HandBrakeCliPath = $defaults.HandBrakeCliPath
                    OutputExtension  = $defaults.OutputExtension
                    SourceExtensions = $defaults.SourceExtensions
                    Recurse          = $defaults.Recurse
                }
                $defaultOptions | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OptionsFile -Encoding UTF8
                Write-Host "Created options file with default values: $OptionsFile"
            }
        }
        else {
            Write-Host "Continuing without options file."
        }
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

$resolvedTempDir = if ($PSBoundParameters.ContainsKey("TempDir")) {
    $TempDir
}
else {
    Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "TempDir")
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

$resolvedRecurse = if ($PSBoundParameters.ContainsKey("Recurse")) {
    [bool]$Recurse
}
else {
    $v = Get-OptionValue -Options $fileOptions -Name "Recurse"
    if ($null -ne $v) { [bool]$v } else { $defaults.Recurse }
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($resolvedSourceDir)) {
    throw "SourceDir is required. Provide -SourceDir or set SourceDir in options.json."
}

if ([string]::IsNullOrWhiteSpace($resolvedTempDir)) {
    throw "TempDir is required. Provide -TempDir or set TempDir in options.json."
}

if ([string]::IsNullOrWhiteSpace($resolvedPresetName)) {
    throw "PresetName is required. Provide -PresetName or set PresetName in options.json."
}

if (-not (Test-Path -LiteralPath $resolvedSourceDir -PathType Container)) {
    throw "SourceDir does not exist: $resolvedSourceDir"
}

$sourceRoot = (Resolve-Path -LiteralPath $resolvedSourceDir).Path

$tempDirResolved = Resolve-Path -LiteralPath $resolvedTempDir -ErrorAction SilentlyContinue
$tempRoot = if ($null -ne $tempDirResolved) { $tempDirResolved.Path } else { $null }

if ($null -ne $tempRoot -and $tempRoot -eq $sourceRoot) {
    throw "TempDir and SourceDir must not be the same path: $sourceRoot"
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

# ---------------------------------------------------------------------------
# Scan for candidate files
# ---------------------------------------------------------------------------

$extensionSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($ext in $resolvedSourceExtensions) {
    [void]$extensionSet.Add($ext)
}

Write-Host "Scanning source folder: $sourceRoot"

$gciParams = @{
    LiteralPath = $sourceRoot
    File        = $true
    ErrorAction = "SilentlyContinue"
}
if ($resolvedRecurse) {
    $gciParams["Recurse"] = $true
}

$allFiles = Get-ChildItem @gciParams

$candidateFiles = New-Object System.Collections.Generic.List[System.IO.FileInfo]
$skippedExisting = 0
$warnings = 0

foreach ($file in $allFiles) {
    if (-not $extensionSet.Contains($file.Extension.ToLowerInvariant())) {
        continue
    }

    $outName = $file.BaseName + $resolvedOutputExtension
    $existingOutput = Join-Path $file.DirectoryName $outName

    if (Test-Path -LiteralPath $existingOutput -PathType Leaf) {
        $skippedExisting++
        continue
    }

    $candidateFiles.Add($file)
}

$candidateCount = $candidateFiles.Count
$totalScanned = $skippedExisting + $candidateCount

Write-Host "Files found: $totalScanned  |  Already have $($resolvedOutputExtension): $skippedExisting  |  Candidates: $candidateCount"

if ($candidateCount -eq 0) {
    Write-Host "No candidate files to recompress."
    Write-Host ("SUMMARY|tool=vidrecompress|status=noop|dry_run={0}|candidates=0|skipped_existing={1}|skipped_no_space=0|encoded=0|encode_failed=0|replaced=0|kept_original=0|space_saved_mb=0|warnings={2}" -f ($(if ($DryRun) { "true" } else { "false" }), $skippedExisting, $warnings))
    exit 0
}

# ---------------------------------------------------------------------------
# Dry run
# ---------------------------------------------------------------------------

if ($DryRun) {
    Write-Host ""
    Write-Host "[DRY RUN] Planned recompressions:"
    foreach ($file in $candidateFiles) {
        $tempOutput = Join-Path $resolvedTempDir ($file.BaseName + $resolvedOutputExtension)
        Write-Host "  DRYRUN: would encode $($file.FullName) -> $tempOutput"
        Write-Host "    then replace source if smaller"
    }
    Write-Host ""
    Write-Host "SUMMARY|tool=vidrecompress|status=noop|dry_run=true|candidates=$candidateCount|skipped_existing=$skippedExisting|skipped_no_space=0|encoded=0|encode_failed=0|replaced=0|kept_original=0|space_saved_mb=0|warnings=$warnings"
    exit 0
}

# ---------------------------------------------------------------------------
# Confirmation prompt
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "Found $candidateCount $($resolvedSourceExtensions -join '/') file(s) to recompress in: $sourceRoot"
Write-Host "  $skippedExisting already have $resolvedOutputExtension -- will skip"
Write-Host "  $candidateCount candidates to encode"
Write-Host "This will REPLACE source files with encoded versions if smaller."

if (-not $NoConfirm) {
    $confirm = Read-Host "Proceed? (Y/N)"
    if ($confirm -notmatch '^[Yy]') {
        Write-Host "Aborted."
        Write-Host "SUMMARY|tool=vidrecompress|status=aborted|dry_run=false|candidates=$candidateCount|skipped_existing=$skippedExisting|skipped_no_space=0|encoded=0|encode_failed=0|replaced=0|kept_original=0|space_saved_mb=0|warnings=$warnings"
        exit 0
    }
}

# ---------------------------------------------------------------------------
# Ensure TempDir exists
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $resolvedTempDir -PathType Container)) {
    New-Item -ItemType Directory -Path $resolvedTempDir -Force | Out-Null
    Write-Host "Created TempDir: $resolvedTempDir"
    $tempRoot = (Resolve-Path -LiteralPath $resolvedTempDir).Path
}
elseif ($null -eq $tempRoot) {
    $tempRoot = (Resolve-Path -LiteralPath $resolvedTempDir).Path
}

Write-Host ""
Write-Host "HandBrakeCLI: $resolvedHandBrakeCliPath"
Write-Host "Preset: $resolvedPresetName"
if ($null -ne $resolvedPresetImportFile) {
    Write-Host "Preset import file: $resolvedPresetImportFile"
}
Write-Host "TempDir: $tempRoot"
Write-Host ""

# ---------------------------------------------------------------------------
# Encode loop
# ---------------------------------------------------------------------------

$encoded = 0
$encodeFailed = 0
$replaced = 0
$keptOriginal = 0
$skippedNoSpace = 0
$sessionWatch = [System.Diagnostics.Stopwatch]::StartNew()
$fileIndex = 0
$currentTempFile = $null
$fileTimings = [System.Collections.Generic.List[double]]::new()
$fileWatch   = [System.Diagnostics.Stopwatch]::new()
$spaceSavedBytes = [long]0

try {
    foreach ($file in $candidateFiles) {
        $fileIndex++
        $fileWatch.Restart()
        $outName = $file.BaseName + $resolvedOutputExtension
        $tempOutput = Join-Path $tempRoot $outName
        $progressFile = ConvertTo-ProgressValue -Value $file.BaseName
        $ranHandBrake = $false

        # Check free space in TempDir: file * 1.2 + 100 MB headroom
        $spaceNeeded = [long]([math]::Ceiling($file.Length * 1.2)) + 104857600
        $freeBytes = Get-DriveFreeBytes -Path $tempRoot
        if ($null -ne $freeBytes -and $freeBytes -lt $spaceNeeded) {
            Write-Warning ("Not enough space in TempDir ({0:N0} bytes free, {1:N0} needed): skipping {2}" -f $freeBytes, $spaceNeeded, $file.Name)
            $skippedNoSpace++
            if ($VerboseConsole) {
                Write-Host ("PROGRESS|tool=vidrecompress|event=update|index={0}|total={1}|file={2}|elapsed_seconds={3}|encoded={4}|replaced={5}|kept_original={6}|encode_failed={7}" -f $fileIndex, $candidateCount, $progressFile, ([math]::Round($sessionWatch.Elapsed.TotalSeconds, 1)), $encoded, $replaced, $keptOriginal, $encodeFailed)
            }
        }
        else {
            if (Test-Path -LiteralPath $tempOutput -PathType Leaf) {
                Remove-Item -LiteralPath $tempOutput -Force
            }

            $currentTempFile = $tempOutput

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

            Write-Host "Encoding [$fileIndex/$candidateCount]: $($file.FullName)"

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
            $stderr = $stderrTask.GetAwaiter().GetResult()
            $ranHandBrake = $true

            if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $tempOutput -PathType Leaf)) {
                $encodeFailed++
                Write-Warning "HandBrakeCLI failed for '$($file.FullName)' (ExitCode: $exitCode)"
                if (-not [string]::IsNullOrWhiteSpace($stderr)) {
                    Write-Warning ($stderr.TrimEnd() -replace "\r?\n", [Environment]::NewLine)
                }
                if (Test-Path -LiteralPath $tempOutput -PathType Leaf) {
                    Remove-Item -LiteralPath $tempOutput -Force -ErrorAction SilentlyContinue
                }
                $currentTempFile = $null
                if ($VerboseConsole) {
                    Write-Host ("PROGRESS|tool=vidrecompress|event=update|index={0}|total={1}|file={2}|elapsed_seconds={3}|encoded={4}|replaced={5}|kept_original={6}|encode_failed={7}" -f $fileIndex, $candidateCount, $progressFile, ([math]::Round($sessionWatch.Elapsed.TotalSeconds, 1)), $encoded, $replaced, $keptOriginal, $encodeFailed)
                }
            }
            else {
                $encoded++
                $tempSize = (Get-Item -LiteralPath $tempOutput).Length

                if ($tempSize -lt $file.Length) {
                    $destOutput = Join-Path $file.DirectoryName $outName
                    try {
                        Remove-Item -LiteralPath $file.FullName -Force
                        Move-Item -LiteralPath $tempOutput -Destination $destOutput -Force
                        $replaced++
                        $spaceSavedBytes += ($file.Length - $tempSize)
                        Write-Host ("Replaced: {0} ({1:N0} -> {2:N0} bytes, saved {3:N0} bytes)" -f $file.Name, $file.Length, $tempSize, ($file.Length - $tempSize))
                    }
                    catch {
                        Write-Warning "Failed to replace source file '$($file.FullName)': $($_.Exception.Message)"
                        $warnings++
                        if (Test-Path -LiteralPath $tempOutput -PathType Leaf) {
                            Remove-Item -LiteralPath $tempOutput -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
                else {
                    Remove-Item -LiteralPath $tempOutput -Force -ErrorAction SilentlyContinue
                    $keptOriginal++
                    Write-Host ("Kept original: {0} (encoded {1:N0} bytes >= source {2:N0} bytes)" -f $file.Name, $tempSize, $file.Length)
                }

                $currentTempFile = $null

                if ($VerboseConsole) {
                    Write-Host ("PROGRESS|tool=vidrecompress|event=update|index={0}|total={1}|file={2}|elapsed_seconds={3}|encoded={4}|replaced={5}|kept_original={6}|encode_failed={7}" -f $fileIndex, $candidateCount, $progressFile, ([math]::Round($sessionWatch.Elapsed.TotalSeconds, 1)), $encoded, $replaced, $keptOriginal, $encodeFailed)
                }
            }
        }

        if ($ranHandBrake) {
            $fileTimings.Add($fileWatch.Elapsed.TotalSeconds)
        }

        $etaStr = "estimating..."
        if ($fileTimings.Count -gt 0) {
            $avgSeconds = ($fileTimings | Measure-Object -Sum).Sum / $fileTimings.Count
            $remaining  = $candidateCount - $fileIndex
            if ($remaining -gt 0) {
                $etaStr = Format-Eta -Seconds ($avgSeconds * $remaining)
            }
            else {
                $etaStr = $null
            }
        }
        $progressStatus = if ($null -ne $etaStr) {
            "$fileIndex/$candidateCount | $($file.BaseName) | ETA $etaStr"
        }
        else {
            "$fileIndex/$candidateCount | $($file.BaseName)"
        }
        $pct = [math]::Min(100, [math]::Round(($fileIndex / $candidateCount) * 100))
        Write-Progress -Activity "vidrecompress" -Status $progressStatus -PercentComplete $pct
    }
}
finally {
    if ($null -ne $currentTempFile -and (Test-Path -LiteralPath $currentTempFile -PathType Leaf)) {
        Remove-Item -LiteralPath $currentTempFile -Force -ErrorAction SilentlyContinue
        Write-Host "Cleaned up partial temp file: $currentTempFile"
    }
}

Write-Progress -Activity "vidrecompress" -Completed

$sessionWatch.Stop()

$status = if ($encodeFailed -gt 0) {
    "failed"
}
elseif ($candidateCount -eq 0 -or ($skippedNoSpace -eq $candidateCount)) {
    "noop"
}
else {
    "ok"
}

$totalSecs = [math]::Round($sessionWatch.Elapsed.TotalSeconds, 1)
$savedMb   = [math]::Round($spaceSavedBytes / 1MB, 1)

Write-Host ""
Write-Host "Recompress run"
Write-Host (" status:            {0}" -f $status)
Write-Host (" total:             {0}s" -f $totalSecs)
Write-Host (" candidates:        {0}" -f $candidateCount)
Write-Host (" skipped_existing:  {0}" -f $skippedExisting)
Write-Host (" encoded:           {0}  failed: {1}" -f $encoded, $encodeFailed)
Write-Host (" replaced:          {0}  kept_original: {1}" -f $replaced, $keptOriginal)
Write-Host (" space_saved:       {0} MB" -f $savedMb)
if ($skippedNoSpace -gt 0) {
    Write-Host (" skipped_no_space:  {0}" -f $skippedNoSpace)
}
if ($warnings -gt 0) {
    Write-Host (" warnings:          {0}" -f $warnings)
}
Write-Host ""
Write-Host ("SUMMARY|tool=vidrecompress|status={0}|dry_run=false|candidates={1}|skipped_existing={2}|skipped_no_space={3}|encoded={4}|encode_failed={5}|replaced={6}|kept_original={7}|space_saved_mb={8}|warnings={9}" -f $status, $candidateCount, $skippedExisting, $skippedNoSpace, $encoded, $encodeFailed, $replaced, $keptOriginal, ([math]::Round($spaceSavedBytes / 1MB, 1)), $warnings)

if ($status -eq "failed") {
    exit 1
}

exit 0
