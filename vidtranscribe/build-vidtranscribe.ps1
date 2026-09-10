param(
    [Parameter(Mandatory = $false)]
    [string]$ImageTag,

    [Parameter(Mandatory = $false)]
    [switch]$NoCache,

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

if ([string]::IsNullOrWhiteSpace($ImageTag)) {
    $ImageTag = "vidtranscribe:latest"
}

$dockerfilePath = Join-Path $scriptRoot "Dockerfile"
if (-not (Test-Path -LiteralPath $dockerfilePath -PathType Leaf)) {
    throw "Dockerfile not found: $dockerfilePath"
}

try {
    & docker version --format '{{.Server.Version}}' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Docker daemon not reachable."
    }
}
catch {
    throw "Docker does not appear to be available. Is Docker Desktop running? ($($_.Exception.Message))"
}

Write-Host "This will build the '$ImageTag' image from $dockerfilePath."
Write-Host "First build downloads a large base image and dependency set (CUDA, PyTorch, WhisperX)."
Write-Host "On a slow connection this can take a long time (over an hour is possible)."

if (-not $NoConfirm) {
    Write-Host ""
    $confirm = Read-Host "Proceed with build? (Y/N)"
    if ($confirm -notmatch '^[Yy]') {
        Write-Host "Aborted."
        Write-Host "SUMMARY|tool=vidtranscribe-build|status=aborted|image=$ImageTag"
        exit 0
    }
}

$dockerArgs = @('build', '-t', $ImageTag, '-f', $dockerfilePath, $scriptRoot)
if ($NoCache) {
    $dockerArgs += '--no-cache'
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & docker @dockerArgs 2>&1 | ForEach-Object { Write-Host $_ }
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
$exitCode = $LASTEXITCODE
$stopwatch.Stop()
$elapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)

if ($exitCode -ne 0) {
    Write-Host "Build failed (exit code $exitCode)."
    Write-Host "SUMMARY|tool=vidtranscribe-build|status=failed|image=$ImageTag|elapsed_seconds=$elapsedSeconds"
    exit 1
}

Write-Host ""
Write-Host "Build succeeded: $ImageTag"
Write-Host "SUMMARY|tool=vidtranscribe-build|status=ok|image=$ImageTag|elapsed_seconds=$elapsedSeconds"
exit 0
