param(
    [Parameter(Mandatory = $false)]
    [string]$StagingDir,

    [Parameter(Mandatory = $false)]
    [string]$HandbrakeDir,

    [Parameter(Mandatory = $false)]
    [string]$FinalDir,

    [Parameter(Mandatory = $false)]
    [string]$OptionsFile,

    [Parameter(Mandatory = $false)]
    [string]$VidpickerScript,

    [Parameter(Mandatory = $false)]
    [string]$VidmatchScript,

    [Parameter(Mandatory = $false)]
    [string]$VidencodeScript,

    [Parameter(Mandatory = $false)]
    [switch]$SkipPick,

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

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Escape-Argument {
    param([Parameter(Mandatory = $true)][string]$Value)
    return '"' + $Value.Replace('"', '""') + '"'
}

function Get-PowerShellExe {
    $pwsh = Get-Command "pwsh" -ErrorAction SilentlyContinue
    if ($null -ne $pwsh) { return $pwsh.Source }
    return "powershell"
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

function Get-NormalizedBaseName {
    param([Parameter(Mandatory = $true)][string]$Name)
    return $Name.ToLowerInvariant()
}

function Invoke-ToolScript {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $Exe
    $psi.Arguments              = $Arguments -join " "
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    Write-Host ""
    Write-Host "--- [$Label] ---"
    [void]$proc.Start()

    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    $nl = [Environment]::NewLine
    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        Write-Host ($stdout.TrimEnd() -replace "\r?\n", $nl)
    }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        Write-Warning ($stderr.TrimEnd() -replace "\r?\n", $nl)
    }

    $summaryLine = ($stdout -split "\r?\n") |
        Where-Object { $_.StartsWith("SUMMARY|") } |
        Select-Object -Last 1

    return [PSCustomObject]@{
        ExitCode = $proc.ExitCode
        Summary  = $summaryLine
        Stdout   = $stdout
    }
}

function Get-SummaryField {
    param(
        [Parameter(Mandatory = $true)][string]$Summary,
        [Parameter(Mandatory = $true)][string]$Field
    )
    $pattern = "(?:^|\|)" + [regex]::Escape($Field) + "=([^|]*)"
    if ($Summary -match $pattern) { return $Matches[1] }
    return $null
}

