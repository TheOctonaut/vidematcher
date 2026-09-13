param(
    [Parameter(Mandatory = $false)]
    [string]$VidtagScript,

    [Parameter(Mandatory = $false)]
    [string]$VidtranscribeScript
)

# ---------------------------------------------------------------------------
# STA relaunch guard
# ---------------------------------------------------------------------------

$currentApartment = [System.Threading.Thread]::CurrentThread.GetApartmentState()
if ($currentApartment -ne [System.Threading.ApartmentState]::STA) {
    $powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) {
        $powershellExe = "powershell.exe"
    }

    Start-Process -FilePath $powershellExe -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-STA",
        "-File", "`"$PSCommandPath`""
    ) | Out-Null
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Must be set before any Controls are created on this thread.
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------

$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $PSCommandPath
}
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = (Get-Location).Path
}

$repoRoot = Split-Path -Parent $scriptRoot

if ([string]::IsNullOrWhiteSpace($VidtagScript)) {
    $VidtagScript = Join-Path $repoRoot "vidtag\vidtag.ps1"
}
if ([string]::IsNullOrWhiteSpace($VidtranscribeScript)) {
    $VidtranscribeScript = Join-Path $repoRoot "vidtranscribe\vidtranscribe.ps1"
}

$vidtagDir         = Split-Path -Parent $VidtagScript
$vidtranscribeDir  = Split-Path -Parent $VidtranscribeScript

# ---------------------------------------------------------------------------
# Shared helper functions
# ---------------------------------------------------------------------------

function Get-PowerShellExe {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($null -ne $pwsh) {
        return $pwsh.Source
    }

    $windowsPowerShell = Get-Command powershell -ErrorAction SilentlyContinue
    if ($null -ne $windowsPowerShell) {
        return $windowsPowerShell.Source
    }

    throw "Could not find a PowerShell executable (pwsh or powershell)."
}

function Escape-Argument {
    # Quotes a value for use inside a single ProcessStartInfo.Arguments string,
    # following the Win32/CRT command-line quoting rules: a run of backslashes
    # must be doubled when it is immediately followed by a quote (embedded or
    # closing), otherwise a trailing "\" merges with the closing quote and the
    # argument never terminates (e.g. a bare "-Path", 'Z:\' would swallow every
    # argument after it). A naive '"' + value + '"' + doubled-quotes approach
    # does not handle this and silently corrupts any path ending in "\".
    param([Parameter(Mandatory = $true)][string]$Value)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashCount = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashCount++
            continue
        }
        if ($ch -eq '"') {
            [void]$sb.Append('\', ($backslashCount * 2 + 1))
            [void]$sb.Append('"')
            $backslashCount = 0
            continue
        }
        if ($backslashCount -gt 0) {
            [void]$sb.Append('\', $backslashCount)
            $backslashCount = 0
        }
        [void]$sb.Append($ch)
    }
    if ($backslashCount -gt 0) {
        [void]$sb.Append('\', $backslashCount * 2)
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Debug logging (non-fatal: a logging failure must never break the UI)
# ---------------------------------------------------------------------------

$script:VidUiLogPath = $null
$script:VidUiLogFallbackActivated = $false

function Initialize-VidUiLogPath {
    $logDir = Join-Path $scriptRoot "logs"
    try {
        New-Item -ItemType Directory -Force -Path $logDir -ErrorAction Stop | Out-Null
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        return Join-Path $logDir ("vidui-{0}-{1}.log" -f $stamp, $PID)
    }
    catch {
        # Fall back to the temp folder if the repo folder isn't writable.
        return Join-Path ([System.IO.Path]::GetTempPath()) ("vidui-{0}-{1}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $PID)
    }
}

function Write-VidUiLog {
    param([Parameter(Mandatory = $true)][string]$Message)

    if ([string]::IsNullOrWhiteSpace($script:VidUiLogPath)) { return }
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[{0}] {1}" -f $ts, $Message

    try {
        Add-Content -LiteralPath $script:VidUiLogPath -Value $line -ErrorAction Stop
    }
    catch {
        if (-not $script:VidUiLogFallbackActivated) {
            $script:VidUiLogFallbackActivated = $true
            $fallbackPath = Join-Path ([System.IO.Path]::GetTempPath()) ("vidui-fallback-{0}-{1}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $PID)
            $script:VidUiLogPath = $fallbackPath
            try { Add-Content -LiteralPath $script:VidUiLogPath -Value $line -ErrorAction Stop } catch { }
        }
        # If even the fallback fails, logging is simply skipped; it must never interrupt the UI.
    }
}

function Show-VidUiError {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][string]$Title = "Error"
    )

    Write-VidUiLog ("[ERROR] {0}" -f $Message)
    $logHint = if ($script:VidUiLogPath) { "`n`nDetails logged to:`n$script:VidUiLogPath" } else { "" }
    [System.Windows.Forms.MessageBox]::Show(
        ($Message + $logHint),
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

$script:VidUiLogPath = Initialize-VidUiLogPath
Write-VidUiLog ("vidui started. VidtagScript=$VidtagScript VidtranscribeScript=$VidtranscribeScript")

function Load-OptionsDefaults {
    param([Parameter(Mandatory = $true)][string]$OptionsPath)

    if (-not (Test-Path -LiteralPath $OptionsPath -PathType Leaf)) {
        return $null
    }

    try {
        $content = Get-Content -LiteralPath $OptionsPath -Raw
        if ([string]::IsNullOrWhiteSpace($content)) {
            return $null
        }

        return $content | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function ConvertFrom-PipeLine {
    # Parses a "KEY|k1=v1|k2=v2" style line (the PROGRESS/SUMMARY protocol
    # shared by vidematcher tools) into a hashtable. First token (before the
    # first "|") is ignored by the caller if it isn't a key=value pair.
    param([Parameter(Mandatory = $true)][string]$Line)

    $map = @{}
    foreach ($part in $Line -split '\|') {
        $eq = $part.IndexOf('=')
        if ($eq -gt 0) {
            $key = $part.Substring(0, $eq)
            $val = $part.Substring($eq + 1)
            $map[$key] = $val
        }
    }
    return $map
}

$vidtagDefaults        = Load-OptionsDefaults -OptionsPath (Join-Path $vidtagDir "options.json")
$vidtranscribeDefaults = Load-OptionsDefaults -OptionsPath (Join-Path $vidtranscribeDir "options.json")

# ---------------------------------------------------------------------------
# Status gauge control (owner-drawn pie/donut, no extra chart assembly
# needed - System.Drawing is already a dependency of this script)
# ---------------------------------------------------------------------------

function New-StatusGauge {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Forms.Control]$Parent,
        [Parameter(Mandatory = $true)][int]$X,
        [Parameter(Mandatory = $true)][int]$Y,
        [int]$Size = 72
    )

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point($X, $Y)
    $panel.Size = New-Object System.Drawing.Size($Size, $Size)
    # PercentValue is an ad-hoc ETS member (not a real Panel property) used
    # purely to hand the current percentage to the Paint handler below.
    $panel | Add-Member -MemberType NoteProperty -Name PercentValue -Value 0.0 -Force

    $panel.Add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $pct = [double]$sender.PercentValue
        if ($pct -lt 0) { $pct = 0 }
        if ($pct -gt 100) { $pct = 100 }

        $rect = New-Object System.Drawing.Rectangle(2, 2, ($sender.Width - 4), ($sender.Height - 4))
        $g.FillEllipse([System.Drawing.Brushes]::Gainsboro, $rect)

        if ($pct -gt 0) {
            $sweep = 360.0 * ($pct / 100.0)
            $sliceBrush =
                if ($pct -ge 99.95) { [System.Drawing.Brushes]::ForestGreen }
                elseif ($pct -ge 50) { [System.Drawing.Brushes]::SteelBlue }
                else { [System.Drawing.Brushes]::IndianRed }
            $g.FillPie($sliceBrush, $rect, -90.0, [float]$sweep)
        }

        $g.DrawEllipse([System.Drawing.Pens]::DarkGray, $rect)

        $innerMargin = [int][Math]::Round($sender.Width * 0.22)
        $innerSize = $sender.Width - (2 * $innerMargin)
        $innerRect = New-Object System.Drawing.Rectangle($innerMargin, $innerMargin, $innerSize, $innerSize)
        $g.FillEllipse([System.Drawing.Brushes]::White, $innerRect)

        $font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = [System.Drawing.StringAlignment]::Center
        $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $clientRectF = New-Object System.Drawing.RectangleF(0, 0, $sender.Width, $sender.Height)
        $g.DrawString(("{0:0}%" -f $pct), $font, [System.Drawing.Brushes]::Black, $clientRectF, $fmt)
        $font.Dispose()
        $fmt.Dispose()
    })

    $Parent.Controls.Add($panel)
    return $panel
}

