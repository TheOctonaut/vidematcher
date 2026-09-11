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
    param([Parameter(Mandatory = $true)][string]$Value)
    return '"' + $Value.Replace('"', '""') + '"'
}

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

$tLanguageLabel = New-Object System.Windows.Forms.Label
$tLanguageLabel.Text = "Language (blank = auto-detect)"
$tLanguageLabel.Location = New-Object System.Drawing.Point(16, 76)
$tLanguageLabel.AutoSize = $true
$tabTranscribe.Controls.Add($tLanguageLabel)

$tLanguageText = New-Object System.Windows.Forms.TextBox
$tLanguageText.Location = New-Object System.Drawing.Point(16, 98)
$tLanguageText.Size = New-Object System.Drawing.Size(120, 24)
$tabTranscribe.Controls.Add($tLanguageText)

$tModelLabel = New-Object System.Windows.Forms.Label
$tModelLabel.Text = "Model"
$tModelLabel.Location = New-Object System.Drawing.Point(160, 76)
$tModelLabel.AutoSize = $true
$tabTranscribe.Controls.Add($tModelLabel)

$tModelText = New-Object System.Windows.Forms.TextBox
$tModelText.Location = New-Object System.Drawing.Point(160, 98)
$tModelText.Size = New-Object System.Drawing.Size(120, 24)
$tModelText.Text = "turbo"
if ($null -ne $vidtranscribeDefaults -and $vidtranscribeDefaults.PSObject.Properties.Name -contains "Model") {
    $tModelText.Text = [string]$vidtranscribeDefaults.Model
}
$tabTranscribe.Controls.Add($tModelText)

$tComputeLabel = New-Object System.Windows.Forms.Label
$tComputeLabel.Text = "Compute Type"
$tComputeLabel.Location = New-Object System.Drawing.Point(304, 76)
$tComputeLabel.AutoSize = $true
$tabTranscribe.Controls.Add($tComputeLabel)

$tComputeText = New-Object System.Windows.Forms.TextBox
$tComputeText.Location = New-Object System.Drawing.Point(304, 98)
$tComputeText.Size = New-Object System.Drawing.Size(120, 24)
$tComputeText.Text = "float16"
if ($null -ne $vidtranscribeDefaults -and $vidtranscribeDefaults.PSObject.Properties.Name -contains "ComputeType") {
    $tComputeText.Text = [string]$vidtranscribeDefaults.ComputeType
}
$tabTranscribe.Controls.Add($tComputeText)

$tDeviceLabel = New-Object System.Windows.Forms.Label
$tDeviceLabel.Text = "Device"
$tDeviceLabel.Location = New-Object System.Drawing.Point(448, 76)
$tDeviceLabel.AutoSize = $true
$tabTranscribe.Controls.Add($tDeviceLabel)

$tDeviceCombo = New-Object System.Windows.Forms.ComboBox
$tDeviceCombo.Location = New-Object System.Drawing.Point(448, 98)
$tDeviceCombo.Size = New-Object System.Drawing.Size(100, 24)
$tDeviceCombo.Items.AddRange(@("cuda", "cpu"))
$tDeviceCombo.Text = "cuda"
if ($null -ne $vidtranscribeDefaults -and $vidtranscribeDefaults.PSObject.Properties.Name -contains "Device") {
    $tDeviceCombo.Text = [string]$vidtranscribeDefaults.Device
}
$tabTranscribe.Controls.Add($tDeviceCombo)

$tMaxFilesLabel = New-Object System.Windows.Forms.Label
$tMaxFilesLabel.Text = "Max Files (0 = unlimited)"
$tMaxFilesLabel.Location = New-Object System.Drawing.Point(568, 76)
$tMaxFilesLabel.AutoSize = $true
$tabTranscribe.Controls.Add($tMaxFilesLabel)

$tMaxFilesUpDown = New-Object System.Windows.Forms.NumericUpDown
$tMaxFilesUpDown.Location = New-Object System.Drawing.Point(568, 98)
$tMaxFilesUpDown.Size = New-Object System.Drawing.Size(90, 24)
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
$tNoteLabel.Text = "ModelsPath / DockerImage are read from vidtranscribe\options.json (not exposed here)."
$tNoteLabel.Location = New-Object System.Drawing.Point(16, 200)
$tNoteLabel.AutoSize = $true
$tNoteLabel.ForeColor = [System.Drawing.Color]::DimGray
$tabTranscribe.Controls.Add($tNoteLabel)

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
# Output is streamed live: OutputDataReceived/ErrorDataReceived fire on a
# background thread, so lines are pushed into a thread-safe queue rather than
# touching WinForms controls directly. A UI-thread timer drains the queue,
# appends to the output box, and updates the shared progress bar/status label
# by parsing the PROGRESS|.../SUMMARY|... protocol common to both tools.

