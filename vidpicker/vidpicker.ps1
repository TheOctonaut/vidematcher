param(
    [Parameter(Mandatory = $false)]
    [string]$SourceDir,

    [Parameter(Mandatory = $false)]
    [string]$DestDir,

    [Parameter(Mandatory = $false)]
    [string]$OptionsFile,

    [Parameter(Mandatory = $false)]
    [string[]]$Extensions,

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

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

$defaults = [PSCustomObject]@{
    SourceDir  = "C:/path/to/source"
    DestDir    = "C:/path/to/dest"
    Extensions = @(".avi", ".mp4")
}

# ---------------------------------------------------------------------------
# Options file: prompt to create if missing
# ---------------------------------------------------------------------------

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
                SourceDir  = $defaults.SourceDir
                DestDir    = $defaults.DestDir
                Extensions = $defaults.Extensions
            }
            $defaultOptions | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OptionsFile -Encoding UTF8
            Write-Host "Created options file with default values: $OptionsFile"
        }
    }
    else {
        Write-Host "Continuing without options file."
    }
}

# ---------------------------------------------------------------------------
# Load options file
# ---------------------------------------------------------------------------

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
# Resolve settings: args > options file > defaults
# ---------------------------------------------------------------------------

$resolvedSourceDir = if ($PSBoundParameters.ContainsKey("SourceDir")) {
    $SourceDir
}
else {
    $v = Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "SourceDir")
    if ($null -ne $v) { $v } else { $null }
}

$resolvedDestDir = if ($PSBoundParameters.ContainsKey("DestDir")) {
    $DestDir
}
else {
    $v = Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "DestDir")
    if ($null -ne $v) { $v } else { $null }
}

$resolvedExtensions = if ($PSBoundParameters.ContainsKey("Extensions")) {
    ConvertTo-NormalizedExtensionArray $Extensions
}
else {
    $v = ConvertTo-NormalizedExtensionArray (Get-OptionValue -Options $fileOptions -Name "Extensions")
    if ($null -ne $v) { $v } else { $defaults.Extensions }
}

# ---------------------------------------------------------------------------
# Validate required settings
# ---------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($resolvedSourceDir)) {
    throw "SourceDir is required. Provide -SourceDir or set SourceDir in options.json."
}

if ([string]::IsNullOrWhiteSpace($resolvedDestDir)) {
    throw "DestDir is required. Provide -DestDir or set DestDir in options.json."
}

if (-not (Test-Path -LiteralPath $resolvedSourceDir -PathType Container)) {
    throw "Source directory does not exist: $resolvedSourceDir"
}

$sourceRoot = (Resolve-Path -LiteralPath $resolvedSourceDir).Path
$destResolved = Resolve-Path -LiteralPath $resolvedDestDir -ErrorAction SilentlyContinue
$destRoot     = if ($null -ne $destResolved) { $destResolved.Path } else { $null }

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

$extensionSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($ext in $resolvedExtensions) { [void]$extensionSet.Add($ext) }

# ---------------------------------------------------------------------------
# Scan for matching files
# ---------------------------------------------------------------------------

Write-Host "Scanning: $sourceRoot"

$matchedFiles = Get-ChildItem -LiteralPath $sourceRoot -File -Recurse |
    Where-Object { $extensionSet.Contains(($_.Extension).ToLowerInvariant()) }

if ($matchedFiles.Count -eq 0) {
    Write-Host "No matching files found."
    exit 0
}

Write-Host "Found $($matchedFiles.Count) file(s) to move."
Write-Host ""

# Detect name conflicts in destination
$destConflicts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$existingInDest = Get-ChildItem -LiteralPath $destRoot -File -ErrorAction SilentlyContinue
foreach ($f in $existingInDest) { [void]$destConflicts.Add($f.Name) }

$toMove   = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
$skipped  = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

foreach ($file in $matchedFiles) {
    if ($destConflicts.Contains($file.Name)) {
        $skipped.Add($file)
    }
    else {
        $toMove.Add($file)
        [void]$destConflicts.Add($file.Name)
    }
}

# ---------------------------------------------------------------------------
# Preview
# ---------------------------------------------------------------------------

if ($DryRun) {
    Write-Host "[DRY RUN] Would move:"
}
else {
    Write-Host "Files to move:"
}