function Set-StatusGauge {
    param(
        [Parameter(Mandatory = $true)]$Gauge,
        [Parameter(Mandatory = $true)][double]$Percent
    )
    $Gauge.PercentValue = $Percent
    $Gauge.Invalidate()
}

# ---------------------------------------------------------------------------
# Background status scans (folder-completeness checks). Each scan runs on a
# separate PowerShell instance via BeginInvoke so a big/slow (e.g. network
# share) recursive scan never freezes the UI thread; a shared timer polls
# for completion, the same pattern used for the tool-run stdout readers.
# ---------------------------------------------------------------------------

$script:pendingScans = [System.Collections.Generic.List[object]]::new()

function Start-StatusScan {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory = $false)][object[]]$ArgumentList = @(),
        [Parameter(Mandatory = $true)][scriptblock]$OnComplete
    )

    $ps = [powershell]::Create()
    [void]$ps.AddScript($ScriptBlock)
    foreach ($argItem in $ArgumentList) { [void]$ps.AddArgument($argItem) }
    $handle = $ps.BeginInvoke()
    $script:pendingScans.Add([PSCustomObject]@{ PowerShell = $ps; Handle = $handle; OnComplete = $OnComplete })
}

$statusScanTimer = New-Object System.Windows.Forms.Timer
$statusScanTimer.Interval = 250
$statusScanTimer.Add_Tick({
    for ($i = $script:pendingScans.Count - 1; $i -ge 0; $i--) {
        $job = $script:pendingScans[$i]
        if ($job.Handle.IsCompleted) {
            $result = $null
            try {
                $result = $job.PowerShell.EndInvoke($job.Handle)
                if ($result -is [array]) { $result = $result | Select-Object -Last 1 }
            }
            catch {
                $result = $null
            }
            try { & $job.OnComplete $result } catch { }
            $job.PowerShell.Dispose()
            $script:pendingScans.RemoveAt($i)
        }
    }
})
$statusScanTimer.Start()

# Scans a Transcribe -Path (file or flat folder, matching vidtranscribe.ps1's
# own non-recursive *.mp4 scan) and reports how many videos are "up to date":
# have an English subtitle AND a .vidtranscribe.json stamped with a probe
# version >= the caller-supplied $LanguageProbeVersion (so files transcribed
# under older language-detection logic show as not-yet-up-to-date, matching
# the -RecheckLanguage workflow).
$transcribeScanScript = {
    param($Path, $LanguageProbeVersion)

    $result = [PSCustomObject]@{ Error = $null; Total = 0; UpToDate = 0; Percent = 0.0 }

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            $result.Error = "Path not found."
            return $result
        }

        $item = Get-Item -LiteralPath $Path
        $videoFiles = if ($item.PSIsContainer) {
            @(Get-ChildItem -LiteralPath $Path -Filter "*.mp4" -File -ErrorAction SilentlyContinue)
        }
        else {
            @($item)
        }

        $result.Total = $videoFiles.Count
        if ($result.Total -eq 0) { return $result }

        $upToDate = 0
        foreach ($file in $videoFiles) {
            $dir = $file.DirectoryName
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            $escapedName = [regex]::Escape($baseName)
            $taggedPattern = "^$escapedName\.([A-Za-z]{2,3})\.srt$"

            $hasEnglish = $false
            $existingSrt = Get-ChildItem -LiteralPath $dir -File -Filter "$baseName*.srt" -ErrorAction SilentlyContinue
            foreach ($s in $existingSrt) {
                if ($s.Name -match $taggedPattern -and $Matches[1].ToLowerInvariant() -eq "en") {
                    $hasEnglish = $true
                    break
                }
            }
            if (-not $hasEnglish) { continue }

            $jsonPath = Join-Path $dir "$baseName.vidtranscribe.json"
            if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) { continue }

            try {
                $raw = Get-Content -LiteralPath $jsonPath -Raw
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    $j = $raw | ConvertFrom-Json
                    if ($null -ne $j.vidtranscribe_probe_version -and [int]$j.vidtranscribe_probe_version -ge $LanguageProbeVersion) {
                        $upToDate++
                    }
                }
            }
            catch { }
        }

        $result.UpToDate = $upToDate
        $result.Percent = [math]::Round((100.0 * $upToDate / $result.Total), 1)
    }
    catch {
        $result.Error = $_.Exception.Message
    }

    return $result
}

