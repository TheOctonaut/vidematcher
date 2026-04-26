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
    [switch]$NoConfirm,

    [Parameter(Mandatory = $false)]
    [string]$DebugLogPath,

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

if ([string]::IsNullOrWhiteSpace($OptionsFile)) {
    $OptionsFile = Join-Path $scriptRoot "options.json"
}

$exampleOptionsFileName = "options.json.example"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

$script:DispatchDebugLogPath = $null
$script:DispatchDebugLogFallbackActivated = $false
$script:ActiveToolProcess = $null

function Initialize-DebugLogPath {
    param([string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $resolvedParent = Split-Path -Parent $RequestedPath
        if (-not [string]::IsNullOrWhiteSpace($resolvedParent)) {
            New-Item -ItemType Directory -Force -Path $resolvedParent | Out-Null
        }
        return $RequestedPath
    }

    $logDir = Join-Path $scriptRoot "logs"
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    return Join-Path $logDir ("viddispatch-{0}.log" -f $stamp)
}

function Write-DebugLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    if ([string]::IsNullOrWhiteSpace($script:DispatchDebugLogPath)) { return }
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[{0}] {1}" -f $ts, $Message

    try {
        Add-Content -LiteralPath $script:DispatchDebugLogPath -Value $line -ErrorAction Stop
        return
    }
    catch {
        if (-not $script:DispatchDebugLogFallbackActivated) {
            $originalPath = $script:DispatchDebugLogPath
            $parent = Split-Path -Parent $originalPath
            if ([string]::IsNullOrWhiteSpace($parent)) {
                $parent = Join-Path $scriptRoot "logs"
            }
            $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
            $fallbackPath = Join-Path $parent ("viddispatch-fallback-{0}-{1}.log" -f $stamp, $PID)
            $script:DispatchDebugLogPath = $fallbackPath
            $script:DispatchDebugLogFallbackActivated = $true

            try {
                Add-Content -LiteralPath $script:DispatchDebugLogPath -Value ("[{0}] [WARN] switched_log_file original={1} reason={2}" -f $ts, $originalPath, $_.Exception.Message) -ErrorAction Stop
                Add-Content -LiteralPath $script:DispatchDebugLogPath -Value $line -ErrorAction Stop
            }
            catch {
                # Logging must never interrupt the pipeline.
            }
        }
    }
}

function Write-DispatchDetail {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][switch]$Warning,
        [Parameter(Mandatory = $false)][switch]$AlwaysConsole
    )

    $level = if ($Warning) { "WARN" } else { "INFO" }
    Write-DebugLog ("[{0}] {1}" -f $level, $Message)

    if ($AlwaysConsole -or $VerboseConsole) {
        if ($Warning) { Write-Warning $Message } else { Write-Host $Message }
    }
}

function Show-StepProgress {
    param(
        [Parameter(Mandatory = $true)][int]$Percent,
        [Parameter(Mandatory = $true)][string]$Status
    )
    Write-Progress -Activity "viddispatch pipeline" -Status $Status -PercentComplete $Percent
}

function Show-StepResult {
    param(
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][string]$Result,
        [Parameter(Mandatory = $true)][string]$Detail,
        [Parameter(Mandatory = $false)][double]$Seconds = -1
    )

    $label = "[{0}]" -f $Result
    $useColor = $false
    try {
        $useColor = ($null -ne $PSStyle -and $PSStyle.OutputRendering -ne "PlainText")
    }
    catch {
        $useColor = $false
    }

    if ($useColor) {
        $colorPrefix = switch ($Result) {
            "OK"   { $PSStyle.Foreground.BrightGreen; break }
            "SKIP" { $PSStyle.Foreground.BrightYellow; break }
            "FAIL" { $PSStyle.Foreground.BrightRed; break }
            default { $PSStyle.Foreground.BrightCyan; break }
        }
        $label = "{0}{1}{2}" -f $colorPrefix, $label, $PSStyle.Reset
    }

    if ($Seconds -ge 0) {
        Write-Host ("{0} {1} ({2}s) - {3}" -f $label, $Step, ([math]::Round($Seconds, 1)), $Detail)
    }
    else {
        Write-Host ("{0} {1} - {2}" -f $label, $Step, $Detail)
    }
}

function Start-StepTimer {
    return [System.Diagnostics.Stopwatch]::StartNew()
}

