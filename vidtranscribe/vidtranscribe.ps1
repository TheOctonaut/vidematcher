param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    [Parameter(Mandatory = $false)]
    [string]$Language,

    [Parameter(Mandatory = $false)]
    [string]$Model,

    [Parameter(Mandatory = $false)]
    [string]$ComputeType,

    [Parameter(Mandatory = $false)]
    [string]$Device,

    [Parameter(Mandatory = $false)]
    [string]$DockerImage,

    [Parameter(Mandatory = $false)]
    [string]$ModelsPath,

    [Parameter(Mandatory = $false)]
    [int]$MaxFiles,

    [Parameter(Mandatory = $false)]
    [switch]$NoTranslate,

    [Parameter(Mandatory = $false)]
    [string]$OptionsFile,

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

$optionsFileExplicit = -not [string]::IsNullOrWhiteSpace($OptionsFile)
if (-not $optionsFileExplicit) {
    $OptionsFile = Join-Path $scriptRoot "options.json"
}

$exampleOptionsFileName = "options.json.example"
$exampleOptionsFile = Join-Path $scriptRoot $exampleOptionsFileName

function Get-OptionValue {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Options,
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

function ConvertTo-ProgressValue {
    param([string]$Value)

    if ($null -eq $Value) { return "" }
    return (($Value -replace "\|", "/") -replace "\r?\n", " ")
}

$defaults = [PSCustomObject]@{
    DockerImage = "vidtranscribe:latest"
    Model       = "turbo"
    ComputeType = "float16"
    Device      = "cuda"
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
                Write-Host "Edit $OptionsFile to set ModelsPath, then re-run."
                exit 0
            }
            else {
                throw "Template file not found: $exampleOptionsFile"
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

$resolvedModelsPath = if ($PSBoundParameters.ContainsKey("ModelsPath")) {
    $ModelsPath
}
else {
    Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "ModelsPath")
}

$resolvedDockerImage = if ($PSBoundParameters.ContainsKey("DockerImage")) {
    $DockerImage
}
else {
    $v = Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "DockerImage")
    if ($null -ne $v) { $v } else { $defaults.DockerImage }
}

$resolvedModel = if ($PSBoundParameters.ContainsKey("Model")) {
    $Model
}
else {
    $v = Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "Model")
    if ($null -ne $v) { $v } else { $defaults.Model }
}

$resolvedComputeType = if ($PSBoundParameters.ContainsKey("ComputeType")) {
    $ComputeType
}
else {
    $v = Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "ComputeType")
    if ($null -ne $v) { $v } else { $defaults.ComputeType }
}

$resolvedDevice = if ($PSBoundParameters.ContainsKey("Device")) {
    $Device
}
else {
    $v = Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "Device")
    if ($null -ne $v) { $v } else { $defaults.Device }
}

$resolvedLanguage = if ($PSBoundParameters.ContainsKey("Language")) {
    Normalize-OptionalString $Language
}
else {
    Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "Language")
}

$resolvedMaxFiles = if ($PSBoundParameters.ContainsKey("MaxFiles")) {
    $MaxFiles
}
else {
    $v = Get-OptionValue -Options $fileOptions -Name "MaxFiles"
    if ($null -ne $v -and [string]$v -match '^\d+$') { [int]$v } else { 0 }
}

if ($resolvedMaxFiles -lt 0) {
    throw "MaxFiles must be zero (no limit) or a positive number."
}

$resolvedAutoTranslate = if ($NoTranslate) {
    $false
}
else {
    $v = Get-OptionValue -Options $fileOptions -Name "AutoTranslate"
    if ($null -ne $v) { [bool]$v } else { $true }
}

if ([string]::IsNullOrWhiteSpace($resolvedModelsPath)) {
    throw "ModelsPath is required. Provide -ModelsPath or set ModelsPath in options.json."
}

if (-not (Test-Path -LiteralPath $Path)) {
    throw "Path not found: $Path"
}

$resolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath
$pathItem = Get-Item -LiteralPath $resolvedPath

$videoFiles = @()
if ($pathItem.PSIsContainer) {
    $videoFiles = @(Get-ChildItem -LiteralPath $resolvedPath -Filter "*.mp4" -File)
}
else {
    if ($pathItem.Extension -ne ".mp4") {
        throw "Path is not an .mp4 file: $resolvedPath"
    }
    $videoFiles = @($pathItem)
}