# Scans a Tag scan-path recursively for *.vidtranscribe.json sidecars
# (matching vidtag.ps1's own recursive scan), and reports how many of the
# ones eligible for tagging (a matching .nfo exists alongside) already have
# vidtag_processed = true.
$tagScanScript = {
    param($Path)

    $result = [PSCustomObject]@{ Error = $null; Eligible = 0; Processed = 0; Percent = 0.0; NoNfo = 0 }

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            $result.Error = "Path not found."
            return $result
        }

        $transcriptFiles = @(Get-ChildItem -LiteralPath $Path -Recurse -Filter "*.vidtranscribe.json" -File -ErrorAction SilentlyContinue)
        if ($transcriptFiles.Count -eq 0) { return $result }

        $eligible = 0
        $processed = 0
        $noNfo = 0

        foreach ($tf in $transcriptFiles) {
            $dir = $tf.DirectoryName
            $baseName = $tf.Name -replace '\.vidtranscribe\.json$', ''
            $nfoPath = Join-Path $dir ($baseName + ".nfo")
            if (-not (Test-Path -LiteralPath $nfoPath -PathType Leaf)) {
                $noNfo++
                continue
            }

            $eligible++
            try {
                $raw = Get-Content -LiteralPath $tf.FullName -Raw
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    $j = $raw | ConvertFrom-Json
                    if ($j.PSObject.Properties.Name -contains "vidtag_processed" -and $j.vidtag_processed -eq $true) {
                        $processed++
                    }
                }
            }
            catch { }
        }

        $result.Eligible = $eligible
        $result.Processed = $processed
        $result.NoNfo = $noNfo
        if ($eligible -gt 0) {
            $result.Percent = [math]::Round((100.0 * $processed / $eligible), 1)
        }
    }
    catch {
        $result.Error = $_.Exception.Message
    }

    return $result
}

# ---------------------------------------------------------------------------
# Main form
# ---------------------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = "vidematcher tools"
$form.Size = New-Object System.Drawing.Size(940, 720)
$form.MinimumSize = New-Object System.Drawing.Size(820, 560)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Location = New-Object System.Drawing.Point(12, 12)
$tabControl.Size = New-Object System.Drawing.Size(900, 330)
$tabControl.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($tabControl)

$tabTranscribe = New-Object System.Windows.Forms.TabPage
$tabTranscribe.Text = "Transcribe"
$tabControl.TabPages.Add($tabTranscribe)

$tabTag = New-Object System.Windows.Forms.TabPage
$tabTag.Text = "Tag"
$tabControl.TabPages.Add($tabTag)

# ===========================================================================
# Transcribe tab
# ===========================================================================

$tPathLabel = New-Object System.Windows.Forms.Label
$tPathLabel.Text = "Path (file or folder)"
$tPathLabel.Location = New-Object System.Drawing.Point(16, 16)
$tPathLabel.AutoSize = $true
$tabTranscribe.Controls.Add($tPathLabel)

$tPathText = New-Object System.Windows.Forms.TextBox
$tPathText.Location = New-Object System.Drawing.Point(16, 38)
$tPathText.Size = New-Object System.Drawing.Size(600, 24)
$tabTranscribe.Controls.Add($tPathText)

$tPathBrowseFolder = New-Object System.Windows.Forms.Button
$tPathBrowseFolder.Text = "Browse Folder..."
$tPathBrowseFolder.Location = New-Object System.Drawing.Point(624, 36)
$tPathBrowseFolder.Size = New-Object System.Drawing.Size(125, 28)
$tPathBrowseFolder.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Select a folder to scan"
    if (-not [string]::IsNullOrWhiteSpace($tPathText.Text) -and (Test-Path -LiteralPath $tPathText.Text -PathType Container)) {
        $dialog.SelectedPath = $tPathText.Text
    }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $tPathText.Text = $dialog.SelectedPath
    }
})
$tabTranscribe.Controls.Add($tPathBrowseFolder)

$tPathBrowseFile = New-Object System.Windows.Forms.Button
$tPathBrowseFile.Text = "Browse File..."
$tPathBrowseFile.Location = New-Object System.Drawing.Point(755, 36)
$tPathBrowseFile.Size = New-Object System.Drawing.Size(125, 28)
$tPathBrowseFile.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Select a video file"
    $dialog.Filter = "Video files|*.mp4;*.mkv;*.avi;*.mov;*.wmv|All files|*.*"
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $tPathText.Text = $dialog.FileName
    }
})
$tabTranscribe.Controls.Add($tPathBrowseFile)

$tStatusButton = New-Object System.Windows.Forms.Button
$tStatusButton.Text = "Check Status"
$tStatusButton.Location = New-Object System.Drawing.Point(700, 124)
$tStatusButton.Size = New-Object System.Drawing.Size(110, 28)
$tabTranscribe.Controls.Add($tStatusButton)

$tStatusGauge = New-StatusGauge -Parent $tabTranscribe -X 820 -Y 116 -Size 56

$tStatusLabel = New-Object System.Windows.Forms.Label
$tStatusLabel.Text = "Not checked"
$tStatusLabel.Location = New-Object System.Drawing.Point(700, 156)
$tStatusLabel.Size = New-Object System.Drawing.Size(180, 40)
$tStatusLabel.ForeColor = [System.Drawing.Color]::DimGray
$tabTranscribe.Controls.Add($tStatusLabel)

