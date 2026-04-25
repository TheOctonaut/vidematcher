param(
    [Parameter(Mandatory = $false)]
    [string]$ScriptPath
)

$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $PSCommandPath
}
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $ScriptPath = Join-Path $scriptRoot "vidpicker.ps1"
}

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

if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    throw "Cannot find vidpicker script: $ScriptPath"
}

$scriptPathResolved = (Resolve-Path -LiteralPath $ScriptPath).Path
$optionsPath = Join-Path $scriptRoot "options.json"
$defaults = Load-OptionsDefaults -OptionsPath $optionsPath

$form = New-Object System.Windows.Forms.Form
$form.Text = "vidpicker"
$form.Size = New-Object System.Drawing.Size(900, 580)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(900, 580)

$font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Font = $font

# ---------------------------------------------------------------------------
# Source folder row
# ---------------------------------------------------------------------------

$sourceLabel = New-Object System.Windows.Forms.Label
$sourceLabel.Text = "Source Folder"
$sourceLabel.Location = New-Object System.Drawing.Point(20, 20)
$sourceLabel.AutoSize = $true
$form.Controls.Add($sourceLabel)

$sourceText = New-Object System.Windows.Forms.TextBox
$sourceText.Location = New-Object System.Drawing.Point(20, 42)
$sourceText.Size = New-Object System.Drawing.Size(730, 24)
if ($null -ne $defaults -and $defaults.PSObject.Properties.Name -contains "SourceDir") {
    $sourceText.Text = [string]$defaults.SourceDir
}
$form.Controls.Add($sourceText)

$sourceBrowse = New-Object System.Windows.Forms.Button
$sourceBrowse.Text = "Browse..."
$sourceBrowse.Location = New-Object System.Drawing.Point(760, 40)
$sourceBrowse.Size = New-Object System.Drawing.Size(110, 28)
$sourceBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Select source folder"
    if (-not [string]::IsNullOrWhiteSpace($sourceText.Text) -and (Test-Path -LiteralPath $sourceText.Text -PathType Container)) {
        $dialog.SelectedPath = $sourceText.Text
    }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $sourceText.Text = $dialog.SelectedPath
    }
})
$form.Controls.Add($sourceBrowse)

# ---------------------------------------------------------------------------
# Destination folder row
# ---------------------------------------------------------------------------

$destLabel = New-Object System.Windows.Forms.Label
$destLabel.Text = "Destination Folder"
$destLabel.Location = New-Object System.Drawing.Point(20, 80)
$destLabel.AutoSize = $true
$form.Controls.Add($destLabel)

$destText = New-Object System.Windows.Forms.TextBox
$destText.Location = New-Object System.Drawing.Point(20, 102)
$destText.Size = New-Object System.Drawing.Size(730, 24)
if ($null -ne $defaults -and $defaults.PSObject.Properties.Name -contains "DestDir") {
    $destText.Text = [string]$defaults.DestDir
}
$form.Controls.Add($destText)

$destBrowse = New-Object System.Windows.Forms.Button
$destBrowse.Text = "Browse..."
$destBrowse.Location = New-Object System.Drawing.Point(760, 100)
$destBrowse.Size = New-Object System.Drawing.Size(110, 28)
$destBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Select destination folder"
    if (-not [string]::IsNullOrWhiteSpace($destText.Text) -and (Test-Path -LiteralPath $destText.Text -PathType Container)) {
        $dialog.SelectedPath = $destText.Text
    }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $destText.Text = $dialog.SelectedPath
    }
})
$form.Controls.Add($destBrowse)

# ---------------------------------------------------------------------------
# Options row (Dry Run checkbox)
# ---------------------------------------------------------------------------

$dryRunCheck = New-Object System.Windows.Forms.CheckBox
$dryRunCheck.Text = "Dry Run (preview only - no files moved or deleted)"
$dryRunCheck.Location = New-Object System.Drawing.Point(20, 145)
$dryRunCheck.AutoSize = $true
$form.Controls.Add($dryRunCheck)

# ---------------------------------------------------------------------------
# Run button + status
# ---------------------------------------------------------------------------

$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = "Run"
$runButton.Location = New-Object System.Drawing.Point(20, 180)
$runButton.Size = New-Object System.Drawing.Size(110, 32)
$form.Controls.Add($runButton)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Ready"
$statusLabel.Location = New-Object System.Drawing.Point(145, 188)
$statusLabel.AutoSize = $true
$form.Controls.Add($statusLabel)

# ---------------------------------------------------------------------------
# Output text box
# ---------------------------------------------------------------------------

$outputText = New-Object System.Windows.Forms.TextBox
$outputText.Location = New-Object System.Drawing.Point(20, 230)
$outputText.Size = New-Object System.Drawing.Size(850, 290)
$outputText.Multiline = $true
$outputText.ScrollBars = "Both"
$outputText.ReadOnly = $true
$outputText.WordWrap = $false
$form.Controls.Add($outputText)

# ---------------------------------------------------------------------------
# Run button click handler
# ---------------------------------------------------------------------------

$runButton.Add_Click({
    try {
        $source = $sourceText.Text.Trim()
        $dest   = $destText.Text.Trim()

        if ([string]::IsNullOrWhiteSpace($source)) {
            [System.Windows.Forms.MessageBox]::Show("Source folder is required.", "Validation", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        if ([string]::IsNullOrWhiteSpace($dest)) {
            [System.Windows.Forms.MessageBox]::Show("Destination folder is required.", "Validation", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        if (-not (Test-Path -LiteralPath $source -PathType Container)) {
            [System.Windows.Forms.MessageBox]::Show("Source folder does not exist.", "Validation", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $runButton.Enabled = $false
        $statusLabel.Text  = "Running..."
        $outputText.Text   = "Working..." + [Environment]::NewLine
        $form.Refresh()

        $exe = Get-PowerShellExe
        $arguments = @(
            "-NoProfile"
            "-ExecutionPolicy"
            "Bypass"
            "-File"
            (Escape-Argument -Value $scriptPathResolved)
            "-SourceDir"
            (Escape-Argument -Value $source)
            "-DestDir"
            (Escape-Argument -Value $dest)
            "-NoConfirm"
        )

        if ($dryRunCheck.Checked) {
            $arguments += "-DryRun"
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $exe
        $psi.Arguments              = ($arguments -join " ")
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi

        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        $nl = [Environment]::NewLine

        $combined = ""
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            $combined += $stdout.TrimEnd() -replace "\r?\n", $nl
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            $combined += $nl + $nl + "Errors:" + $nl
            $combined += $stderr.TrimEnd() -replace "\r?\n", $nl
        }

        if ([string]::IsNullOrWhiteSpace($combined)) {
            $outputText.Text = "Done. No output returned."
        }
        else {
            $outputText.Text = $combined
        }

        if ($process.ExitCode -eq 0) {
            $statusLabel.Text = "Done"
        }
        else {
            $statusLabel.Text = "Failed (ExitCode: $($process.ExitCode))"
        }
    }
    catch {
        $statusLabel.Text = "Failed"
        $outputText.Text  = "Error: $($_.Exception.Message)"
    }
    finally {
        $runButton.Enabled = $true
    }
})

[void]$form.ShowDialog()