function Stop-StepTimer {
    param([Parameter(Mandatory = $true)][System.Diagnostics.Stopwatch]$Timer)
    $Timer.Stop()
    return [math]::Round($Timer.Elapsed.TotalSeconds, 1)
}

function Show-FinalScorecard {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][double]$TotalSeconds,
        [Parameter(Mandatory = $true)][int]$Picked,
        [Parameter(Mandatory = $true)][int]$Unmatched,
        [Parameter(Mandatory = $true)][int]$Encoded,
        [Parameter(Mandatory = $true)][int]$EncodeFailed,
        [Parameter(Mandatory = $true)][int]$Moved,
        [Parameter(Mandatory = $true)][int]$MoveFailed,
        [Parameter(Mandatory = $true)][int]$ReconcileInspected,
        [Parameter(Mandatory = $true)][int]$ReconcileReplacedInflated,
        [Parameter(Mandatory = $true)][int]$ReconcileDeletedSmaller,
        [Parameter(Mandatory = $true)][int]$ReconcileKeptEqual,
        [Parameter(Mandatory = $true)][int]$ReconcileErrors
    )

    Write-Host ""
    Write-Host "Run scorecard"
    Write-Host ("  status: {0}" -f $Status)
    Write-Host ("  total:  {0}s" -f ([math]::Round($TotalSeconds, 1)))
    Write-Host ("  pick/match/encode/move: {0}/{1}/{2}/{3}" -f $Picked, $Unmatched, $Encoded, $Moved)
    Write-Host ("  encode_failed/move_failed: {0}/{1}" -f $EncodeFailed, $MoveFailed)
    Write-Host ("  reconcile inspected/replaced/deleted_smaller/kept_equal/errors: {0}/{1}/{2}/{3}/{4}" -f $ReconcileInspected, $ReconcileReplacedInflated, $ReconcileDeletedSmaller, $ReconcileKeptEqual, $ReconcileErrors)
}

function Escape-Argument {
    param([Parameter(Mandatory = $true)][string]$Value)
    return '"' + $Value.Replace('"', '""') + '"'
}

function Get-PowerShellExe {
    $pwsh = Get-Command "pwsh" -ErrorAction SilentlyContinue
    if ($null -eq $pwsh) {
        throw "pwsh is required for viddispatch.ps7.ps1"
    }
    return $pwsh.Source
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

    Write-DebugLog ("BEGIN tool={0} exe={1} args={2}" -f $Label, $Exe, ($Arguments -join ' '))
    [void]$proc.Start()

    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    $nl = [Environment]::NewLine
    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        Write-DebugLog ("STDOUT tool={0}:{1}{2}" -f $Label, $nl, ($stdout.TrimEnd() -replace "\r?\n", $nl))
    }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        Write-DebugLog ("STDERR tool={0}:{1}{2}" -f $Label, $nl, ($stderr.TrimEnd() -replace "\r?\n", $nl))
    }

    if ($VerboseConsole) {
        if (-not [string]::IsNullOrWhiteSpace($stdout)) { Write-Host ($stdout.TrimEnd() -replace "\r?\n", $nl) }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) { Write-Warning ($stderr.TrimEnd() -replace "\r?\n", $nl) }
    }

    $summaryLine = ($stdout -split "\r?\n") |
        Where-Object { $_.StartsWith("SUMMARY|") } |
        Select-Object -Last 1

    return [PSCustomObject]@{
        ExitCode = $proc.ExitCode
        Summary  = $summaryLine
        Stdout   = $stdout
        Stderr   = $stderr
    }
}

function Stop-ActiveToolProcess {
    if ($null -eq $script:ActiveToolProcess) { return }
    try {
        if (-not $script:ActiveToolProcess.HasExited) {
            $script:ActiveToolProcess.Kill()
            [void]$script:ActiveToolProcess.WaitForExit(3000)
        }
    }
    catch {
        # Best effort only.
    }
    finally {
        $script:ActiveToolProcess = $null
    }
}

function Format-Elapsed {
    param([double]$Seconds)

    if ($Seconds -lt 0) { return "n/a" }
    $ts = [TimeSpan]::FromSeconds([math]::Round($Seconds, 0))
    if ($ts.TotalHours -ge 1) {
        return "{0}h {1}m {2}s" -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds
    }
    if ($ts.TotalMinutes -ge 1) {
        return "{0}m {1}s" -f [int]$ts.TotalMinutes, $ts.Seconds
    }
    return "{0}s" -f [int]$ts.TotalSeconds
}