foreach ($file in $toMove) {
    $rel = [System.IO.Path]::GetRelativePath($sourceRoot, $file.FullName)
    Write-Host "  $rel  ->  $destRoot\$($file.Name)"
}

if ($skipped.Count -gt 0) {
    Write-Host ""
    Write-Host "Skipped (name conflict in destination):"
    foreach ($file in $skipped) {
        $rel = [System.IO.Path]::GetRelativePath($sourceRoot, $file.FullName)
        Write-Host "  $rel"
    }
}

# Compute source folders to clean up (only folders where we're moving files)
$foldersToClean = $toMove |
    ForEach-Object { Split-Path -Parent $_.FullName } |
    Sort-Object -Unique |
    Where-Object { $_ -ne $sourceRoot } |
    Sort-Object { $_.Length } -Descending

if ($foldersToClean.Count -gt 0) {
    Write-Host ""
    if ($DryRun) {
        Write-Host "[DRY RUN] Would delete source folder(s) and remaining contents:"
    }
    else {
        Write-Host "Source folder(s) to delete (after moving files):"
    }
    foreach ($folder in $foldersToClean) {
        $rel = [System.IO.Path]::GetRelativePath($sourceRoot, $folder)
        Write-Host "  $rel"
    }
}

if ($DryRun) {
    Write-Host ""
    Write-Host "Dry run complete. No files were moved or deleted."
    exit 0
}

if ($toMove.Count -eq 0) {
    Write-Host ""
    Write-Host "Nothing to move."
    exit 0
}

# ---------------------------------------------------------------------------
# Confirm
# ---------------------------------------------------------------------------

if (-not $NoConfirm) {
    Write-Host ""
    $confirm = Read-Host "Proceed? (Y/N)"
    if ($confirm -notmatch '^[Yy]') {
        Write-Host "Aborted."
        exit 0
    }
}

# ---------------------------------------------------------------------------
# Move files
# ---------------------------------------------------------------------------

$moveOk    = 0
$moveError = 0

foreach ($file in $toMove) {
    $dest = Join-Path $destRoot $file.Name
    try {
        Move-Item -LiteralPath $file.FullName -Destination $dest -Force
        $moveOk++
    }
    catch {
        Write-Warning "Failed to move '$($file.FullName)': $($_.Exception.Message)"
        $moveError++
    }
}

Write-Host "Moved: $moveOk  Failed: $moveError"

# ---------------------------------------------------------------------------
# Clean up source folders (deepest first)
# ---------------------------------------------------------------------------

if ($foldersToClean.Count -gt 0) {
    Write-Host ""
    Write-Host "Cleaning up source folders..."

    foreach ($folder in $foldersToClean) {
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
            continue
        }
        try {
            Remove-Item -LiteralPath $folder -Recurse -Force
            $rel = [System.IO.Path]::GetRelativePath($sourceRoot, $folder)
            Write-Host "  Deleted: $rel"
        }
        catch {
            $rel = [System.IO.Path]::GetRelativePath($sourceRoot, $folder)
            Write-Warning "  Failed to delete '$rel': $($_.Exception.Message)"
        }
    }

    # Remove now-empty ancestor folders up to (not including) sourceRoot
    $ancestors = $foldersToClean |
        ForEach-Object {
            $current = Split-Path -Parent $_
            while (-not [string]::IsNullOrWhiteSpace($current) -and
                   $current -ne $sourceRoot -and
                   $current.Length -gt $sourceRoot.Length) {
                $current
                $current = Split-Path -Parent $current
            }
        } |
        Sort-Object -Unique |
        Where-Object { $_ -ne $sourceRoot } |
        Sort-Object { $_.Length } -Descending

    foreach ($ancestor in $ancestors) {
        if (-not (Test-Path -LiteralPath $ancestor -PathType Container)) { continue }
        $children = Get-ChildItem -LiteralPath $ancestor -Force
        if ($children.Count -eq 0) {
            try {
                Remove-Item -LiteralPath $ancestor -Force
                $rel = [System.IO.Path]::GetRelativePath($sourceRoot, $ancestor)
                Write-Host "  Deleted empty: $rel"
            }
            catch {
                $rel = [System.IO.Path]::GetRelativePath($sourceRoot, $ancestor)
                Write-Warning "  Failed to delete '$rel': $($_.Exception.Message)"
            }
        }
    }
}

Write-Host ""
Write-Host "Done."