$script:runState = [PSCustomObject]@{
    Process     = $null
    Queue       = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    LastTotal   = 0
    LastIndex   = 0
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

function Update-ProgressFromLine {
    param([string]$Line)

    if ($Line -match '^PROGRESS\|') {
        $map = ConvertFrom-PipeLine -Line $Line
        $total = 0
        $index = 0
        if ($map.ContainsKey("total")) { [void][int]::TryParse($map["total"], [ref]$total) }
        if ($map.ContainsKey("index")) { [void][int]::TryParse($map["index"], [ref]$index) }

        if ($total -gt 0) {
            if ($progressBar.Maximum -ne $total) { $progressBar.Maximum = $total }
            $completed = $index
            if ($map["event"] -eq "start") { $completed = $index - 1 }
            if ($completed -lt 0) { $completed = 0 }
            if ($completed -gt $total) { $completed = $total }
            $progressBar.Value = $completed
        }

        $fileLabel = if ($map.ContainsKey("file")) { $map["file"] } else { "" }
        if ($total -gt 0) {
            $statusLabel.Text = "Processing $index/$total`: $fileLabel"
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
    $line = $null
    $drained = 0
    while ($script:runState.Queue.TryDequeue([ref]$line) -and $drained -lt 200) {
        Add-OutputLine -Line $line
        Update-ProgressFromLine -Line $line
        $drained++
    }

    $proc = $script:runState.Process
    if ($null -ne $proc -and $proc.HasExited) {
        # Drain anything left before finishing up.
        while ($script:runState.Queue.TryDequeue([ref]$line)) {
            Add-OutputLine -Line $line
            Update-ProgressFromLine -Line $line
        }

        $outputTimer.Stop()
        $exitCode = $proc.ExitCode
        if ($statusLabel.Text -notmatch '^(Done|Aborted|Failed|Finished)') {
            if ($exitCode -eq 0) {
                $statusLabel.Text = "Done (ExitCode 0)"
            }
            else {
                $statusLabel.Text = "Failed (ExitCode $exitCode)"
            }
        }
        $script:runState.Process = $null
        $runButton.Enabled = $true
        $cancelButton.Enabled = $false
        $tabControl.Enabled = $true
    }
})

function Start-ToolRun {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show("Cannot find script: $ScriptPath", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }

    $exe = Get-PowerShellExe
    $scriptPathResolved = (Resolve-Path -LiteralPath $ScriptPath).Path

    $fullArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Escape-Argument -Value $scriptPathResolved)) + $Arguments

    $outputText.Clear()
    $progressBar.Value = 0
    $progressBar.Maximum = 1
    $statusLabel.Text = "Running..."
    $runButton.Enabled = $false
    $cancelButton.Enabled = $true
    $tabControl.Enabled = $false

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $exe
    $psi.Arguments              = ($fullArgs -join " ")
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $process.EnableRaisingEvents = $true

    $queueRef = $script:runState.Queue

    Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action {
        if ($null -ne $Event.SourceEventArgs.Data) {
            $Event.MessageData.Enqueue($Event.SourceEventArgs.Data)
        }
    } -MessageData $queueRef | Out-Null

    Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -Action {
        if ($null -ne $Event.SourceEventArgs.Data) {
            $Event.MessageData.Enqueue($Event.SourceEventArgs.Data)
        }
    } -MessageData $queueRef | Out-Null

    [void]$process.Start()
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()

    $script:runState.Process = $process
    $outputTimer.Start()
}

$cancelButton.Add_Click({
    $proc = $script:runState.Process
    if ($null -ne $proc -and -not $proc.HasExited) {
        try {
            # Use taskkill for a reliable process-tree kill across both
            # Windows PowerShell 5.1 and PowerShell 7+ hosts.
            Start-Process -FilePath "taskkill.exe" -ArgumentList @("/PID", $proc.Id, "/T", "/F") -WindowStyle Hidden -Wait | Out-Null
        }
        catch { }
        $statusLabel.Text = "Cancelled"
    }
})

# ---------------------------------------------------------------------------
# Run button click handler: dispatches to the active tab's tool
# ---------------------------------------------------------------------------

$runButton.Add_Click({
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
})

$form.Add_FormClosing({
    $proc = $script:runState.Process
    if ($null -ne $proc -and -not $proc.HasExited) {
        try { Start-Process -FilePath "taskkill.exe" -ArgumentList @("/PID", $proc.Id, "/T", "/F") -WindowStyle Hidden -Wait | Out-Null } catch { }
    }
})

[void]$form.ShowDialog()