function Invoke-HandbrakeFinalReconcile {
    param(
        [Parameter(Mandatory = $true)][string]$HandbrakeDir,
        [Parameter(Mandatory = $true)][string]$FinalDir,
        [Parameter(Mandatory = $true)][bool]$IsDryRun
    )

    $videoExtensions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ext in @(".avi", ".mp4", ".mkv")) {
        [void]$videoExtensions.Add($ext)
    }

    $handbrakeFiles = Get-ChildItem -LiteralPath $HandbrakeDir -File -Recurse |
        Where-Object { $videoExtensions.Contains(($_.Extension).ToLowerInvariant()) }
    $finalFiles = Get-ChildItem -LiteralPath $FinalDir -File -Recurse |
        Where-Object { $videoExtensions.Contains(($_.Extension).ToLowerInvariant()) }

    $finalByBase = @{}
    foreach ($f in $finalFiles) {
        $base = Get-NormalizedBaseName -Name $f.BaseName
        if (-not $finalByBase.ContainsKey($base)) {
            $finalByBase[$base] = New-Object System.Collections.Generic.List[System.IO.FileInfo]
        }
        $finalByBase[$base].Add($f)
    }

    $inspected = 0
    $replacedInflated = 0
    $deletedFinalInflated = 0
    $deletedHandbrakeSmallerFinal = 0
    $keptEqual = 0
    $missingFinalMatch = 0
    $cleanupErrors = 0

    Write-Host ""
    if ($IsDryRun) {
        Write-Host "--- [post-encode reconcile] [DRY RUN] ---"
    }
    else {
        Write-Host "--- [post-encode reconcile] ---"
    }

    foreach ($hb in $handbrakeFiles) {
        $inspected++
        $base = Get-NormalizedBaseName -Name $hb.BaseName

        if (-not $finalByBase.ContainsKey($base) -or $finalByBase[$base].Count -eq 0) {
            $missingFinalMatch++
            continue
        }

        $matches = @($finalByBase[$base])
        $smallestFinal = $matches | Sort-Object Length | Select-Object -First 1

        if ($smallestFinal.Length -gt $hb.Length) {
            if ($IsDryRun) {
                Write-Host ("[NOISY][DRY RUN] Inflated final detected for '{0}': smallest final={1} bytes, handbrake source={2} bytes. Would replace final with untouched source and remove source from handbrake." -f $hb.Name, $smallestFinal.Length, $hb.Length)
                $replacedInflated++
                $deletedFinalInflated += $matches.Count
                continue
            }

            Write-Warning ("[NOISY] Inflated final detected for '{0}': smallest final={1} bytes, handbrake source={2} bytes. Replacing final with untouched source." -f $hb.Name, $smallestFinal.Length, $hb.Length)

            $deleteOk = $true
            foreach ($m in $matches) {
                try {
                    Remove-Item -LiteralPath $m.FullName -Force
                    $deletedFinalInflated++
                    Write-Warning ("[NOISY] Removed inflated final file: {0}" -f $m.FullName)
                }
                catch {
                    $cleanupErrors++
                    $deleteOk = $false
                    Write-Warning ("Failed to remove inflated final file '{0}': {1}" -f $m.FullName, $_.Exception.Message)
                }
            }

            if ($deleteOk) {
                try {
                    $replacementPath = Join-Path $FinalDir $hb.Name
                    Move-Item -LiteralPath $hb.FullName -Destination $replacementPath -Force
                    Write-Warning ("[NOISY] Replaced final with untouched source and removed handbrake copy: {0}" -f $replacementPath)
                    $replacedInflated++
                }
                catch {
                    $cleanupErrors++
                    Write-Warning ("Failed to move replacement source '{0}' into final: {1}" -f $hb.FullName, $_.Exception.Message)
                }
            }

            continue
        }

        if ($smallestFinal.Length -lt $hb.Length) {
            if ($IsDryRun) {
                Write-Host ("[DRY RUN] Final is smaller for '{0}' (final={1}, handbrake={2}). Would delete from handbrake." -f $hb.Name, $smallestFinal.Length, $hb.Length)
                $deletedHandbrakeSmallerFinal++
                continue
            }

            try {
                Remove-Item -LiteralPath $hb.FullName -Force
                Write-Host ("Deleted handbrake source after verified smaller final: {0}" -f $hb.FullName)
                $deletedHandbrakeSmallerFinal++
            }
            catch {
                $cleanupErrors++
                Write-Warning ("Failed to delete handbrake source '{0}': {1}" -f $hb.FullName, $_.Exception.Message)
            }

            continue
        }

        $keptEqual++
    }

    return [PSCustomObject]@{
        inspected = $inspected
        replaced_inflated = $replacedInflated
        deleted_final_inflated = $deletedFinalInflated
        deleted_handbrake_smaller_final = $deletedHandbrakeSmallerFinal
        kept_equal = $keptEqual
        missing_final_match = $missingFinalMatch
        cleanup_errors = $cleanupErrors
    }
}

# ---------------------------------------------------------------------------
# Options file
# ---------------------------------------------------------------------------

$exampleOptionsFile = Join-Path $scriptRoot $exampleOptionsFileName

if (-not (Test-Path -LiteralPath $OptionsFile -PathType Leaf)) {
    Write-Host "Options file not found: $OptionsFile"
    $response = Read-Host "Create it now? (Y/N)"

    if ($response -match '^[Yy]') {
        if (Test-Path -LiteralPath $exampleOptionsFile -PathType Leaf) {
            Copy-Item -LiteralPath $exampleOptionsFile -Destination $OptionsFile -Force
            Write-Host "Created options file from template: $OptionsFile"
            Write-Host "Edit it to set your StagingDir, HandbrakeDir, and FinalDir, then re-run."
        }
        else {
            $stub = [ordered]@{
                StagingDir      = "C:/path/to/staging"
                HandbrakeDir    = "C:/path/to/handbrake"
                FinalDir        = "C:/path/to/final"
            }
            $stub | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OptionsFile -Encoding UTF8
            Write-Host "Created options file: $OptionsFile"
            Write-Host "Edit it to set your directories, then re-run."
        }
        Write-Host "SUMMARY|tool=viddispatch|status=aborted|dry_run=false|skip_pick=false|note=options_file_created"
        exit 0
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

# ---------------------------------------------------------------------------
# Resolve settings (CLI > options file)
# ---------------------------------------------------------------------------

$resolvedStagingDir = if ($PSBoundParameters.ContainsKey("StagingDir")) {
    $StagingDir
} else {
    Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "StagingDir")
}

$resolvedHandbrakeDir = if ($PSBoundParameters.ContainsKey("HandbrakeDir")) {
    $HandbrakeDir
} else {
    Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "HandbrakeDir")
}

