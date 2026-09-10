<#
.SYNOPSIS
Pre-downloads WhisperX alignment models for one or more language codes, without using the GPU.

.DESCRIPTION
WhisperX downloads its per-language alignment model lazily, the first time it encounters that
language during a real transcription. Some of these downloads are large (~1.2GB, from Hugging
Face) and can stall on flaky connections mid-run, which looks like the transcription "hanging".

This script forces those downloads ahead of time by calling whisperx.alignment.load_align_model()
directly inside the vidtranscribe container, using device='cpu' so it never touches the GPU and
so it can safely run alongside a live transcription batch.

.PARAMETER Languages
One or more language codes to precache (e.g. fr, de, it, pt, ru).

.PARAMETER ModelsPath
Host folder to mount as /models (must match the ModelsPath used by vidtranscribe.ps1, so the
cached models are actually reused). Falls back to options.json, then options.json.example.

.PARAMETER DockerImage
Image to run. Falls back to options.json, then options.json.example.

.EXAMPLE
.\precache-align-models.ps1 -Languages pt,ru,it,fr,de
#>
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Languages,

    [Parameter(Mandatory = $false)]
    [string]$ModelsPath,

    [Parameter(Mandatory = $false)]
    [string]$DockerImage,

    [Parameter(Mandatory = $false)]
    [string]$OptionsFile
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
$exampleOptionsFile = Join-Path $scriptRoot "options.json.example"

function Get-OptionValue {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Options,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Options) { return $null }
    if ($Options.PSObject.Properties.Name -contains $Name) { return $Options.$Name }
    return $null
}

$options = $null
if (Test-Path -LiteralPath $OptionsFile -PathType Leaf) {
    $options = Get-Content -LiteralPath $OptionsFile -Raw | ConvertFrom-Json
}
elseif (Test-Path -LiteralPath $exampleOptionsFile -PathType Leaf) {
    $options = Get-Content -LiteralPath $exampleOptionsFile -Raw | ConvertFrom-Json
}

if ([string]::IsNullOrWhiteSpace($ModelsPath)) {
    $ModelsPath = Get-OptionValue -Options $options -Name "ModelsPath"
}
if ([string]::IsNullOrWhiteSpace($DockerImage)) {
    $DockerImage = Get-OptionValue -Options $options -Name "DockerImage"
}
if ([string]::IsNullOrWhiteSpace($DockerImage)) {
    $DockerImage = "vidtranscribe:latest"
}

if ([string]::IsNullOrWhiteSpace($ModelsPath)) {
    throw "ModelsPath is required (pass -ModelsPath, or set it in options.json)."
}

Write-Host "Precaching alignment models for: $($Languages -join ', ')"
Write-Host "Models path: $ModelsPath"
Write-Host "Docker image: $DockerImage"
Write-Host "Running on CPU only - this will not use or contend with the GPU."
Write-Host ""

$succeeded = 0
$failed = 0

foreach ($lang in $Languages) {
    Write-Host "PROGRESS|tool=precache-align-models|event=start|language=$lang"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $pythonScript = @"
import time
import whisperx.alignment as al
t = time.time()
al.load_align_model('$lang', 'cpu')
print('done in', round(time.time() - t, 1), 's')
"@

    $dockerArgs = @(
        'run', '--rm', '--entrypoint', 'python3',
        '-v', "${ModelsPath}:/models",
        '-e', 'HF_HOME=/models/huggingface',
        '-e', 'XDG_CACHE_HOME=/models/cache',
        '-e', 'TORCH_HOME=/models/torch'
    )
    if (-not [string]::IsNullOrWhiteSpace($env:HF_TOKEN)) {
        $dockerArgs += @('-e', "HF_TOKEN=$($env:HF_TOKEN)")
    }
    $dockerArgs += @($DockerImage, '-c', $pythonScript)

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

    if ($exitCode -eq 0) {
        $succeeded++
        Write-Host "PROGRESS|tool=precache-align-models|event=complete|language=$lang|elapsed_seconds=$elapsedSeconds"
    }
    else {
        $failed++
        Write-Host "PROGRESS|tool=precache-align-models|event=complete|language=$lang|elapsed_seconds=$elapsedSeconds|failed=true"
    }
}

$status = if ($failed -gt 0) { "failed" } else { "ok" }
Write-Host ""
Write-Host "SUMMARY|tool=precache-align-models|status=$status|languages=$($Languages.Count)|succeeded=$succeeded|failed=$failed"
if ($failed -gt 0) { exit 1 }
exit 0