$tStatusButton.Add_Click({
    $path = $tPathText.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
        [System.Windows.Forms.MessageBox]::Show("Enter or browse to a valid file/folder first.", "Validation", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $probeVersion = 1
    try {
        $probeMatch = [regex]::Match((Get-Content -LiteralPath $VidtranscribeScript -Raw), '\$LanguageProbeVersion\s*=\s*(\d+)')
        if ($probeMatch.Success) { $probeVersion = [int]$probeMatch.Groups[1].Value }
    }
    catch { }

    $tStatusButton.Enabled = $false
    $tStatusLabel.Text = "Scanning..."

    Start-StatusScan -ScriptBlock $transcribeScanScript -ArgumentList @($path, $probeVersion) -OnComplete {
        param($result)
        $tStatusButton.Enabled = $true
        if ($null -eq $result -or $null -ne $result.Error) {
            $tStatusLabel.Text = if ($null -ne $result -and $result.Error) { "Error: $($result.Error)" } else { "Scan failed." }
            Set-StatusGauge -Gauge $tStatusGauge -Percent 0
            return
        }
        if ($result.Total -eq 0) {
            $tStatusLabel.Text = "No .mp4 files found."
            Set-StatusGauge -Gauge $tStatusGauge -Percent 0
        }
        else {
            $tStatusLabel.Text = "$($result.UpToDate) / $($result.Total) up to date"
            Set-StatusGauge -Gauge $tStatusGauge -Percent $result.Percent
        }
    }
})

$tToolTip = New-Object System.Windows.Forms.ToolTip
$tToolTip.AutoPopDelay = 15000
$tToolTip.InitialDelay = 400
$tToolTip.ReshowDelay = 200

$tLanguageLabel = New-Object System.Windows.Forms.Label
$tLanguageLabel.Text = "Language"
$tLanguageLabel.Location = New-Object System.Drawing.Point(16, 76)
$tLanguageLabel.AutoSize = $true
$tabTranscribe.Controls.Add($tLanguageLabel)

$tLanguageText = New-Object System.Windows.Forms.TextBox
$tLanguageText.Location = New-Object System.Drawing.Point(16, 98)
$tLanguageText.Size = New-Object System.Drawing.Size(90, 24)
$tabTranscribe.Controls.Add($tLanguageText)
$tToolTip.SetToolTip($tLanguageText, "ISO 639-1 code, e.g. en, fr, ja. Leave blank to auto-detect via voice-activity probing.")

$tModelLabel = New-Object System.Windows.Forms.Label
$tModelLabel.Text = "Model"
$tModelLabel.Location = New-Object System.Drawing.Point(118, 76)
$tModelLabel.AutoSize = $true
$tabTranscribe.Controls.Add($tModelLabel)

$tModelText = New-Object System.Windows.Forms.ComboBox
$tModelText.Location = New-Object System.Drawing.Point(118, 98)
$tModelText.Size = New-Object System.Drawing.Size(110, 24)
$tModelText.Items.AddRange(@("turbo", "large-v3", "large-v2", "medium", "small", "base", "tiny"))
$tModelText.Text = "turbo"
if ($null -ne $vidtranscribeDefaults -and $vidtranscribeDefaults.PSObject.Properties.Name -contains "Model") {
    $tModelText.Text = [string]$vidtranscribeDefaults.Model
}
$tabTranscribe.Controls.Add($tModelText)
$tToolTip.SetToolTip($tModelText, "Whisper model used to transcribe. Smaller = faster/less accurate; 'turbo' (default) is a fast large-v3 distillation good for transcription. You can type a custom model name too.")

$tComputeLabel = New-Object System.Windows.Forms.Label
$tComputeLabel.Text = "Compute Type"
$tComputeLabel.Location = New-Object System.Drawing.Point(240, 76)
$tComputeLabel.AutoSize = $true
$tabTranscribe.Controls.Add($tComputeLabel)

$tComputeText = New-Object System.Windows.Forms.ComboBox
$tComputeText.Location = New-Object System.Drawing.Point(240, 98)
$tComputeText.Size = New-Object System.Drawing.Size(110, 24)
$tComputeText.Items.AddRange(@("float16", "float32", "int8", "int8_float16", "int8_float32"))
$tComputeText.Text = "float16"
if ($null -ne $vidtranscribeDefaults -and $vidtranscribeDefaults.PSObject.Properties.Name -contains "ComputeType") {
    $tComputeText.Text = [string]$vidtranscribeDefaults.ComputeType
}
$tabTranscribe.Controls.Add($tComputeText)
$tToolTip.SetToolTip($tComputeText, "Numeric precision the GPU/CPU model runs at. float16 = default GPU precision (fast, accurate). int8* = smaller/faster but slightly less accurate. float32 = full precision, needed for CPU.")

$tDeviceLabel = New-Object System.Windows.Forms.Label
$tDeviceLabel.Text = "Device"
$tDeviceLabel.Location = New-Object System.Drawing.Point(362, 76)
$tDeviceLabel.AutoSize = $true
$tabTranscribe.Controls.Add($tDeviceLabel)

$tDeviceCombo = New-Object System.Windows.Forms.ComboBox
$tDeviceCombo.Location = New-Object System.Drawing.Point(362, 98)
$tDeviceCombo.Size = New-Object System.Drawing.Size(90, 24)
$tDeviceCombo.Items.AddRange(@("cuda", "cpu"))
$tDeviceCombo.Text = "cuda"
if ($null -ne $vidtranscribeDefaults -and $vidtranscribeDefaults.PSObject.Properties.Name -contains "Device") {
    $tDeviceCombo.Text = [string]$vidtranscribeDefaults.Device
}
$tabTranscribe.Controls.Add($tDeviceCombo)

$tTranslateModelLabel = New-Object System.Windows.Forms.Label
$tTranslateModelLabel.Text = "Translate Model"
$tTranslateModelLabel.Location = New-Object System.Drawing.Point(464, 76)
$tTranslateModelLabel.AutoSize = $true
$tabTranscribe.Controls.Add($tTranslateModelLabel)

$tTranslateModelText = New-Object System.Windows.Forms.ComboBox
$tTranslateModelText.Location = New-Object System.Drawing.Point(464, 98)
$tTranslateModelText.Size = New-Object System.Drawing.Size(130, 24)
$tTranslateModelText.Items.AddRange(@("large-v3", "large-v2", "medium"))
$tTranslateModelText.Text = "large-v3"
if ($null -ne $vidtranscribeDefaults -and $vidtranscribeDefaults.PSObject.Properties.Name -contains "TranslateModel") {
    $tTranslateModelText.Text = [string]$vidtranscribeDefaults.TranslateModel
}
$tabTranscribe.Controls.Add($tTranslateModelText)
$tToolTip.SetToolTip($tTranslateModelText, "Separate model used only for non-English -> English translation. 'turbo' is deliberately excluded here: its pruned decoder gives poor translation quality, so large-v3 (default) or large-v2 is used instead.")

$tMaxFilesLabel = New-Object System.Windows.Forms.Label
$tMaxFilesLabel.Text = "Max Files"
$tMaxFilesLabel.Location = New-Object System.Drawing.Point(606, 76)
$tMaxFilesLabel.AutoSize = $true
$tabTranscribe.Controls.Add($tMaxFilesLabel)

$tMaxFilesUpDown = New-Object System.Windows.Forms.NumericUpDown
$tMaxFilesUpDown.Location = New-Object System.Drawing.Point(606, 98)
$tMaxFilesUpDown.Size = New-Object System.Drawing.Size(80, 24)
$tMaxFilesUpDown.Minimum = 0
$tMaxFilesUpDown.Maximum = 100000
$tMaxFilesUpDown.Value = 0
if ($null -ne $vidtranscribeDefaults -and $vidtranscribeDefaults.PSObject.Properties.Name -contains "MaxFiles") {
    try {
        $v = [int]$vidtranscribeDefaults.MaxFiles
        if ($v -ge 0 -and $v -le 100000) { $tMaxFilesUpDown.Value = $v }
    }
    catch { }
}
$tabTranscribe.Controls.Add($tMaxFilesUpDown)
$tToolTip.SetToolTip($tMaxFilesUpDown, "0 = unlimited (process every eligible file found).")

$tNoTranslateCheck = New-Object System.Windows.Forms.CheckBox
$tNoTranslateCheck.Text = "Disable auto-translate to English"
$tNoTranslateCheck.Location = New-Object System.Drawing.Point(16, 138)
$tNoTranslateCheck.AutoSize = $true
if ($null -ne $vidtranscribeDefaults -and $vidtranscribeDefaults.PSObject.Properties.Name -contains "AutoTranslate") {
    $tNoTranslateCheck.Checked = -not [bool]$vidtranscribeDefaults.AutoTranslate
}
$tabTranscribe.Controls.Add($tNoTranslateCheck)

$tDryRunCheck = New-Object System.Windows.Forms.CheckBox
$tDryRunCheck.Text = "Dry Run (preview only)"
$tDryRunCheck.Location = New-Object System.Drawing.Point(16, 165)
$tDryRunCheck.AutoSize = $true
$tabTranscribe.Controls.Add($tDryRunCheck)

$tNoteLabel = New-Object System.Windows.Forms.Label
$tNoteLabel.Text = "ModelsPath / DockerImage / WorkerPort are read from vidtranscribe\options.json (not exposed here)."
$tNoteLabel.Location = New-Object System.Drawing.Point(16, 225)
$tNoteLabel.AutoSize = $true
$tNoteLabel.ForeColor = [System.Drawing.Color]::DimGray
$tabTranscribe.Controls.Add($tNoteLabel)

$tWorkerNoteLabel = New-Object System.Windows.Forms.Label
$tWorkerNoteLabel.Text = "Transcribe runs a persistent GPU worker container; Cancel stops this script only - the worker keeps running (and finishes any in-flight file) for faster reuse next run."
$tWorkerNoteLabel.Location = New-Object System.Drawing.Point(16, 245)
$tWorkerNoteLabel.AutoSize = $true
$tWorkerNoteLabel.MaximumSize = New-Object System.Drawing.Size(860, 0)
$tWorkerNoteLabel.ForeColor = [System.Drawing.Color]::DimGray
$tabTranscribe.Controls.Add($tWorkerNoteLabel)

# ===========================================================================
# Tag tab
# ===========================================================================

$gScanLabel = New-Object System.Windows.Forms.Label
$gScanLabel.Text = "Scan Path"
$gScanLabel.Location = New-Object System.Drawing.Point(16, 16)
$gScanLabel.AutoSize = $true
$tabTag.Controls.Add($gScanLabel)

$gScanText = New-Object System.Windows.Forms.TextBox
$gScanText.Location = New-Object System.Drawing.Point(16, 38)
$gScanText.Size = New-Object System.Drawing.Size(600, 24)
if ($null -ne $vidtagDefaults -and $vidtagDefaults.PSObject.Properties.Name -contains "ScanPath") {
    $gScanText.Text = [string]$vidtagDefaults.ScanPath
}
$tabTag.Controls.Add($gScanText)

$gScanBrowse = New-Object System.Windows.Forms.Button
$gScanBrowse.Text = "Browse..."
$gScanBrowse.Location = New-Object System.Drawing.Point(624, 36)
$gScanBrowse.Size = New-Object System.Drawing.Size(125, 28)
$gScanBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Select folder to scan for .vidtranscribe.json files"
    if (-not [string]::IsNullOrWhiteSpace($gScanText.Text) -and (Test-Path -LiteralPath $gScanText.Text -PathType Container)) {
        $dialog.SelectedPath = $gScanText.Text
    }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $gScanText.Text = $dialog.SelectedPath
    }
})
$tabTag.Controls.Add($gScanBrowse)

