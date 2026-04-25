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
    $ScriptPath = Join-Path $scriptRoot "vidmatch.ps1"
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
    throw "Cannot find vidmatch script: $ScriptPath"
}

$scriptPathResolved = (Resolve-Path -LiteralPath $ScriptPath).Path
$optionsPath = Join-Path $scriptRoot "options.json"
$defaults = Load-OptionsDefaults -OptionsPath $optionsPath

$form = New-Object System.Windows.Forms.Form
$form.Text = "vidmatch"
$form.Size = New-Object System.Drawing.Size(900, 650)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(900, 650)

$font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Font = $font

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

$targetLabel = New-Object System.Windows.Forms.Label
$targetLabel.Text = "Target Folder"
$targetLabel.Location = New-Object System.Drawing.Point(20, 80)
$targetLabel.AutoSize = $true
$form.Controls.Add($targetLabel)

$targetText = New-Object System.Windows.Forms.TextBox
$targetText.Location = New-Object System.Drawing.Point(20, 102)
$targetText.Size = New-Object System.Drawing.Size(730, 24)
if ($null -ne $defaults -and $defaults.PSObject.Properties.Name -contains "TargetDir") {
    $targetText.Text = [string]$defaults.TargetDir
}
$form.Controls.Add($targetText)

$targetBrowse = New-Object System.Windows.Forms.Button
$targetBrowse.Text = "Browse..."
$targetBrowse.Location = New-Object System.Drawing.Point(760, 100)
$targetBrowse.Size = New-Object System.Drawing.Size(110, 28)
$targetBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Select target folder"
    if (-not [string]::IsNullOrWhiteSpace($targetText.Text) -and (Test-Path -LiteralPath $targetText.Text -PathType Container)) {
        $dialog.SelectedPath = $targetText.Text
    }

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $targetText.Text = $dialog.SelectedPath
    }
})
$form.Controls.Add($targetBrowse)

$csvLabel = New-Object System.Windows.Forms.Label
$csvLabel.Text = "CSV Output (Optional)"
$csvLabel.Location = New-Object System.Drawing.Point(20, 140)
$csvLabel.AutoSize = $true
$form.Controls.Add($csvLabel)

$csvText = New-Object System.Windows.Forms.TextBox
$csvText.Location = New-Object System.Drawing.Point(20, 162)
$csvText.Size = New-Object System.Drawing.Size(730, 24)
if ($null -ne $defaults -and $defaults.PSObject.Properties.Name -contains "CsvOutputPath" -and $null -ne $defaults.CsvOutputPath) {
    $csvText.Text = [string]$defaults.CsvOutputPath
}
$form.Controls.Add($csvText)

$csvBrowse = New-Object System.Windows.Forms.Button
$csvBrowse.Text = "Browse..."
$csvBrowse.Location = New-Object System.Drawing.Point(760, 160)
$csvBrowse.Size = New-Object System.Drawing.Size(110, 28)
$csvBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = "CSV files (*.csv)|*.csv|All files (*.*)|*.*"
    $dialog.Title = "Choose output CSV path"
    if (-not [string]::IsNullOrWhiteSpace($csvText.Text)) {
        $dialog.FileName = $csvText.Text
    }

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $csvText.Text = $dialog.FileName
    }
})
$form.Controls.Add($csvBrowse)

$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = "Compare"
$runButton.Location = New-Object System.Drawing.Point(20, 205)
$runButton.Size = New-Object System.Drawing.Size(110, 32)
$form.Controls.Add($runButton)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Ready"
$statusLabel.Location = New-Object System.Drawing.Point(145, 213)
$statusLabel.AutoSize = $true
$form.Controls.Add($statusLabel)

$outputText = New-Object System.Windows.Forms.TextBox
$outputText.Location = New-Object System.Drawing.Point(20, 255)
$outputText.Size = New-Object System.Drawing.Size(850, 330)
$outputText.Multiline = $true
$outputText.ScrollBars = "Both"
$outputText.ReadOnly = $true
$outputText.WordWrap = $false
$form.Controls.Add($outputText)

$runButton.Add_Click({
    try {
        $source = $sourceText.Text.Trim()
        $target = $targetText.Text.Trim()
        $csv = $csvText.Text.Trim()

        if ([string]::IsNullOrWhiteSpace($source)) {
            [System.Windows.Forms.MessageBox]::Show("Source folder is required.", "Validation", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        if ([string]::IsNullOrWhiteSpace($target)) {
            [System.Windows.Forms.MessageBox]::Show("Target folder is required.", "Validation", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        if (-not (Test-Path -LiteralPath $source -PathType Container)) {
            [System.Windows.Forms.MessageBox]::Show("Source folder does not exist.", "Validation", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        if (-not (Test-Path -LiteralPath $target -PathType Container)) {
            [System.Windows.Forms.MessageBox]::Show("Target folder does not exist.", "Validation", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $runButton.Enabled = $false
        $statusLabel.Text = "Running..."
        $outputText.Text = "Working..." + [Environment]::NewLine
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
            "-TargetDir"
            (Escape-Argument -Value $target)
        )

        if (-not [string]::IsNullOrWhiteSpace($csv)) {
            $arguments += "-CsvOutputPath"
            $arguments += (Escape-Argument -Value $csv)
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = ($arguments -join " ")
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

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
        $outputText.Text = "Error: $($_.Exception.Message)"
    }
    finally {
        $runButton.Enabled = $true
    }
})

[void]$form.ShowDialog()