$resolvedFinalDir = if ($PSBoundParameters.ContainsKey("FinalDir")) {
    $FinalDir
} else {
    Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "FinalDir")
}

$resolvedVidpickerScript = if ($PSBoundParameters.ContainsKey("VidpickerScript")) {
    $VidpickerScript
} else {
    Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "VidpickerScript")
}

$resolvedVidmatchScript = if ($PSBoundParameters.ContainsKey("VidmatchScript")) {
    $VidmatchScript
} else {
    Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "VidmatchScript")
}

$resolvedVidencodeScript = if ($PSBoundParameters.ContainsKey("VidencodeScript")) {
    $VidencodeScript
} else {
    Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "VidencodeScript")
}

# Default tool script paths: siblings of the dispatcher's parent folder
$repoRoot = Split-Path -Parent $scriptRoot

if ([string]::IsNullOrWhiteSpace($resolvedVidpickerScript)) {
    $resolvedVidpickerScript = Join-Path $repoRoot "vidpicker\vidpicker.ps1"
}
if ([string]::IsNullOrWhiteSpace($resolvedVidmatchScript)) {
    $resolvedVidmatchScript = Join-Path $repoRoot "vidmatch\vidmatch.ps1"
}
if ([string]::IsNullOrWhiteSpace($resolvedVidencodeScript)) {
    $resolvedVidencodeScript = Join-Path $repoRoot "videncode\videncode.ps1"
}

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------

if (-not $SkipPick -and [string]::IsNullOrWhiteSpace($resolvedStagingDir)) {
    throw "StagingDir is required when -SkipPick is not set. Provide -StagingDir or set it in options.json."
}

if ([string]::IsNullOrWhiteSpace($resolvedHandbrakeDir)) {
    throw "HandbrakeDir is required. Provide -HandbrakeDir or set it in options.json."
}

if ([string]::IsNullOrWhiteSpace($resolvedFinalDir)) {
    throw "FinalDir is required. Provide -FinalDir or set it in options.json."
}

foreach ($entry in @(
    @{ Name = "VidpickerScript"; Path = $resolvedVidpickerScript },
    @{ Name = "VidmatchScript";  Path = $resolvedVidmatchScript  },
    @{ Name = "VidencodeScript"; Path = $resolvedVidencodeScript  }
)) {
    if (-not (Test-Path -LiteralPath $entry.Path -PathType Leaf)) {
        throw "$($entry.Name) not found: $($entry.Path)"
    }
}

if (-not $SkipPick -and -not (Test-Path -LiteralPath $resolvedStagingDir -PathType Container)) {
    throw "StagingDir does not exist: $resolvedStagingDir"
}
if (-not (Test-Path -LiteralPath $resolvedHandbrakeDir -PathType Container)) {
    throw "HandbrakeDir does not exist: $resolvedHandbrakeDir"
}
if (-not (Test-Path -LiteralPath $resolvedFinalDir -PathType Container)) {
    throw "FinalDir does not exist: $resolvedFinalDir"
}

# ---------------------------------------------------------------------------
# Summary header
# ---------------------------------------------------------------------------

$dryRunFlag  = if ($DryRun.IsPresent)   { "true" } else { "false" }
$skipPickFlag = if ($SkipPick.IsPresent) { "true" } else { "false" }

Write-Host "viddispatch starting"
if (-not $SkipPick) { Write-Host "  StagingDir:   $resolvedStagingDir" }
Write-Host "  HandbrakeDir: $resolvedHandbrakeDir"
Write-Host "  FinalDir:     $resolvedFinalDir"
if ($DryRun)   { Write-Host "  [DRY RUN]" }
if ($SkipPick) { Write-Host "  [SKIP PICK]" }

if (-not $DryRun -and -not $NoConfirm) {
    Write-Host ""
    Write-Host "This will run pick -> match -> encode -> reconcile cleanup."
    $dispatchConfirm = Read-Host "Proceed? (Y/N)"
    if ($dispatchConfirm -notmatch '^[Yy]') {
        Write-Host "Aborted."
        Write-Host "SUMMARY|tool=viddispatch|status=aborted|dry_run=false|skip_pick=$skipPickFlag|note=user_aborted"
        exit 0
    }
}