if ($videoFiles.Count -eq 0) {
    Write-Host "No .mp4 files found at: $resolvedPath"
    Write-Host "SUMMARY|tool=vidtranscribe|status=noop|dry_run=$($DryRun.IsPresent.ToString().ToLowerInvariant())|total=0|to_process=0|skipped=0|processed=0|translated_only=0|failed=0"
    exit 0
}

function Get-SubtitleStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$BaseName
    )

    $escaped = [regex]::Escape($BaseName)
    $taggedPattern = "^$escaped\.([A-Za-z]{2,3})\.srt$"
    $untaggedPattern = "^$escaped\.srt$"
    $existing = Get-ChildItem -LiteralPath $Directory -File -Filter "$BaseName*.srt" -ErrorAction SilentlyContinue

    $hasEnglish = $false
    $hasUntagged = $false
    $otherLanguage = $null

    foreach ($item in $existing) {
        if ($item.Name -match $taggedPattern) {
            $lang = $Matches[1].ToLowerInvariant()
            if ($lang -eq "en") { $hasEnglish = $true }
            elseif ($null -eq $otherLanguage) { $otherLanguage = $lang }
        }
        elseif ($item.Name -match $untaggedPattern) {
            $hasUntagged = $true
        }
    }

    if ($hasEnglish) { return [PSCustomObject]@{ Status = "HasEnglish"; Language = $null } }
    if ($hasUntagged) { return [PSCustomObject]@{ Status = "HasUntagged"; Language = $null } }
    if ($null -ne $otherLanguage) { return [PSCustomObject]@{ Status = "HasOtherLanguage"; Language = $otherLanguage } }
    return [PSCustomObject]@{ Status = "None"; Language = $null }
}

$toProcess = New-Object System.Collections.Generic.List[object]
$skipped = 0
$scanned = 0
$stoppedEarly = $false

foreach ($file in $videoFiles) {
    $scanned++
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $subStatus = Get-SubtitleStatus -Directory $file.DirectoryName -BaseName $baseName

    $item = $null
    switch ($subStatus.Status) {
        "HasEnglish" {
            Write-Host "Skipping (English subtitle already exists): $($file.FullName)"
            $skipped++
        }
        "HasUntagged" {
            Write-Host "Skipping (existing subtitle has no language tag, can't tell if translation is needed): $($file.FullName)"
            $skipped++
        }
        "HasOtherLanguage" {
            if ($resolvedAutoTranslate) {
                $item = [PSCustomObject]@{ File = $file; Mode = "TranslateOnly"; Language = $subStatus.Language }
            }
            else {
                Write-Host "Skipping ($($subStatus.Language) subtitle exists, AutoTranslate disabled): $($file.FullName)"
                $skipped++
            }
        }
        "None" {
            $item = [PSCustomObject]@{ File = $file; Mode = "Transcribe"; Language = $null }
        }
    }

    if ($null -ne $item) {
        $toProcess.Add($item)
    }

    if ($resolvedMaxFiles -gt 0 -and $toProcess.Count -ge $resolvedMaxFiles) {
        $stoppedEarly = ($scanned -lt $videoFiles.Count)
        break
    }
}

$total = $videoFiles.Count

Write-Host ""
if ($stoppedEarly) {
    Write-Host "Found $total .mp4 file(s) total; scanned $scanned before reaching the -MaxFiles limit of $resolvedMaxFiles ($skipped already had subtitles). $($total - $scanned) file(s) not yet scanned."
}
else {
    Write-Host "Found $total .mp4 file(s): $($toProcess.Count) to process, $skipped already have subtitles."
}

if ($toProcess.Count -eq 0) {
    Write-Host "SUMMARY|tool=vidtranscribe|status=noop|dry_run=$($DryRun.IsPresent.ToString().ToLowerInvariant())|total=$total|to_process=0|skipped=$skipped|processed=0|translated_only=0|failed=0"
    exit 0
}

if ($DryRun) {
    Write-Host ""
    Write-Host "Dry run - the following file(s) would be processed:"
    foreach ($item in $toProcess) {
        if ($item.Mode -eq "TranslateOnly") {
            Write-Host "  $($item.File.FullName)  [translate existing $($item.Language) subtitle to English only]"
        }
        else {
            Write-Host "  $($item.File.FullName)"
        }
    }
    Write-Host "SUMMARY|tool=vidtranscribe|status=noop|dry_run=true|total=$total|to_process=$($toProcess.Count)|skipped=$skipped|processed=0|translated_only=0|failed=0"
    exit 0
}