function ConvertTo-KeyValueMap {
    param([string]$Line)

    $map = @{}
    foreach ($part in ($Line -split "\|")) {
        if ($part -match "=") {
            $kv = $part -split "=", 2
            $map[$kv[0]] = $kv[1]
        }
    }
    return $map
}

function Get-MapIntValue {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Map,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $false)][int]$Default = 0
    )

    if (-not $Map.ContainsKey($Key)) { return $Default }
    $parsed = 0
    if ([int]::TryParse([string]$Map[$Key], [ref]$parsed)) { return $parsed }
    return $Default
}

function Get-MapDoubleValue {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Map,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $false)][double]$Default = 0
    )

    if (-not $Map.ContainsKey($Key)) { return $Default }
    $parsed = 0.0
    if ([double]::TryParse([string]$Map[$Key], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }
    return $Default
}

function Invoke-ToolScriptStreaming {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $false)][scriptblock]$OnStdoutLine,
        [Parameter(Mandatory = $false)][scriptblock]$OnStderrLine
    )

    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    $proc = $null
    $stdoutIndex = 0
    $stderrIndex = 0

    try {
        Write-DebugLog ("BEGIN tool={0} exe={1} args={2}" -f $Label, $Exe, ($Arguments -join ' '))
        $proc = Start-Process -FilePath $Exe -ArgumentList ($Arguments -join " ") -NoNewWindow -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $script:ActiveToolProcess = $proc

        while (-not $proc.HasExited) {
            $stdoutLines = @(Get-Content -LiteralPath $stdoutPath -ErrorAction SilentlyContinue)
            for ($i = $stdoutIndex; $i -lt $stdoutLines.Count; $i++) {
                if ($null -ne $OnStdoutLine) { & $OnStdoutLine ([string]$stdoutLines[$i]) }
            }
            $stdoutIndex = $stdoutLines.Count

            $stderrLines = @(Get-Content -LiteralPath $stderrPath -ErrorAction SilentlyContinue)
            for ($i = $stderrIndex; $i -lt $stderrLines.Count; $i++) {
                if ($null -ne $OnStderrLine) { & $OnStderrLine ([string]$stderrLines[$i]) }
            }
            $stderrIndex = $stderrLines.Count

            Start-Sleep -Milliseconds 250
        }

        [void]$proc.WaitForExit()

        $stdoutLines = @(Get-Content -LiteralPath $stdoutPath -ErrorAction SilentlyContinue)
        for ($i = $stdoutIndex; $i -lt $stdoutLines.Count; $i++) {
            if ($null -ne $OnStdoutLine) { & $OnStdoutLine ([string]$stdoutLines[$i]) }
        }

        $stderrLines = @(Get-Content -LiteralPath $stderrPath -ErrorAction SilentlyContinue)
        for ($i = $stderrIndex; $i -lt $stderrLines.Count; $i++) {
            if ($null -ne $OnStderrLine) { & $OnStderrLine ([string]$stderrLines[$i]) }
        }

        $stdout = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue } else { "" }
        $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue } else { "" }

        $nl = [Environment]::NewLine
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            Write-DebugLog ("STDOUT tool={0}:{1}{2}" -f $Label, $nl, ($stdout.TrimEnd() -replace "\r?\n", $nl))
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            Write-DebugLog ("STDERR tool={0}:{1}{2}" -f $Label, $nl, ($stderr.TrimEnd() -replace "\r?\n", $nl))
        }

        $summaryLine = ($stdout -split "\r?\n") |
            Where-Object { $_.StartsWith("SUMMARY|") } |
            Select-Object -Last 1

        return [PSCustomObject]@{
            ExitCode = $proc.ExitCode
            Summary  = $summaryLine
            Stdout   = $stdout
            Stderr   = $stderr
        }
    }
    finally {
        Stop-ActiveToolProcess
        if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
            Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
            Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
        }
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

    if ($IsDryRun) {
        Write-DispatchDetail -Message "post-encode reconcile start [DRY RUN]"
    }
    else {
        Write-DispatchDetail -Message "post-encode reconcile start"
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
                Write-DispatchDetail -Message ("[DRY RUN] Inflated final for '{0}': smallest final={1} bytes, handbrake source={2} bytes." -f $hb.Name, $smallestFinal.Length, $hb.Length)
                $replacedInflated++
                $deletedFinalInflated += $matches.Count
                continue
            }

            Write-DispatchDetail -Warning -Message ("Inflated final detected for '{0}': smallest final={1} bytes, handbrake source={2} bytes. Replacing final with source." -f $hb.Name, $smallestFinal.Length, $hb.Length)

            $deleteOk = $true
            foreach ($m in $matches) {
                try {
                    Remove-Item -LiteralPath $m.FullName -Force
                    $deletedFinalInflated++
                    Write-DispatchDetail -Warning -Message ("Removed inflated final file: {0}" -f $m.FullName)
                }
                catch {
                    $cleanupErrors++
                    $deleteOk = $false
                    Write-DispatchDetail -Warning -Message ("Failed to remove inflated final file '{0}': {1}" -f $m.FullName, $_.Exception.Message)
                }
            }

            if ($deleteOk) {
                try {
                    $replacementPath = Join-Path $FinalDir $hb.Name
                    Move-Item -LiteralPath $hb.FullName -Destination $replacementPath -Force
                    Write-DispatchDetail -Warning -Message ("Replaced final with untouched source and removed handbrake copy: {0}" -f $replacementPath)
                    $replacedInflated++
                }
                catch {
                    $cleanupErrors++
                    Write-DispatchDetail -Warning -Message ("Failed to move replacement source '{0}' into final: {1}" -f $hb.FullName, $_.Exception.Message)
                }
            }

            continue
        }

        if ($smallestFinal.Length -lt $hb.Length) {
            if ($IsDryRun) {
                Write-DispatchDetail -Message ("[DRY RUN] Final is smaller for '{0}' (final={1}, handbrake={2}). Would delete from handbrake." -f $hb.Name, $smallestFinal.Length, $hb.Length)
                $deletedHandbrakeSmallerFinal++
                continue
            }

            try {
                Remove-Item -LiteralPath $hb.FullName -Force
                Write-DispatchDetail -Message ("Deleted handbrake source after verified smaller final: {0}" -f $hb.FullName)
                $deletedHandbrakeSmallerFinal++
            }
            catch {
                $cleanupErrors++
                Write-DispatchDetail -Warning -Message ("Failed to delete handbrake source '{0}': {1}" -f $hb.FullName, $_.Exception.Message)
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
    $resolvedVidpickerScript = Join-Path $repoRoot "vidpicker\vidpicker.ps7.ps1"
}
if ([string]::IsNullOrWhiteSpace($resolvedVidmatchScript)) {
    $resolvedVidmatchScript = Join-Path $repoRoot "vidmatch\vidmatch.ps7.ps1"
}
if ([string]::IsNullOrWhiteSpace($resolvedVidencodeScript)) {
    $resolvedVidencodeScript = Join-Path $repoRoot "videncode\videncode.ps7.ps1"
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
$script:DispatchDebugLogPath = Initialize-DebugLogPath -RequestedPath $DebugLogPath

Write-Progress -Activity "viddispatch pipeline" -Completed
Write-Host "viddispatch starting"
if (-not $SkipPick) { Write-Host "  StagingDir:   $resolvedStagingDir" }
Write-Host "  HandbrakeDir: $resolvedHandbrakeDir"
Write-Host "  FinalDir:     $resolvedFinalDir"
if ($DryRun)   { Write-Host "  [DRY RUN]" }
if ($SkipPick) { Write-Host "  [SKIP PICK]" }
Write-Host ("  Debug log:    {0}" -f $script:DispatchDebugLogPath)
if (-not $VerboseConsole) { Write-Host "  Console mode: clean (use -VerboseConsole for full child output)" }
Write-DebugLog "viddispatch session started"
$pipelineWatch = [System.Diagnostics.Stopwatch]::StartNew()

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
Show-StepProgress -Percent 0 -Status "Initializing"

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

$preflightWatch = Start-StepTimer
$preflightResult = Invoke-ToolScript -Label "preflight: videncode" -Exe $psExe -Arguments $preflightArgs
$preflightSeconds = Stop-StepTimer -Timer $preflightWatch
if ($preflightResult.ExitCode -ne 0) {
    Show-StepResult -Step "Preflight" -Result "FAIL" -Detail "videncode dependency/config check failed" -Seconds $preflightSeconds
    Write-DispatchDetail -Warning -AlwaysConsole -Message "Preflight failed (videncode dependencies/config). Stopping before file moves."
    $pipelineWatch.Stop()
    Show-FinalScorecard -Status "failed" -TotalSeconds $pipelineWatch.Elapsed.TotalSeconds -Picked $dispatchPickedCount -Unmatched 0 -Encoded $dispatchEncoded -EncodeFailed $dispatchEncodeFailed -Moved $dispatchMoved -MoveFailed $dispatchMoveFailed -ReconcileInspected 0 -ReconcileReplacedInflated 0 -ReconcileDeletedSmaller 0 -ReconcileKeptEqual 0 -ReconcileErrors 0
    Show-StepProgress -Percent 100 -Status "Failed"
    Write-Progress -Activity "viddispatch pipeline" -Completed
    Write-Host "SUMMARY|tool=viddispatch|status=failed|dry_run=$dryRunFlag|skip_pick=$skipPickFlag|note=preflight_videncode_failed"
    exit 1
}
Show-StepResult -Step "Preflight" -Result "OK" -Detail "encode dependencies validated" -Seconds $preflightSeconds
Show-StepProgress -Percent 20 -Status "Preflight complete"

# ---------------------------------------------------------------------------
# STEP 1: vidpicker (staging -> handbrake folder)
# ---------------------------------------------------------------------------

if (-not $SkipPick) {
    $pickWatch = Start-StepTimer
    $pickerArgs = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
        (Escape-Argument -Value $resolvedVidpickerScript),
        "-SourceDir", (Escape-Argument -Value $resolvedStagingDir),
        "-DestDir",   (Escape-Argument -Value $resolvedHandbrakeDir),
        "-NoConfirm"
    )
    if ($DryRun) { $pickerArgs += "-DryRun" }

    $pickerResult = Invoke-ToolScript -Label "vidpicker" -Exe $psExe -Arguments $pickerArgs
    $pickSeconds = Stop-StepTimer -Timer $pickWatch

    if ($pickerResult.ExitCode -ne 0) {
        Show-StepResult -Step "Pick" -Result "FAIL" -Detail ("vidpicker exited {0}" -f $pickerResult.ExitCode) -Seconds $pickSeconds
        $pipelineWatch.Stop()
        Show-FinalScorecard -Status "failed" -TotalSeconds $pipelineWatch.Elapsed.TotalSeconds -Picked $dispatchPickedCount -Unmatched 0 -Encoded $dispatchEncoded -EncodeFailed $dispatchEncodeFailed -Moved $dispatchMoved -MoveFailed $dispatchMoveFailed -ReconcileInspected 0 -ReconcileReplacedInflated 0 -ReconcileDeletedSmaller 0 -ReconcileKeptEqual 0 -ReconcileErrors 0
        Show-StepProgress -Percent 100 -Status "Failed"
        Write-Progress -Activity "viddispatch pipeline" -Completed
        Write-Host "SUMMARY|tool=viddispatch|status=failed|dry_run=$dryRunFlag|skip_pick=$skipPickFlag|note=vidpicker_failed"
        exit 1
    }

    if (-not [string]::IsNullOrWhiteSpace($pickerResult.Summary)) {
        $pickedVal = Get-SummaryField -Summary $pickerResult.Summary -Field "moved"
        if ($null -ne $pickedVal) {
            $dispatchPickedCount = [int]$pickedVal
        }
    }

    Show-StepResult -Step "Pick" -Result "OK" -Detail ("moved={0}" -f $dispatchPickedCount) -Seconds $pickSeconds
}
else {
    Show-StepResult -Step "Pick" -Result "SKIP" -Detail "-SkipPick enabled"
}
Show-StepProgress -Percent 45 -Status "Matching source vs final"

# ---------------------------------------------------------------------------
# STEP 2: vidmatch (handbrake folder vs final folder) - get unmatched list
# ---------------------------------------------------------------------------

$tempCsvPath = Join-Path ([System.IO.Path]::GetTempPath()) ("vidmatch-dispatch-" + [System.Guid]::NewGuid().ToString("N") + ".csv")
$tempInputListPath = Join-Path ([System.IO.Path]::GetTempPath()) ("viddispatch-inputs-" + [System.Guid]::NewGuid().ToString("N") + ".txt")

$dispatchUnmatchedCount = 0
$inputFilesForEncode    = @()

try {
    $matchWatch = Start-StepTimer
    $matchArgs = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
        (Escape-Argument -Value $resolvedVidmatchScript),
        "-SourceDir", (Escape-Argument -Value $resolvedHandbrakeDir),
        "-TargetDir", (Escape-Argument -Value $resolvedFinalDir),
        "-CsvOutputPath", (Escape-Argument -Value $tempCsvPath)
    )

    $matchResult = Invoke-ToolScript -Label "vidmatch" -Exe $psExe -Arguments $matchArgs
    $matchSeconds = Stop-StepTimer -Timer $matchWatch

    if ($matchResult.ExitCode -ne 0) {
        Show-StepResult -Step "Match" -Result "FAIL" -Detail ("vidmatch exited {0}" -f $matchResult.ExitCode) -Seconds $matchSeconds
        $pipelineWatch.Stop()
        Show-FinalScorecard -Status "failed" -TotalSeconds $pipelineWatch.Elapsed.TotalSeconds -Picked $dispatchPickedCount -Unmatched $dispatchUnmatchedCount -Encoded $dispatchEncoded -EncodeFailed $dispatchEncodeFailed -Moved $dispatchMoved -MoveFailed $dispatchMoveFailed -ReconcileInspected 0 -ReconcileReplacedInflated 0 -ReconcileDeletedSmaller 0 -ReconcileKeptEqual 0 -ReconcileErrors 0
        Show-StepProgress -Percent 100 -Status "Failed"
        Write-Progress -Activity "viddispatch pipeline" -Completed
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
        Show-StepResult -Step "Match" -Result "OK" -Detail "unmatched=0" -Seconds $matchSeconds
        Show-StepResult -Step "Encode" -Result "SKIP" -Detail "nothing to encode"
    }
    else {
        Show-StepResult -Step "Match" -Result "OK" -Detail ("unmatched={0}" -f $dispatchUnmatchedCount) -Seconds $matchSeconds
        # ---------------------------------------------------------------------------
        # STEP 3: videncode (encode unmatched files -> final folder)
        # ---------------------------------------------------------------------------

        $encodeArgs = @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
            (Escape-Argument -Value $resolvedVidencodeScript),
            "-SourceDir", (Escape-Argument -Value $resolvedHandbrakeDir),
            "-DestDir",   (Escape-Argument -Value $resolvedFinalDir),
            "-InputFilesListFile", (Escape-Argument -Value $tempInputListPath)
        )
        Set-Content -LiteralPath $tempInputListPath -Value $inputFilesForEncode -Encoding UTF8
        Write-DebugLog ("encode input transport=list_file count={0}" -f $inputFilesForEncode.Count)
        $encodeArgs += "-NoConfirm"
        if ($DryRun) { $encodeArgs += "-DryRun" }

        $encodeWatch = Start-StepTimer
        $encodeState = @{
            index   = 0
            total   = $dispatchUnmatchedCount
            file    = ""
            elapsed = 0.0
            eta     = "estimating..."
        }
        Show-StepProgress -Percent 50 -Status ("Encoding 0/{0}" -f $encodeState.total)

        $onEncodeStdout = {
            param([string]$Line)

            if ([string]::IsNullOrWhiteSpace($Line)) { return }

            if ($Line.StartsWith("PROGRESS|tool=videncode|")) {
                $progressMap = ConvertTo-KeyValueMap -Line $Line
                $evt = if ($progressMap.ContainsKey("event")) { $progressMap["event"] } else { "" }
                if ($progressMap.ContainsKey("file") -and -not [string]::IsNullOrWhiteSpace($progressMap["file"])) {
                    $encodeState.file = $progressMap["file"]
                }
                $encodeState.index   = Get-MapIntValue    -Map $progressMap -Key "index"           -Default $encodeState.index
                $encodeState.total   = Get-MapIntValue    -Map $progressMap -Key "total"           -Default $encodeState.total
                $encodeState.elapsed = Get-MapDoubleValue -Map $progressMap -Key "elapsed_seconds" -Default $encodeState.elapsed

                if ($encodeState.total -le 0) { $encodeState.total = $dispatchUnmatchedCount }
                if ($encodeState.index -gt $encodeState.total) { $encodeState.index = $encodeState.total }

                if ($evt -eq "update") {
                    if ($encodeState.index -gt 0 -and $encodeState.index -lt $encodeState.total -and $encodeState.elapsed -gt 0) {
                        $avg = $encodeState.elapsed / [double]$encodeState.index
                        $encodeState.eta = Format-Elapsed -Seconds ($avg * ($encodeState.total - $encodeState.index))
                    }
                    elseif ($encodeState.index -ge $encodeState.total) {
                        $encodeState.eta = ""
                    }
                }

                $progressPercent = 50
                if ($encodeState.total -gt 0) {
                    $fraction = [math]::Min(1.0, ([double]$encodeState.index / [double]$encodeState.total))
                    $progressPercent = 50 + [int][math]::Round($fraction * 25)
                }

                $currentName = if ([string]::IsNullOrWhiteSpace($encodeState.file)) { "-" } else { [System.IO.Path]::GetFileName($encodeState.file) }
                $etaDisplay  = if ([string]::IsNullOrWhiteSpace($encodeState.eta)) { "" } else { " | ETA $($encodeState.eta)" }
                $status = "Encoding {0}/{1} | {2}{3}" -f $encodeState.index, $encodeState.total, $currentName, $etaDisplay
                Show-StepProgress -Percent $progressPercent -Status $status
                return
            }

            if ($VerboseConsole) {
                Write-Host $Line
            }
        }

        $onEncodeStderr = {
            param([string]$Line)
            if ([string]::IsNullOrWhiteSpace($Line)) { return }
            if ($VerboseConsole) { Write-Warning $Line }
        }

        try {
            $encodeResult = Invoke-ToolScriptStreaming -Label "videncode" -Exe $psExe -Arguments $encodeArgs -OnStdoutLine $onEncodeStdout -OnStderrLine $onEncodeStderr
        }
        catch [System.Management.Automation.PipelineStoppedException] {
            Stop-ActiveToolProcess
            $encodeSeconds = Stop-StepTimer -Timer $encodeWatch
            Show-StepResult -Step "Encode" -Result "FAIL" -Detail "interrupted by user; active encode stopped and remaining files left untouched" -Seconds $encodeSeconds
            $pipelineWatch.Stop()
            Show-FinalScorecard -Status "aborted" -TotalSeconds $pipelineWatch.Elapsed.TotalSeconds -Picked $dispatchPickedCount -Unmatched $dispatchUnmatchedCount -Encoded $dispatchEncoded -EncodeFailed $dispatchEncodeFailed -Moved $dispatchMoved -MoveFailed $dispatchMoveFailed -ReconcileInspected 0 -ReconcileReplacedInflated 0 -ReconcileDeletedSmaller 0 -ReconcileKeptEqual 0 -ReconcileErrors 0
            Show-StepProgress -Percent 100 -Status "Aborted"
            Write-Progress -Activity "viddispatch pipeline" -Completed
            Write-Host "SUMMARY|tool=viddispatch|status=aborted|dry_run=$dryRunFlag|skip_pick=$skipPickFlag|picked=$dispatchPickedCount|unmatched=$dispatchUnmatchedCount|encoded=$dispatchEncoded|encode_failed=$dispatchEncodeFailed|moved=$dispatchMoved|move_failed=$dispatchMoveFailed|reconcile_inspected=0|reconcile_replaced_inflated=0|reconcile_deleted_final_inflated=0|reconcile_deleted_handbrake_smaller=0|reconcile_kept_equal=0|reconcile_missing_final_match=0|reconcile_errors=0|note=user_interrupted"
            exit 130
        }

        $encodeSeconds = Stop-StepTimer -Timer $encodeWatch

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

        $encodeSummaryStatus = $null
        if (-not [string]::IsNullOrWhiteSpace($encodeResult.Summary)) {
            $encodeSummaryStatus = Get-SummaryField -Summary $encodeResult.Summary -Field "status"
        }
        $encodeSucceeded = ($encodeSummaryStatus -eq "ok" -or $encodeSummaryStatus -eq "noop") -or
                           ($null -eq $encodeSummaryStatus -and $encodeResult.ExitCode -eq 0)
        if (-not $encodeSucceeded) {
            $encodeFailDetail = if (-not [string]::IsNullOrWhiteSpace($encodeSummaryStatus)) {
                "videncode status=$encodeSummaryStatus"
            } else {
                $encodeExitCodeText = if ($null -eq $encodeResult.ExitCode -or [string]::IsNullOrWhiteSpace([string]$encodeResult.ExitCode)) { "non-zero" } else { [string]$encodeResult.ExitCode }
                "videncode exited $encodeExitCodeText"
            }
            Show-StepResult -Step "Encode" -Result "FAIL" -Detail $encodeFailDetail -Seconds $encodeSeconds
            $pipelineWatch.Stop()
            Show-FinalScorecard -Status "failed" -TotalSeconds $pipelineWatch.Elapsed.TotalSeconds -Picked $dispatchPickedCount -Unmatched $dispatchUnmatchedCount -Encoded $dispatchEncoded -EncodeFailed $dispatchEncodeFailed -Moved $dispatchMoved -MoveFailed $dispatchMoveFailed -ReconcileInspected 0 -ReconcileReplacedInflated 0 -ReconcileDeletedSmaller 0 -ReconcileKeptEqual 0 -ReconcileErrors 0
            Show-StepProgress -Percent 100 -Status "Failed"
            Write-Progress -Activity "viddispatch pipeline" -Completed
            Write-Host "SUMMARY|tool=viddispatch|status=failed|dry_run=$dryRunFlag|skip_pick=$skipPickFlag|picked=$dispatchPickedCount|unmatched=$dispatchUnmatchedCount|encoded=$dispatchEncoded|encode_failed=$dispatchEncodeFailed|moved=$dispatchMoved|move_failed=$dispatchMoveFailed|reconcile_inspected=0|reconcile_replaced_inflated=0|reconcile_deleted_final_inflated=0|reconcile_deleted_handbrake_smaller=0|reconcile_kept_equal=0|reconcile_missing_final_match=0|reconcile_errors=0"
            exit 1
        }

        Show-StepResult -Step "Encode" -Result "OK" -Detail ("encoded={0} failed={1} moved={2}" -f $dispatchEncoded, $dispatchEncodeFailed, $dispatchMoved) -Seconds $encodeSeconds
    }

    Show-StepProgress -Percent 75 -Status "Reconcile cleanup"

    # ---------------------------------------------------------------------------
    # STEP 4: reconcile handbrake leftovers vs final sizes
    # ---------------------------------------------------------------------------

    $reconcileWatch = Start-StepTimer
    $reconcile = Invoke-HandbrakeFinalReconcile -HandbrakeDir $resolvedHandbrakeDir -FinalDir $resolvedFinalDir -IsDryRun $DryRun.IsPresent
    $reconcileSeconds = Stop-StepTimer -Timer $reconcileWatch
    Show-StepResult -Step "Reconcile" -Result "OK" -Detail ("inspected={0} replaced_inflated={1} deleted_smaller={2} kept_equal={3}" -f $reconcile.inspected, $reconcile.replaced_inflated, $reconcile.deleted_handbrake_smaller_final, $reconcile.kept_equal) -Seconds $reconcileSeconds

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

    Show-StepProgress -Percent 100 -Status "Complete"
    Write-Progress -Activity "viddispatch pipeline" -Completed
    $pipelineWatch.Stop()
    Show-FinalScorecard -Status $status -TotalSeconds $pipelineWatch.Elapsed.TotalSeconds -Picked $dispatchPickedCount -Unmatched $dispatchUnmatchedCount -Encoded $dispatchEncoded -EncodeFailed $dispatchEncodeFailed -Moved $dispatchMoved -MoveFailed $dispatchMoveFailed -ReconcileInspected $reconcile.inspected -ReconcileReplacedInflated $reconcile.replaced_inflated -ReconcileDeletedSmaller $reconcile.deleted_handbrake_smaller_final -ReconcileKeptEqual $reconcile.kept_equal -ReconcileErrors $reconcile.cleanup_errors
    Write-Host "SUMMARY|tool=viddispatch|status=$status|dry_run=$dryRunFlag|skip_pick=$skipPickFlag|picked=$dispatchPickedCount|unmatched=$dispatchUnmatchedCount|encoded=$dispatchEncoded|encode_failed=$dispatchEncodeFailed|moved=$dispatchMoved|move_failed=$dispatchMoveFailed|reconcile_inspected=$($reconcile.inspected)|reconcile_replaced_inflated=$($reconcile.replaced_inflated)|reconcile_deleted_final_inflated=$($reconcile.deleted_final_inflated)|reconcile_deleted_handbrake_smaller=$($reconcile.deleted_handbrake_smaller_final)|reconcile_kept_equal=$($reconcile.kept_equal)|reconcile_missing_final_match=$($reconcile.missing_final_match)|reconcile_errors=$($reconcile.cleanup_errors)"
}
finally {
    if (Test-Path -LiteralPath $tempCsvPath) {
        Remove-Item -LiteralPath $tempCsvPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $tempInputListPath) {
        Remove-Item -LiteralPath $tempInputListPath -Force -ErrorAction SilentlyContinue
    }
}