$psExe = Get-PowerShellExe

$dispatchPickedCount = 0
$dispatchEncoded = 0
$dispatchEncodeFailed = 0
$dispatchMoved = 0
$dispatchMoveFailed = 0

# ---------------------------------------------------------------------------
# PREFLIGHT: validate encode dependencies before any destructive steps
# ---------------------------------------------------------------------------

$preflightArgs = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
    (Escape-Argument -Value $resolvedVidencodeScript),
    "-SourceDir", (Escape-Argument -Value $resolvedHandbrakeDir),
    "-DestDir",   (Escape-Argument -Value $resolvedFinalDir),
    "-InputFiles", (Escape-Argument -Value "__viddispatch_preflight__.avi"),
    "-DryRun",
    "-NoConfirm"
)

$preflightResult = Invoke-ToolScript -Label "preflight: videncode" -Exe $psExe -Arguments $preflightArgs
if ($preflightResult.ExitCode -ne 0) {
    Write-Warning "Preflight failed (videncode dependencies/config). Stopping before file moves."
    Write-Host "SUMMARY|tool=viddispatch|status=failed|dry_run=$dryRunFlag|skip_pick=$skipPickFlag|note=preflight_videncode_failed"
    exit 1
}

# ---------------------------------------------------------------------------
# STEP 1: vidpicker (staging -> handbrake folder)
# ---------------------------------------------------------------------------

if (-not $SkipPick) {
    $pickerArgs = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
        (Escape-Argument -Value $resolvedVidpickerScript),
        "-SourceDir", (Escape-Argument -Value $resolvedStagingDir),
        "-DestDir",   (Escape-Argument -Value $resolvedHandbrakeDir),
        "-NoConfirm"
    )
    if ($DryRun) { $pickerArgs += "-DryRun" }

    $pickerResult = Invoke-ToolScript -Label "vidpicker" -Exe $psExe -Arguments $pickerArgs

    if ($pickerResult.ExitCode -ne 0) {
        Write-Warning "vidpicker exited with code $($pickerResult.ExitCode). Stopping."
        Write-Host "SUMMARY|tool=viddispatch|status=failed|dry_run=$dryRunFlag|skip_pick=$skipPickFlag|note=vidpicker_failed"
        exit 1
    }

    if (-not [string]::IsNullOrWhiteSpace($pickerResult.Summary)) {
        $pickedVal = Get-SummaryField -Summary $pickerResult.Summary -Field "moved"
        if ($null -ne $pickedVal) {
            $dispatchPickedCount = [int]$pickedVal
        }
    }
}

# ---------------------------------------------------------------------------
# STEP 2: vidmatch (handbrake folder vs final folder) - get unmatched list
# ---------------------------------------------------------------------------

$tempCsvPath = Join-Path ([System.IO.Path]::GetTempPath()) ("vidmatch-dispatch-" + [System.Guid]::NewGuid().ToString("N") + ".csv")

$dispatchUnmatchedCount = 0
$inputFilesForEncode    = @()