if (-not $NoConfirm) {
    Write-Host ""
    $confirm = Read-Host "Transcribe $($toProcess.Count) file(s)? This can take a long time. (Y/N)"
    if ($confirm -notmatch '^[Yy]') {
        Write-Host "Aborted."
        Write-Host "SUMMARY|tool=vidtranscribe|status=aborted|dry_run=false|total=$total|to_process=$($toProcess.Count)|skipped=$skipped|processed=0|translated_only=0|failed=0"
        exit 0
    }
}

try {
    & docker version --format '{{.Server.Version}}' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Docker daemon not reachable."
    }
}
catch {
    Write-Host "Docker does not appear to be available. Is Docker Desktop running? ($($_.Exception.Message))"
    Write-Host "SUMMARY|tool=vidtranscribe|status=aborted|dry_run=false|total=$total|to_process=$($toProcess.Count)|skipped=$skipped|processed=0|translated_only=0|failed=0"
    exit 1
}

& docker image inspect $resolvedDockerImage 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Docker image not found: $resolvedDockerImage"
    Write-Host "Build it first with build-vidtranscribe.ps1 in this folder."
    Write-Host "SUMMARY|tool=vidtranscribe|status=aborted|dry_run=false|total=$total|to_process=$($toProcess.Count)|skipped=$skipped|processed=0|translated_only=0|failed=0"
    exit 1
}

New-Item -ItemType Directory -Path $resolvedModelsPath -Force | Out-Null

$processed = 0
$translatedOnlyCount = 0
$failed = 0
$index = 0