$gStatusButton = New-Object System.Windows.Forms.Button
$gStatusButton.Text = "Check Status"
$gStatusButton.Location = New-Object System.Drawing.Point(700, 76)
$gStatusButton.Size = New-Object System.Drawing.Size(120, 28)
$tabTag.Controls.Add($gStatusButton)

$gStatusGauge = New-StatusGauge -Parent $tabTag -X 820 -Y 70 -Size 56

$gStatusLabel = New-Object System.Windows.Forms.Label
$gStatusLabel.Text = "Not checked"
$gStatusLabel.Location = New-Object System.Drawing.Point(700, 106)
$gStatusLabel.Size = New-Object System.Drawing.Size(176, 28)
$gStatusLabel.ForeColor = [System.Drawing.Color]::DimGray
$tabTag.Controls.Add($gStatusLabel)

$gStatusButton.Add_Click({
    $path = $gScanText.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show("Enter or browse to a valid scan folder first.", "Validation", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $gStatusButton.Enabled = $false
    $gStatusLabel.Text = "Scanning..."

    Start-StatusScan -ScriptBlock $tagScanScript -ArgumentList @($path) -OnComplete {
        param($result)
        $gStatusButton.Enabled = $true
        if ($null -eq $result -or $null -ne $result.Error) {
            $gStatusLabel.Text = if ($null -ne $result -and $result.Error) { "Error: $($result.Error)" } else { "Scan failed." }
            Set-StatusGauge -Gauge $gStatusGauge -Percent 0
            return
        }
        if ($result.Eligible -eq 0) {
            $gStatusLabel.Text = "No taggable files found."
            Set-StatusGauge -Gauge $gStatusGauge -Percent 0
        }
        else {
            $gStatusLabel.Text = "$($result.Processed) / $($result.Eligible) tagged"
            Set-StatusGauge -Gauge $gStatusGauge -Percent $result.Percent
        }
    }
})

$gMaxFilesLabel = New-Object System.Windows.Forms.Label
$gMaxFilesLabel.Text = "Max Files (0 = unlimited)"
$gMaxFilesLabel.Location = New-Object System.Drawing.Point(16, 76)
$gMaxFilesLabel.AutoSize = $true
$tabTag.Controls.Add($gMaxFilesLabel)

$gMaxFilesUpDown = New-Object System.Windows.Forms.NumericUpDown
$gMaxFilesUpDown.Location = New-Object System.Drawing.Point(16, 98)
$gMaxFilesUpDown.Size = New-Object System.Drawing.Size(100, 24)
$gMaxFilesUpDown.Minimum = 0
$gMaxFilesUpDown.Maximum = 100000
$gMaxFilesUpDown.Value = 0
if ($null -ne $vidtagDefaults -and $vidtagDefaults.PSObject.Properties.Name -contains "MaxFiles") {
    try {
        $v = [int]$vidtagDefaults.MaxFiles
        if ($v -ge 0 -and $v -le 100000) { $gMaxFilesUpDown.Value = $v }
    }
    catch { }
}
$tabTag.Controls.Add($gMaxFilesUpDown)

$gAllowNewTagsCheck = New-Object System.Windows.Forms.CheckBox
$gAllowNewTagsCheck.Text = "Allow new tags (accept LLM suggestions outside existing vocabulary)"
$gAllowNewTagsCheck.Location = New-Object System.Drawing.Point(16, 138)
$gAllowNewTagsCheck.AutoSize = $true
if ($null -ne $vidtagDefaults -and $vidtagDefaults.PSObject.Properties.Name -contains "AllowNewTags") {
    $gAllowNewTagsCheck.Checked = [bool]$vidtagDefaults.AllowNewTags
}
$tabTag.Controls.Add($gAllowNewTagsCheck)

$gGenerateDescriptionCheck = New-Object System.Windows.Forms.CheckBox
$gGenerateDescriptionCheck.Text = "Generate plot description (when <plot> is empty)"
$gGenerateDescriptionCheck.Location = New-Object System.Drawing.Point(16, 165)
$gGenerateDescriptionCheck.AutoSize = $true
if ($null -ne $vidtagDefaults -and $vidtagDefaults.PSObject.Properties.Name -contains "GenerateDescription") {
    $gGenerateDescriptionCheck.Checked = [bool]$vidtagDefaults.GenerateDescription
}
$tabTag.Controls.Add($gGenerateDescriptionCheck)

$gUseVisualsCheck = New-Object System.Windows.Forms.CheckBox
$gUseVisualsCheck.Text = "Use visuals (extract screenshots, send to a vision model)"
$gUseVisualsCheck.Location = New-Object System.Drawing.Point(16, 192)
$gUseVisualsCheck.AutoSize = $true
if ($null -ne $vidtagDefaults -and $vidtagDefaults.PSObject.Properties.Name -contains "UseVisuals") {
    $gUseVisualsCheck.Checked = [bool]$vidtagDefaults.UseVisuals
}
$tabTag.Controls.Add($gUseVisualsCheck)

$gRefreshVocabCheck = New-Object System.Windows.Forms.CheckBox
$gRefreshVocabCheck.Text = "Force refresh Jellyfin tag/genre vocabulary (ignore cache age)"
$gRefreshVocabCheck.Location = New-Object System.Drawing.Point(16, 219)
$gRefreshVocabCheck.AutoSize = $true
$tabTag.Controls.Add($gRefreshVocabCheck)

$gRefreshLibraryCheck = New-Object System.Windows.Forms.CheckBox
$gRefreshLibraryCheck.Text = "Refresh Jellyfin library at end of run (if any file was tagged)"
$gRefreshLibraryCheck.Location = New-Object System.Drawing.Point(460, 138)
$gRefreshLibraryCheck.AutoSize = $true
if ($null -ne $vidtagDefaults -and $vidtagDefaults.PSObject.Properties.Name -contains "RefreshJellyfinLibrary") {
    $gRefreshLibraryCheck.Checked = [bool]$vidtagDefaults.RefreshJellyfinLibrary
}
$tabTag.Controls.Add($gRefreshLibraryCheck)

$gDryRunCheck = New-Object System.Windows.Forms.CheckBox
$gDryRunCheck.Text = "Dry Run (preview only - no files changed)"
$gDryRunCheck.Location = New-Object System.Drawing.Point(460, 165)
$gDryRunCheck.AutoSize = $true
$tabTag.Controls.Add($gDryRunCheck)

# ===========================================================================
# Shared bottom panel: Run / Cancel / progress bar / status / output
# ===========================================================================

$noteLabel = New-Object System.Windows.Forms.Label
$noteLabel.Text = "Both tools always run with -NoConfirm here (no interactive Y/N prompt)."
$noteLabel.Location = New-Object System.Drawing.Point(12, 350)
$noteLabel.AutoSize = $true
$noteLabel.ForeColor = [System.Drawing.Color]::DimGray
$noteLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
$form.Controls.Add($noteLabel)

$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = "Run"
$runButton.Location = New-Object System.Drawing.Point(12, 376)
$runButton.Size = New-Object System.Drawing.Size(110, 32)
$runButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
$form.Controls.Add($runButton)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = "Cancel"
$cancelButton.Location = New-Object System.Drawing.Point(130, 376)
$cancelButton.Size = New-Object System.Drawing.Size(110, 32)
$cancelButton.Enabled = $false
$cancelButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
$form.Controls.Add($cancelButton)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Ready"
$statusLabel.Location = New-Object System.Drawing.Point(255, 384)
$statusLabel.AutoSize = $true
$statusLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
$form.Controls.Add($statusLabel)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(12, 416)
$progressBar.Size = New-Object System.Drawing.Size(900, 22)
$progressBar.Minimum = 0
$progressBar.Maximum = 1
$progressBar.Value = 0
$progressBar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($progressBar)

$outputText = New-Object System.Windows.Forms.TextBox
$outputText.Location = New-Object System.Drawing.Point(12, 446)
$outputText.Size = New-Object System.Drawing.Size(900, 220)
$outputText.Multiline = $true
$outputText.ScrollBars = "Both"
$outputText.ReadOnly = $true
$outputText.WordWrap = $false
$outputText.Font = New-Object System.Drawing.Font("Consolas", 9)
$outputText.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($outputText)

# ---------------------------------------------------------------------------
# Shared process-running engine
# ---------------------------------------------------------------------------
#
# Output is streamed live. NOTE: Register-ObjectEvent's -Action scriptblock is
# dispatched through PowerShell's own engine event queue, which is only
# processed when the engine is idle between statements. Because this script's
# main thread never returns from $form.ShowDialog() while the form is open,
# that queue is never drained and no output would ever appear (verified via a
# minimal repro). Instead, two dedicated background [powershell] runspaces do
# a plain blocking ReadLine() loop over the child's stdout/stderr streams and
# push lines into a thread-safe queue - this runs on the .NET thread pool,
# independent of the main engine thread's idle state. A UI-thread timer then
# drains the queue, appends to the output box, and updates the shared
# progress bar/status label by parsing the PROGRESS|.../SUMMARY|... protocol
# common to both tools.

$script:runState = [PSCustomObject]@{
    Process     = $null
    OutReader   = $null
    ErrReader   = $null
    Queue       = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    LastTotal   = 0
    LastIndex   = 0
    FileStartTimes  = @{}
    FileDurations   = [System.Collections.Generic.List[double]]::new()
}

function Stop-StreamReader {
    param($Reader)

    if ($null -eq $Reader) { return }
    try {
        # By the time this is called the child process has exited (or been
        # killed), so its stdout/stderr streams are already closed and the
        # reader loop's ReadLine() will have hit EOF almost immediately -
        # this EndInvoke should return promptly, not block indefinitely.
        [void]$Reader.PowerShell.EndInvoke($Reader.Handle)
    }
    catch { }
    finally {
        $Reader.PowerShell.Dispose()
    }
}

$outputTimer = New-Object System.Windows.Forms.Timer
$outputTimer.Interval = 150

function Add-OutputLine {
    param([string]$Line)

    if ($outputText.TextLength -gt 0) {
        $outputText.AppendText([Environment]::NewLine)
    }
    $outputText.AppendText($Line)
}

function Format-Eta {
    param([double]$Seconds)

    if ($Seconds -lt 0) { $Seconds = 0 }
    $ts = [TimeSpan]::FromSeconds($Seconds)
    if ($ts.TotalHours -ge 1) {
        return "{0}h {1}m" -f [int]$ts.TotalHours, $ts.Minutes
    }
    elseif ($ts.TotalMinutes -ge 1) {
        return "{0}m {1}s" -f [int]$ts.TotalMinutes, $ts.Seconds
    }
    else {
        return "{0}s" -f [int][Math]::Ceiling($ts.TotalSeconds)
    }
}

function Update-ProgressFromLine {
    param([string]$Line)

    if ($Line -match '^PROGRESS\|') {
        $map = ConvertFrom-PipeLine -Line $Line
        $total = 0
        $index = 0
        if ($map.ContainsKey("total")) { [void][int]::TryParse($map["total"], [ref]$total) }
        if ($map.ContainsKey("index")) { [void][int]::TryParse($map["index"], [ref]$index) }
        $event = if ($map.ContainsKey("event")) { $map["event"] } else { "" }

        if ($event -eq "start" -and $index -gt 0) {
            $script:runState.FileStartTimes[$index] = Get-Date
        }
        elseif ($event -eq "complete" -and $index -gt 0) {
            $startedAt = $script:runState.FileStartTimes[$index]
            if ($null -ne $startedAt) {
                $elapsed = ((Get-Date) - $startedAt).TotalSeconds
                if ($elapsed -gt 0) { [void]$script:runState.FileDurations.Add($elapsed) }
                $script:runState.FileStartTimes.Remove($index)
            }
        }

        if ($total -gt 0) {
            if ($progressBar.Maximum -ne $total) { $progressBar.Maximum = $total }
            $completed = $index
            if ($event -eq "start") { $completed = $index - 1 }
            if ($completed -lt 0) { $completed = 0 }
            if ($completed -gt $total) { $completed = $total }
            $progressBar.Value = $completed
        }

        $fileLabel = if ($map.ContainsKey("file")) { $map["file"] } else { "" }
        if ($total -gt 0) {
            $remaining = $total - $completed
            $etaText = ""
            if ($remaining -gt 0) {
                if ($script:runState.FileDurations.Count -gt 0) {
                    $avgSeconds = ($script:runState.FileDurations | Measure-Object -Average).Average
                    $etaText = " (ETA: ~{0})" -f (Format-Eta -Seconds ($avgSeconds * $remaining))
                }
                else {
                    $etaText = " (estimating...)"
                }
            }
            $statusLabel.Text = "Processing $index/$total`: $fileLabel$etaText"
        }
    }
    elseif ($Line -match '^SUMMARY\|') {
        $map = ConvertFrom-PipeLine -Line $Line
        $status = if ($map.ContainsKey("status")) { $map["status"] } else { "unknown" }
        switch ($status) {
            "ok"      { $statusLabel.Text = "Done (status=ok)"; $progressBar.Value = $progressBar.Maximum }
            "noop"    { $statusLabel.Text = "Done (nothing to process)"; $progressBar.Value = $progressBar.Maximum }
            "aborted" { $statusLabel.Text = "Aborted" }
            "failed"  { $statusLabel.Text = "Failed (see output)" }
            default   { $statusLabel.Text = "Finished (status=$status)" }
        }
    }
}

$outputTimer.Add_Tick({
    try {
        $line = $null
        $drained = 0
        while ($script:runState.Queue.TryDequeue([ref]$line) -and $drained -lt 200) {
            Add-OutputLine -Line $line
            Update-ProgressFromLine -Line $line
            Write-VidUiLog ("CHILD: {0}" -f $line)
            $drained++
        }

        $proc = $script:runState.Process
        if ($null -ne $proc -and $proc.HasExited) {
            # Drain anything left before finishing up.
            while ($script:runState.Queue.TryDequeue([ref]$line)) {
                Add-OutputLine -Line $line
                Update-ProgressFromLine -Line $line
                Write-VidUiLog ("CHILD: {0}" -f $line)
            }

            $outputTimer.Stop()
            Stop-StreamReader -Reader $script:runState.OutReader
            Stop-StreamReader -Reader $script:runState.ErrReader
            $script:runState.OutReader = $null
            $script:runState.ErrReader = $null
            $exitCode = $proc.ExitCode
            if ($statusLabel.Text -notmatch '^(Done|Aborted|Failed|Finished)') {
                if ($exitCode -eq 0) {
                    $statusLabel.Text = "Done (ExitCode 0)"
                }
                else {
                    $statusLabel.Text = "Failed (ExitCode $exitCode)"
                }
            }
            Write-VidUiLog ("Process exited. ExitCode={0} FinalStatus={1}" -f $exitCode, $statusLabel.Text)
            $script:runState.Process = $null
            $runButton.Enabled = $true
            $cancelButton.Enabled = $false
            $tabControl.Enabled = $true
        }
    }
    catch {
        $outputTimer.Stop()
        $script:runState.Process = $null
        $runButton.Enabled = $true
        $cancelButton.Enabled = $false
        $tabControl.Enabled = $true
        Show-VidUiError -Message ("An unexpected error occurred while monitoring the running tool:`n`n{0}" -f $_.Exception.Message) -Title "vidui - Run monitor error"
    }
})

function Start-ToolRun {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    try {
        if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
            Show-VidUiError -Message "Cannot find script: $ScriptPath" -Title "vidui - Script not found"
            return
        }

        $exe = Get-PowerShellExe
        $scriptPathResolved = (Resolve-Path -LiteralPath $ScriptPath).Path

        $fullArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Escape-Argument -Value $scriptPathResolved)) + $Arguments
        $commandLine = $fullArgs -join " "
        Write-VidUiLog ("Starting: {0} {1}" -f $exe, $commandLine)

        $outputText.Clear()
        $progressBar.Value = 0
        $progressBar.Maximum = 1
        $script:runState.FileStartTimes = @{}
        $script:runState.FileDurations = [System.Collections.Generic.List[double]]::new()
        $statusLabel.Text = "Running..."
        $runButton.Enabled = $false
        $cancelButton.Enabled = $true
        $tabControl.Enabled = $false

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $exe
        $psi.Arguments              = $commandLine
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi

        $queueRef = $script:runState.Queue

        # Plain blocking ReadLine() loop, executed on a dedicated background
        # runspace so it runs independent of the main thread being blocked
        # inside ShowDialog(). See the comment above $script:runState.
        $readerScript = {
            param($reader, $queue)
            $line = $reader.ReadLine()
            while ($null -ne $line) {
                $queue.Enqueue($line)
                $line = $reader.ReadLine()
            }
        }

        [void]$process.Start()

        $outPs = [powershell]::Create()
        [void]$outPs.AddScript($readerScript).AddArgument($process.StandardOutput).AddArgument($queueRef)
        $script:runState.OutReader = [PSCustomObject]@{ PowerShell = $outPs; Handle = $outPs.BeginInvoke() }

        $errPs = [powershell]::Create()
        [void]$errPs.AddScript($readerScript).AddArgument($process.StandardError).AddArgument($queueRef)
        $script:runState.ErrReader = [PSCustomObject]@{ PowerShell = $errPs; Handle = $errPs.BeginInvoke() }

        $script:runState.Process = $process
        $outputTimer.Start()
    }
    catch {
        $runButton.Enabled = $true
        $cancelButton.Enabled = $false
        $tabControl.Enabled = $true
        Show-VidUiError -Message ("Failed to start the tool process:`n`n{0}" -f $_.Exception.Message) -Title "vidui - Failed to start"
    }
}

