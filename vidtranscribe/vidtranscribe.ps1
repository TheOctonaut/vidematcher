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
    [switch]$RecheckLanguage,

    [Parameter(Mandatory = $false)]
    [switch]$FixMismatches,

    [Parameter(Mandatory = $false)]
    [switch]$ForceRecheck,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$NoConfirm
)

$ErrorActionPreference = "Stop"

# Bumped whenever the language-probing logic changes materially (e.g. the
# move from percentage sampling to VAD-based windows, or 2-window to
# 3-window majority vote). Stamped into each sidecar's "language" resolution
# so -RecheckLanguage can tell which files were already verified/produced
# under the current logic and skip re-probing them.
$LanguageProbeVersion = 2

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

# ---------------------------------------------------------------------------
# Language probing
# ---------------------------------------------------------------------------
#
# WhisperX only auto-detects language from the raw first 30 seconds of audio,
# before any silence/VAD filtering. Films that open with a silent/no-dialogue
# scene (common for short, visual/artistic pieces) can cause WhisperX to
# confidently detect the wrong language from that window, then transcribe the
# whole file assuming that (wrong) language - which can produce garbled or
# even wrong-script output. To avoid trusting that flawed window, when no
# explicit -Language is set we run a cheap separate pass first: extract a
# short clip from a point in the file that's actually likely to contain
# speech (skipping a detected leading silence), and probe just that clip with
# a small/fast model to get a real language guess before the full transcription
# runs. This is also reused by -RecheckLanguage to audit already-processed
# files without needing to re-transcribe them.

function Get-VideoDurationSeconds {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    $out = & ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -- $FilePath 2>$null
    $seconds = 0.0
    if ($out -and [double]::TryParse(($out | Select-Object -First 1).Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$seconds)) {
        return $seconds
    }
    return $null
}

function Get-VadSpeechSegments {
    # Runs WhisperX's own pyannote-based voice-activity detector (via the
    # standalone vad_probe.py helper) directly against the whole file - much
    # cheaper than a full transcription pass - and returns the speech segments
    # it finds as an array of @{ Start = <seconds>; End = <seconds> }. Used to
    # locate genuine speech-containing windows for language identification,
    # since fixed time offsets (start-of-file, or a fixed percentage into the
    # runtime) are unreliable for content with long wordless stretches
    # (intro music/logos, ambient-only scenes) anywhere in the runtime.
    # Returns $null on any failure.
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$ModelsPath,
        [Parameter(Mandatory = $true)][string]$DockerImage,
        [Parameter(Mandatory = $true)][string]$Device,
        [Parameter(Mandatory = $true)][string]$ScriptRoot
    )

    try {
        $videoDir = Split-Path -Parent $FilePath
        $fileName = Split-Path -Leaf $FilePath

        $vadArgs = @(
            'run', '--rm', '--gpus', 'all', '--entrypoint', 'python',
            '-v', "${ScriptRoot}:/scripts:ro",
            '-v', "${videoDir}:/input:ro",
            '-v', "${ModelsPath}:/models",
            $DockerImage,
            '/scripts/vad_probe.py',
            "/input/$fileName"
        )

        $stdout = & docker @vadArgs 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $stdout) { return $null }

        $jsonLine = $stdout | Select-Object -Last 1
        $parsed = $jsonLine | ConvertFrom-Json
        if ($null -eq $parsed) { return $null }
        return @($parsed | ForEach-Object { [PSCustomObject]@{ Start = [double]$_.start; End = [double]$_.end } })
    }
    catch {
        return $null
    }
}

function Select-SpeechClipWindow {
    # Picks a window of roughly $ClipSeconds actual speech within
    # [$MinStart, $MaxEnd), anchored on the longest single VAD segment in that
    # range and extended forward by merging nearby (small-gap) segments if the
    # anchor alone is shorter than the target length. Returns $null if no
    # speech segments fall within the given range at all.
    param(
        [Parameter(Mandatory = $true)]$Segments,
        [Parameter(Mandatory = $true)][double]$ClipSeconds,
        [Parameter(Mandatory = $true)][double]$MinStart,
        [Parameter(Mandatory = $true)][double]$MaxEnd,
        [double]$MaxGapSeconds = 5
    )

    $inRange = @($Segments | Where-Object { $_.Start -ge $MinStart -and $_.End -le $MaxEnd } | Sort-Object Start)
    if ($inRange.Count -eq 0) { return $null }

    $anchor = $inRange | Sort-Object { $_.End - $_.Start } -Descending | Select-Object -First 1
    $windowStart = $anchor.Start
    $windowEnd = $anchor.End

    foreach ($seg in ($inRange | Where-Object { $_.Start -ge $anchor.Start } | Sort-Object Start)) {
        if (($windowEnd - $windowStart) -ge $ClipSeconds) { break }
        if ($seg.Start -le ($windowEnd + $MaxGapSeconds) -and $seg.End -gt $windowEnd) {
            $windowEnd = $seg.End
        }
    }

    $windowEnd = [Math]::Min($windowEnd, $windowStart + $ClipSeconds)
    return [PSCustomObject]@{ Start = $windowStart; End = $windowEnd }
}