foreach ($item in $toProcess) {
    $index++
    $file = $item.File
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $videoDir = $file.DirectoryName
    $safeName = ConvertTo-ProgressValue $file.Name

    Write-Host ""

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $success = $false
    $detectedLanguage = $null
    $translated = $false

    if ($item.Mode -eq "TranslateOnly") {
        # A source-language subtitle already exists from a previous run (before auto-translate
        # existed, or from a run with AutoTranslate disabled). Skip re-transcribing and only
        # attempt to add the missing English translation.
        $detectedLanguage = $item.Language
        Write-Host "PROGRESS|tool=vidtranscribe|event=start|index=$index|total=$($toProcess.Count)|file=$safeName|mode=translate_only|source_language=$detectedLanguage"
        $success = $true
    }
    else {
        Write-Host "PROGRESS|tool=vidtranscribe|event=start|index=$index|total=$($toProcess.Count)|file=$safeName"

        $tempOutDir = Join-Path $env:TEMP "vidtranscribe_$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $tempOutDir -Force | Out-Null

        try {
            $dockerArgs = @(
                'run', '--rm', '--gpus', 'all',
                '-v', "${videoDir}:/input:ro",
                '-v', "${tempOutDir}:/output",
                '-v', "${resolvedModelsPath}:/models"
            )
            if (-not [string]::IsNullOrWhiteSpace($env:HF_TOKEN)) {
                $dockerArgs += @('-e', "HF_TOKEN=$($env:HF_TOKEN)")
            }
            $dockerArgs += @(
                $resolvedDockerImage,
                "/input/$($file.Name)",
                '--model', $resolvedModel,
                '--device', $resolvedDevice,
                '--compute_type', $resolvedComputeType,
                '--output_dir', '/output',
                '--verbose', 'False'
            )
            if (-not [string]::IsNullOrWhiteSpace($resolvedLanguage)) {
                $dockerArgs += @('--language', $resolvedLanguage)
            }

            $previousErrorActionPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & docker @dockerArgs 2>&1 | ForEach-Object { Write-Host $_ }
            }
            finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) {
                Write-Host "Transcription failed for $($file.FullName) (docker exit code $exitCode)."
            }
            else {
                $jsonTemp = Join-Path $tempOutDir "$baseName.json"
                $srtTemp = Join-Path $tempOutDir "$baseName.srt"

                if (-not (Test-Path -LiteralPath $jsonTemp -PathType Leaf) -or -not (Test-Path -LiteralPath $srtTemp -PathType Leaf)) {
                    Write-Host "Expected output files not found for $($file.FullName)."
                }
                else {
                    $jsonObj = Get-Content -LiteralPath $jsonTemp -Raw | ConvertFrom-Json
                    $detectedLanguage = if (-not [string]::IsNullOrWhiteSpace($resolvedLanguage)) {
                        $resolvedLanguage
                    }
                    elseif ($null -ne $jsonObj.language -and -not [string]::IsNullOrWhiteSpace([string]$jsonObj.language)) {
                        [string]$jsonObj.language
                    }
                    else {
                        "und"
                    }

                    $destSrt = Join-Path $videoDir "$baseName.$detectedLanguage.srt"
                    $destJson = Join-Path $videoDir "$baseName.vidtranscribe.json"

                    if ((Test-Path -LiteralPath $destSrt) -or (Test-Path -LiteralPath $destJson)) {
                        Write-Host "Destination already exists, not overwriting: $destSrt / $destJson"
                    }
                    else {
                        Move-Item -LiteralPath $srtTemp -Destination $destSrt
                        Move-Item -LiteralPath $jsonTemp -Destination $destJson
                        $success = $true
                    }
                }
            }
        }
        catch {
            Write-Host "Error processing $($file.FullName): $($_.Exception.Message)"
        }
        finally {
            Remove-Item -LiteralPath $tempOutDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($success -and $resolvedAutoTranslate -and $detectedLanguage -ne "en" -and $detectedLanguage -ne "und") {
        $destEnSrt = Join-Path $videoDir "$baseName.en.srt"

        if (Test-Path -LiteralPath $destEnSrt) {
            Write-Host "English subtitle already exists, skipping translation: $destEnSrt"
        }
        else {
            Write-Host "PROGRESS|tool=vidtranscribe|event=translate_start|index=$index|total=$($toProcess.Count)|file=$safeName|source_language=$detectedLanguage"

            $tempTranslateDir = Join-Path $env:TEMP "vidtranscribe_translate_$([guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $tempTranslateDir -Force | Out-Null

            try {
                $translateArgs = @(
                    'run', '--rm', '--gpus', 'all',
                    '-v', "${videoDir}:/input:ro",
                    '-v', "${tempTranslateDir}:/output",
                    '-v', "${resolvedModelsPath}:/models"
                )
                if (-not [string]::IsNullOrWhiteSpace($env:HF_TOKEN)) {
                    $translateArgs += @('-e', "HF_TOKEN=$($env:HF_TOKEN)")
                }
                $translateArgs += @(
                    $resolvedDockerImage,
                    "/input/$($file.Name)",
                    '--task', 'translate',
                    '--language', $detectedLanguage,
                    '--model', $resolvedModel,
                    '--device', $resolvedDevice,
                    '--compute_type', $resolvedComputeType,
                    '--output_dir', '/output',
                    '--verbose', 'False'
                )

                $previousErrorActionPreference = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try {
                    & docker @translateArgs 2>&1 | ForEach-Object { Write-Host $_ }
                }
                finally {
                    $ErrorActionPreference = $previousErrorActionPreference
                }
                $translateExitCode = $LASTEXITCODE

                if ($translateExitCode -ne 0) {
                    Write-Host "Translation to English failed for $($file.FullName) (docker exit code $translateExitCode)."
                }
                else {
                    $srtTranslateTemp = Join-Path $tempTranslateDir "$baseName.srt"

                    if (-not (Test-Path -LiteralPath $srtTranslateTemp -PathType Leaf)) {
                        Write-Host "Expected translated subtitle not found for $($file.FullName)."
                    }
                    elseif (Test-Path -LiteralPath $destEnSrt) {
                        Write-Host "Destination already exists, not overwriting: $destEnSrt"
                    }
                    else {
                        Move-Item -LiteralPath $srtTranslateTemp -Destination $destEnSrt
                        $translated = $true
                    }
                }
            }
            catch {
                Write-Host "Error translating $($file.FullName) to English: $($_.Exception.Message)"
            }
            finally {
                Remove-Item -LiteralPath $tempTranslateDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $stopwatch.Stop()
    $elapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)

    if ($success) {
        if ($item.Mode -eq "TranslateOnly") {
            $translatedOnlyCount++
        }
        else {
            $processed++
        }
        Write-Host "PROGRESS|tool=vidtranscribe|event=complete|index=$index|total=$($toProcess.Count)|file=$safeName|elapsed_seconds=$elapsedSeconds|language=$detectedLanguage|translated=$($translated.ToString().ToLowerInvariant())"
    }
    else {
        $failed++
        Write-Host "PROGRESS|tool=vidtranscribe|event=complete|index=$index|total=$($toProcess.Count)|file=$safeName|elapsed_seconds=$elapsedSeconds|failed=true"
    }
}

$status = if ($failed -gt 0) { "failed" } else { "ok" }

Write-Host ""
Write-Host "Done."
Write-Host "SUMMARY|tool=vidtranscribe|status=$status|dry_run=false|total=$total|to_process=$($toProcess.Count)|skipped=$skipped|processed=$processed|translated_only=$translatedOnlyCount|failed=$failed"

if ($status -eq "failed") {
    exit 1
}

exit 0