$cancelButton.Add_Click({
    try {
        $proc = $script:runState.Process
        if ($null -ne $proc -and -not $proc.HasExited) {
            # Use taskkill for a reliable process-tree kill across both
            # Windows PowerShell 5.1 and PowerShell 7+ hosts.
            Start-Process -FilePath "taskkill.exe" -ArgumentList @("/PID", $proc.Id, "/T", "/F") -WindowStyle Hidden -Wait | Out-Null
            $statusLabel.Text = "Cancelled"
            Write-VidUiLog "Run cancelled by user."
        }
    }
    catch {
        Write-VidUiLog ("[WARN] Cancel failed: {0}" -f $_.Exception.Message)
    }
})

# ---------------------------------------------------------------------------
# Run button click handler: dispatches to the active tab's tool
# ---------------------------------------------------------------------------

$runButton.Add_Click({
  try {
    if ($tabControl.SelectedTab -eq $tabTranscribe) {
        $path = $tPathText.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($path)) {
            [System.Windows.Forms.MessageBox]::Show("Path is required.", "Validation", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if (-not (Test-Path -LiteralPath $path)) {
            [System.Windows.Forms.MessageBox]::Show("Path does not exist.", "Validation", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $arguments = @(
            "-Path", (Escape-Argument -Value $path)
            "-MaxFiles", [int]$tMaxFilesUpDown.Value
            "-NoConfirm"
        )
        if (-not [string]::IsNullOrWhiteSpace($tLanguageText.Text)) { $arguments += @("-Language", (Escape-Argument -Value $tLanguageText.Text.Trim())) }
        if (-not [string]::IsNullOrWhiteSpace($tModelText.Text))    { $arguments += @("-Model", (Escape-Argument -Value $tModelText.Text.Trim())) }
        if (-not [string]::IsNullOrWhiteSpace($tComputeText.Text))  { $arguments += @("-ComputeType", (Escape-Argument -Value $tComputeText.Text.Trim())) }
        if (-not [string]::IsNullOrWhiteSpace($tDeviceCombo.Text))  { $arguments += @("-Device", (Escape-Argument -Value $tDeviceCombo.Text.Trim())) }
        if (-not [string]::IsNullOrWhiteSpace($tTranslateModelText.Text)) { $arguments += @("-TranslateModel", (Escape-Argument -Value $tTranslateModelText.Text.Trim())) }
        if ($tNoTranslateCheck.Checked) { $arguments += "-NoTranslate" }
        if ($tDryRunCheck.Checked)      { $arguments += "-DryRun" }

        Start-ToolRun -ScriptPath $VidtranscribeScript -Arguments $arguments
    }
    else {
        $scanPath = $gScanText.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($scanPath)) {
            [System.Windows.Forms.MessageBox]::Show("Scan path is required.", "Validation", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if (-not (Test-Path -LiteralPath $scanPath -PathType Container)) {
            [System.Windows.Forms.MessageBox]::Show("Scan path does not exist.", "Validation", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $arguments = @(
            "-ScanPath", (Escape-Argument -Value $scanPath)
            "-MaxFiles", [int]$gMaxFilesUpDown.Value
            "-NoConfirm"
        )
        if ($gAllowNewTagsCheck.Checked)         { $arguments += "-AllowNewTags" }
        if ($gGenerateDescriptionCheck.Checked)  { $arguments += "-GenerateDescription" }
        if ($gUseVisualsCheck.Checked)           { $arguments += "-UseVisuals" }
        if ($gRefreshVocabCheck.Checked)         { $arguments += "-RefreshVocabulary" }
        if ($gRefreshLibraryCheck.Checked)       { $arguments += "-RefreshJellyfinLibrary" }
        if ($gDryRunCheck.Checked)               { $arguments += "-DryRun" }

        Start-ToolRun -ScriptPath $VidtagScript -Arguments $arguments
    }
  }
  catch {
    Show-VidUiError -Message ("An unexpected error occurred while starting the run:`n`n{0}" -f $_.Exception.Message) -Title "vidui - Run button error"
  }
})

$form.Add_FormClosing({
    $proc = $script:runState.Process
    if ($null -ne $proc -and -not $proc.HasExited) {
        try { Start-Process -FilePath "taskkill.exe" -ArgumentList @("/PID", $proc.Id, "/T", "/F") -WindowStyle Hidden -Wait | Out-Null } catch { }
    }
    Write-VidUiLog "vidui closing."
})

# ---------------------------------------------------------------------------
# Global unhandled-exception safety net.
#
# Without this, an exception thrown inside a WinForms event handler that
# isn't otherwise caught can silently terminate the whole app (the window
# just disappears) with no visible error and nothing logged. These handlers
# make sure that, whatever else happens, we log the failure and try to show
# the user something before giving up.
# ---------------------------------------------------------------------------

[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    Write-VidUiLog ("[FATAL] Unhandled UI thread exception: {0}" -f $e.Exception)
    try {
        [System.Windows.Forms.MessageBox]::Show(
            ("An unexpected error occurred:`n`n{0}`n`nDetails logged to:`n{1}" -f $e.Exception.Message, $script:VidUiLogPath),
            "vidui - Unexpected error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    catch { }
})

[System.AppDomain]::CurrentDomain.add_UnhandledException({
    param($sender, $e)
    Write-VidUiLog ("[FATAL] Unhandled non-UI exception (process will terminate): {0}" -f $e.ExceptionObject)
})

[void]$form.ShowDialog()