function Get-LanguageForClip {
    # Extracts a short audio clip spanning $OffsetSeconds..($OffsetSeconds +
    # $ClipSeconds) and runs a fast (tiny model, no alignment) WhisperX pass
    # on it, reading the actually-detected language from its
    # "Detected language: <code> (<confidence>)" log line rather than the
    # output JSON's "language" field. WhisperX's own transcribe.py
    # unconditionally overwrites that JSON field with "align_language" right
    # before writing output - which defaults to "en" whenever --language
    # isn't explicitly forced, regardless of what was actually detected - so
    # the JSON field cannot be trusted for auto-detection. --log-level info
    # surfaces that log line without --verbose True's per-segment transcript
    # text (keeps dialogue content out of console/log output). Returns $null
    # on any failure so callers can fall back gracefully.
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][double]$OffsetSeconds,
        [Parameter(Mandatory = $true)][double]$ClipSeconds,
        [Parameter(Mandatory = $true)][string]$ModelsPath,
        [Parameter(Mandatory = $true)][string]$DockerImage,
        [Parameter(Mandatory = $true)][string]$Device,
        [Parameter(Mandatory = $true)][string]$ComputeType
    )

    $probeDir = $null
    try {
        $probeDir = Join-Path $env:TEMP "vidtranscribe_probe_$([guid]::NewGuid().ToString('N'))"
        $probeOutDir = Join-Path $probeDir "out"
        New-Item -ItemType Directory -Path $probeOutDir -Force | Out-Null
        $clipPath = Join-Path $probeDir "clip.wav"

        & ffmpeg -hide_banner -loglevel error -ss $OffsetSeconds -i $FilePath -t $ClipSeconds -vn -ar 16000 -ac 1 -f wav $clipPath 2>$null
        if (-not (Test-Path -LiteralPath $clipPath -PathType Leaf)) { return $null }

        $probeDockerArgs = @(
            'run', '--rm', '--gpus', 'all',
            '-v', "${probeDir}:/input:ro",
            '-v', "${probeOutDir}:/output",
            '-v', "${ModelsPath}:/models",
            $DockerImage,
            '/input/clip.wav',
            '--model', 'tiny',
            '--device', $Device,
            '--compute_type', $ComputeType,
            '--no_align',
            '--output_dir', '/output',
            '--verbose', 'False',
            '--log-level', 'info'
        )

        $probeOutput = & docker @probeDockerArgs 2>&1
        if ($LASTEXITCODE -ne 0) { return $null }

        foreach ($line in $probeOutput) {
            if ($line -match 'Detected language:\s*(\w+)') {
                return $Matches[1]
            }
        }
        return $null
    }
    catch {
        return $null
    }
    finally {
        if ($null -ne $probeDir -and (Test-Path -LiteralPath $probeDir)) {
            Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-ProbedLanguage {
    # WhisperX's own language auto-detection only looks at the raw first ~30s
    # of audio, with no confidence check - and films very often have long
    # wordless stretches (intro music/logos, ambient-only scenes) that aren't
    # limited to the opening. A fixed time offset (even one chosen as a
    # percentage into the runtime) can still land on a stretch with no real
    # dialogue. Instead, this runs WhisperX's own voice-activity detector once
    # across the whole file to find where speech actually is, then probes
    # language in one genuine-speech window from each third of the runtime.
    # Two or three agreeing windows win by majority. A genuine three-way
    # split falls back to English if English was one of the guesses (a fair
    # default for this library, where most short/ambiguous dialogue turns
    # out to be English) - otherwise the caller falls back to WhisperX's
    # normal full-file auto-detection.
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$ModelsPath,
        [Parameter(Mandatory = $true)][string]$DockerImage,
        [Parameter(Mandatory = $true)][string]$Device,
        [Parameter(Mandatory = $true)][string]$ComputeType,
        [Parameter(Mandatory = $true)][string]$ScriptRoot,
        [double]$ClipSeconds = 45
    )

    $duration = Get-VideoDurationSeconds -FilePath $FilePath
    if ($null -eq $duration -or $duration -le 0) {
        return $null
    }

    $segments = Get-VadSpeechSegments -FilePath $FilePath -ModelsPath $ModelsPath -DockerImage $DockerImage -Device $Device -ScriptRoot $ScriptRoot
    if ($null -eq $segments -or $segments.Count -eq 0) {
        Write-Host "No speech detected anywhere in the file via voice-activity detection; cannot probe language."
        return $null
    }

    $third = $duration / 3
    $ranges = @(
        @{ MinStart = 0; MaxEnd = $third },
        @{ MinStart = $third; MaxEnd = 2 * $third },
        @{ MinStart = 2 * $third; MaxEnd = $duration }
    )

    $samples = foreach ($range in $ranges) {
        $window = Select-SpeechClipWindow -Segments $segments -ClipSeconds $ClipSeconds -MinStart $range.MinStart -MaxEnd $range.MaxEnd
        if ($null -eq $window) { continue }
        $lang = Get-LanguageForClip -FilePath $FilePath -OffsetSeconds $window.Start -ClipSeconds ($window.End - $window.Start) -ModelsPath $ModelsPath -DockerImage $DockerImage -Device $Device -ComputeType $ComputeType
        if ($null -eq $lang) { continue }
        [pscustomobject]@{ Start = $window.Start; Language = $lang }
    }

    $samples = @($samples)
    if ($samples.Count -eq 0) { return $null }
    if ($samples.Count -eq 1) { return $samples[0].Language }

    $groups = $samples | Group-Object -Property Language | Sort-Object Count -Descending
    if ($groups[0].Count -ge 2) {
        return $groups[0].Name
    }

    $summary = ($samples | ForEach-Object { "$($_.Start)s=$($_.Language)" }) -join ", "
    if ($samples.Language -contains "en") {
        Write-Host "Language probe split with no majority ($summary); defaulting to English."
        return "en"
    }
    Write-Host "Language probe split with no majority ($summary); deferring to normal auto-detection."
    return $null
}

function Invoke-LanguageRecheck {
    param(
        [Parameter(Mandatory = $true)][object[]]$VideoFiles,
        [Parameter(Mandatory = $true)][int]$MaxFiles,
        [Parameter(Mandatory = $true)][string]$ModelsPath,
        [Parameter(Mandatory = $true)][string]$DockerImage,
        [Parameter(Mandatory = $true)][string]$Device,
        [Parameter(Mandatory = $true)][string]$ComputeType,
        [Parameter(Mandatory = $true)][int]$LanguageProbeVersion,
        [Parameter(Mandatory = $true)][bool]$Fix,
        [Parameter(Mandatory = $true)][bool]$IsDryRun,
        [Parameter(Mandatory = $true)][bool]$IsNoConfirm,
        [switch]$Force
    )

    # Only files this tool itself transcribed have a .vidtranscribe.json
    # sidecar recording the language it originally claimed - that recorded
    # language is what we compare a fresh probe against. Subtitles obtained
    # from elsewhere (no sidecar) aren't in scope for this audit. Files
    # already stamped with the current probe-logic version were produced (or
    # already verified) under today's logic, so they're skipped unless
    # -Force is passed.
    $candidates = New-Object System.Collections.Generic.List[object]
    $alreadyVerified = 0
    foreach ($file in $VideoFiles) {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $jsonPath = Join-Path $file.DirectoryName "$baseName.vidtranscribe.json"
        if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) { continue }

        if (-not $Force) {
            $stampedVersion = $null
            try {
                $existingJson = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
                if ($null -ne $existingJson.vidtranscribe_probe_version) { $stampedVersion = [int]$existingJson.vidtranscribe_probe_version }
            }
            catch { }
            if ($null -ne $stampedVersion -and $stampedVersion -ge $LanguageProbeVersion) {
                $alreadyVerified++
                continue
            }
        }

        $candidates.Add([PSCustomObject]@{ File = $file; BaseName = $baseName; JsonPath = $jsonPath })
    }

    if ($MaxFiles -gt 0 -and $candidates.Count -gt $MaxFiles) {
        $candidates = $candidates.GetRange(0, $MaxFiles)
    }

    Write-Host ""
    if ($alreadyVerified -gt 0) {
        Write-Host "Language recheck: $alreadyVerified file(s) already verified under the current probe logic (v$LanguageProbeVersion) - skipped. Use -ForceRecheck to re-probe them anyway."
    }
    Write-Host "Language recheck: $($candidates.Count) previously-transcribed file(s) to probe."

    if ($candidates.Count -eq 0) {
        Write-Host "SUMMARY|tool=vidtranscribe|status=noop|dry_run=$($IsDryRun.ToString().ToLowerInvariant())|total=$($VideoFiles.Count)|already_verified=$alreadyVerified|checked=0|matched=0|mismatched=0|probe_failed=0"
        return 0
    }

    if ($IsDryRun) {
        Write-Host "Dry run - the following file(s) would be probed:"
        foreach ($c in $candidates) { Write-Host "  $($c.File.FullName)" }
        Write-Host "SUMMARY|tool=vidtranscribe|status=noop|dry_run=true|total=$($VideoFiles.Count)|already_verified=$alreadyVerified|checked=0|matched=0|mismatched=0|probe_failed=0"
        return 0
    }

    if (-not $IsNoConfirm) {
        Write-Host ""
        $verb = if ($Fix) { "probe and fix mismatches for" } else { "probe" }
        $confirm = Read-Host "$($verb.Substring(0,1).ToUpperInvariant())$($verb.Substring(1)) $($candidates.Count) file(s)? This can take a while. (Y/N)"
        if ($confirm -notmatch '^[Yy]') {
            Write-Host "Aborted."
            Write-Host "SUMMARY|tool=vidtranscribe|status=aborted|dry_run=false|total=$($VideoFiles.Count)|already_verified=$alreadyVerified|checked=0|matched=0|mismatched=0|probe_failed=0"
            return 0
        }
    }

    $matched = 0
    $mismatched = 0
    $probeFailed = 0
    $index = 0

    foreach ($c in $candidates) {
        $index++
        $safeName = ConvertTo-ProgressValue $c.File.Name
        Write-Host "PROGRESS|tool=vidtranscribe|event=start|index=$index|total=$($candidates.Count)|file=$safeName"

        $recordedLanguage = $null
        try {
            $existingJson = Get-Content -LiteralPath $c.JsonPath -Raw | ConvertFrom-Json
            if ($null -ne $existingJson.language) { $recordedLanguage = [string]$existingJson.language }
        }
        catch { }

        if ([string]::IsNullOrWhiteSpace($recordedLanguage)) {
            Write-Host "  Skipping (sidecar has no recorded language): $($c.File.FullName)"
            $probeFailed++
            Write-Host "PROGRESS|tool=vidtranscribe|event=complete|index=$index|total=$($candidates.Count)|file=$safeName|failed=true"
            continue
        }

        $probed = Get-ProbedLanguage -FilePath $c.File.FullName -ModelsPath $ModelsPath -DockerImage $DockerImage -Device $Device -ComputeType $ComputeType -ScriptRoot $scriptRoot

        if ($null -eq $probed) {
            Write-Host "  Probe failed: $($c.File.FullName)"
            $probeFailed++
            Write-Host "PROGRESS|tool=vidtranscribe|event=complete|index=$index|total=$($candidates.Count)|file=$safeName|failed=true"
            continue
        }

        if ($probed -eq $recordedLanguage) {
            Write-Host "  OK ($recordedLanguage): $($c.File.FullName)"
            $matched++
            try {
                $existingJson | Add-Member -NotePropertyName 'vidtranscribe_probe_version' -NotePropertyValue $LanguageProbeVersion -Force
                ($existingJson | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $c.JsonPath -NoNewline
            }
            catch {
                Write-Host "    Warning: could not stamp probe version on $($c.JsonPath): $($_.Exception.Message)"
            }
        }
        else {
            $mismatched++
            Write-Host "  MISMATCH: recorded=$recordedLanguage probed=$probed : $($c.File.FullName)"

            if ($Fix) {
                $recordedSrt = Join-Path $c.File.DirectoryName "$($c.BaseName).$recordedLanguage.srt"
                $pathsToRemove = New-Object System.Collections.Generic.List[string]
                if (Test-Path -LiteralPath $recordedSrt -PathType Leaf) { $pathsToRemove.Add($recordedSrt) }
                $pathsToRemove.Add($c.JsonPath)
                if ($recordedLanguage -ne "en") {
                    $translatedSrt = Join-Path $c.File.DirectoryName "$($c.BaseName).en.srt"
                    if (Test-Path -LiteralPath $translatedSrt -PathType Leaf) { $pathsToRemove.Add($translatedSrt) }
                }

                foreach ($p in $pathsToRemove) {
                    Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
                    Write-Host "    Removed: $p"
                }
                Write-Host "    File will be re-transcribed on the next normal vidtranscribe run."
            }
        }

        Write-Host "PROGRESS|tool=vidtranscribe|event=complete|index=$index|total=$($candidates.Count)|file=$safeName"
    }

    Write-Host ""
    Write-Host "Done."
    $status = if ($probeFailed -gt 0) { "failed" } else { "ok" }
    Write-Host "SUMMARY|tool=vidtranscribe|status=$status|dry_run=false|total=$($VideoFiles.Count)|already_verified=$alreadyVerified|checked=$($candidates.Count)|matched=$matched|mismatched=$mismatched|probe_failed=$probeFailed"

    if ($status -eq "failed") { return 1 }
    return 0
}

if ($RecheckLanguage) {
    $exitCode = Invoke-LanguageRecheck -VideoFiles $videoFiles -MaxFiles $resolvedMaxFiles -ModelsPath $resolvedModelsPath -DockerImage $resolvedDockerImage -Device $resolvedDevice -ComputeType $resolvedComputeType -LanguageProbeVersion $LanguageProbeVersion -Fix:$FixMismatches.IsPresent -IsDryRun:$DryRun.IsPresent -IsNoConfirm:$NoConfirm.IsPresent -Force:$ForceRecheck.IsPresent
    exit $exitCode
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

        $languageForRun = $resolvedLanguage
        if ([string]::IsNullOrWhiteSpace($languageForRun)) {
            Write-Host "Probing language via voice-activity detection to find genuine speech..."
            $probedLanguage = Get-ProbedLanguage -FilePath $file.FullName -ModelsPath $resolvedModelsPath -DockerImage $resolvedDockerImage -Device $resolvedDevice -ComputeType $resolvedComputeType -ScriptRoot $scriptRoot
            if ($null -ne $probedLanguage) {
                Write-Host "Probed language: $probedLanguage"
                $languageForRun = $probedLanguage
            }
            else {
                Write-Host "Language probe failed; falling back to the main model's own auto-detection."
            }
        }

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
                '--verbose', 'False',
                '--log-level', 'info'
            )
            if (-not [string]::IsNullOrWhiteSpace($languageForRun)) {
                $dockerArgs += @('--language', $languageForRun)
            }

            $previousErrorActionPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            $dockerOutputLines = [System.Collections.Generic.List[string]]::new()
            try {
                & docker @dockerArgs 2>&1 | ForEach-Object { Write-Host $_; $dockerOutputLines.Add([string]$_) }
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

                    # WhisperX's transcribe.py unconditionally overwrites the output
                    # JSON's "language" field with its internal "align_language"
                    # value right before writing - which defaults to "en" whenever
                    # --language wasn't explicitly passed, regardless of what was
                    # actually detected. So when no language was forced, the true
                    # detected language is only recoverable from the "Detected
                    # language: <code> (<confidence>)" log line (unaffected by
                    # --verbose) rather than the JSON field.
                    $loggedLanguage = $null
                    if ([string]::IsNullOrWhiteSpace($languageForRun)) {
                        foreach ($line in $dockerOutputLines) {
                            if ($line -match 'Detected language:\s*(\w+)') {
                                $loggedLanguage = $Matches[1]
                                break
                            }
                        }
                    }

                    $detectedLanguage = if (-not [string]::IsNullOrWhiteSpace($languageForRun)) {
                        $languageForRun
                    }
                    elseif (-not [string]::IsNullOrWhiteSpace($loggedLanguage)) {
                        $loggedLanguage
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
                        # WhisperX's own output JSON has its "language" field
                        # unconditionally overwritten to its "en" default whenever
                        # no --language was forced (see comment above). Correct it
                        # here so the sidecar we keep long-term reflects the real
                        # detected language, not that artifact. Also stamp the
                        # probe-logic version so a future -RecheckLanguage run can
                        # tell this file was already produced/verified under the
                        # current logic and skip re-probing it.
                        $jsonObj | Add-Member -NotePropertyName 'language' -NotePropertyValue $detectedLanguage -Force
                        $jsonObj | Add-Member -NotePropertyName 'vidtranscribe_probe_version' -NotePropertyValue $LanguageProbeVersion -Force
                        ($jsonObj | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $jsonTemp -NoNewline
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