try {
    $matchArgs = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
        (Escape-Argument -Value $resolvedVidmatchScript),
        "-SourceDir", (Escape-Argument -Value $resolvedHandbrakeDir),
        "-TargetDir", (Escape-Argument -Value $resolvedFinalDir),
        "-CsvOutputPath", (Escape-Argument -Value $tempCsvPath)
    )

    $matchResult = Invoke-ToolScript -Label "vidmatch" -Exe $psExe -Arguments $matchArgs

    if ($matchResult.ExitCode -ne 0) {
        Write-Warning "vidmatch exited with code $($matchResult.ExitCode). Stopping."
        Write-Host "SUMMARY|tool=viddispatch|status=failed|dry_run=$dryRunFlag|skip_pick=$skipPickFlag|note=vidmatch_failed"
        exit 1
    }

    if (Test-Path -LiteralPath $tempCsvPath -PathType Leaf) {
        $csvRows = Import-Csv -LiteralPath $tempCsvPath -Encoding UTF8

        $inputFilesForEncode = @(foreach ($row in $csvRows) {
            $fp = $row.FilePath
            if (-not [string]::IsNullOrWhiteSpace($fp)) {
                if ([System.IO.Path]::IsPathRooted($fp)) {
                    $fp
                } else {
                    Join-Path $resolvedHandbrakeDir $fp
                }
            }
        })

        $dispatchUnmatchedCount = $inputFilesForEncode.Count
    }

    if ($dispatchUnmatchedCount -eq 0) {
        Write-Host ""
        Write-Host "No unmatched files found in handbrake folder. Skipping encode step."
    }
    else {
        # ---------------------------------------------------------------------------
        # STEP 3: videncode (encode unmatched files -> final folder)
        # ---------------------------------------------------------------------------

        $encodeArgs = @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
            (Escape-Argument -Value $resolvedVidencodeScript),
            "-SourceDir", (Escape-Argument -Value $resolvedHandbrakeDir),
            "-DestDir",   (Escape-Argument -Value $resolvedFinalDir),
            "-InputFiles"
        )
        foreach ($f in $inputFilesForEncode) {
            $encodeArgs += Escape-Argument -Value $f
        }
        $encodeArgs += "-NoConfirm"
        if ($DryRun) { $encodeArgs += "-DryRun" }

        $encodeResult = Invoke-ToolScript -Label "videncode" -Exe $psExe -Arguments $encodeArgs

        if (-not [string]::IsNullOrWhiteSpace($encodeResult.Summary)) {
            $v = Get-SummaryField -Summary $encodeResult.Summary -Field "encoded"
            if ($null -ne $v) { $dispatchEncoded = [int]$v }
            $v = Get-SummaryField -Summary $encodeResult.Summary -Field "encode_failed"
            if ($null -ne $v) { $dispatchEncodeFailed = [int]$v }
            $v = Get-SummaryField -Summary $encodeResult.Summary -Field "moved"
            if ($null -ne $v) { $dispatchMoved = [int]$v }
            $v = Get-SummaryField -Summary $encodeResult.Summary -Field "move_failed"
            if ($null -ne $v) { $dispatchMoveFailed = [int]$v }
        }

        if ($encodeResult.ExitCode -ne 0) {
            Write-Warning "videncode exited with code $($encodeResult.ExitCode)."
            Write-Host "SUMMARY|tool=viddispatch|status=failed|dry_run=$dryRunFlag|skip_pick=$skipPickFlag|picked=$dispatchPickedCount|unmatched=$dispatchUnmatchedCount|encoded=$dispatchEncoded|encode_failed=$dispatchEncodeFailed|moved=$dispatchMoved|move_failed=$dispatchMoveFailed|reconcile_inspected=0|reconcile_replaced_inflated=0|reconcile_deleted_final_inflated=0|reconcile_deleted_handbrake_smaller=0|reconcile_kept_equal=0|reconcile_missing_final_match=0|reconcile_errors=0"
            exit 1
        }
    }

    # ---------------------------------------------------------------------------
    # STEP 4: reconcile handbrake leftovers vs final sizes
    # ---------------------------------------------------------------------------

    $reconcile = Invoke-HandbrakeFinalReconcile -HandbrakeDir $resolvedHandbrakeDir -FinalDir $resolvedFinalDir -IsDryRun $DryRun.IsPresent

    $didWork = ($dispatchUnmatchedCount -gt 0 -or $dispatchEncoded -gt 0 -or $dispatchMoved -gt 0 -or $reconcile.replaced_inflated -gt 0 -or $reconcile.deleted_handbrake_smaller_final -gt 0)
    $status = if ($DryRun) {
        "noop"
    }
    elseif ($didWork) {
        "ok"
    }
    else {
        "noop"
    }

    Write-Host ""
    Write-Host "SUMMARY|tool=viddispatch|status=$status|dry_run=$dryRunFlag|skip_pick=$skipPickFlag|picked=$dispatchPickedCount|unmatched=$dispatchUnmatchedCount|encoded=$dispatchEncoded|encode_failed=$dispatchEncodeFailed|moved=$dispatchMoved|move_failed=$dispatchMoveFailed|reconcile_inspected=$($reconcile.inspected)|reconcile_replaced_inflated=$($reconcile.replaced_inflated)|reconcile_deleted_final_inflated=$($reconcile.deleted_final_inflated)|reconcile_deleted_handbrake_smaller=$($reconcile.deleted_handbrake_smaller_final)|reconcile_kept_equal=$($reconcile.kept_equal)|reconcile_missing_final_match=$($reconcile.missing_final_match)|reconcile_errors=$($reconcile.cleanup_errors)"
}
finally {
    if (Test-Path -LiteralPath $tempCsvPath) {
        Remove-Item -LiteralPath $tempCsvPath -Force -ErrorAction SilentlyContinue
    }
}
