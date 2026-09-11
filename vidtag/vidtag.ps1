param(
    [Parameter(Mandatory = $false)]
    [string]$ScanPath,

    [Parameter(Mandatory = $false)]
    [string]$OptionsFile,

    [Parameter(Mandatory = $false)]
    [string]$JellyfinUrl,

    [Parameter(Mandatory = $false)]
    [string]$JellyfinApiKey,

    [Parameter(Mandatory = $false)]
    [string]$LlmBaseUrl,

    [Parameter(Mandatory = $false)]
    [string]$LlmApiKey,

    [Parameter(Mandatory = $false)]
    [string]$LlmModel,

    [Parameter(Mandatory = $false)]
    [int]$MaxFiles,

    [Parameter(Mandatory = $false)]
    [switch]$AllowNewTags,

    [Parameter(Mandatory = $false)]
    [switch]$GenerateDescription,

    [Parameter(Mandatory = $false)]
    [switch]$UseVisuals,

    [Parameter(Mandatory = $false)]
    [string]$FfmpegPath,

    [Parameter(Mandatory = $false)]
    [string]$LogFile,

    [Parameter(Mandatory = $false)]
    [string]$VocabCacheFile,

    [Parameter(Mandatory = $false)]
    [int]$VocabCacheMaxAgeHours,

    [Parameter(Mandatory = $false)]
    [switch]$RefreshVocabulary,

    [Parameter(Mandatory = $false)]
    [int]$LlmRequestDelaySeconds,

    [Parameter(Mandatory = $false)]
    [int]$LlmMaxRetries,

    [Parameter(Mandatory = $false)]
    [int]$LlmRetryDelaySeconds,

    [Parameter(Mandatory = $false)]
    [switch]$RefreshJellyfinLibrary,

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

$optionsFileExplicit = -not [string]::IsNullOrWhiteSpace($OptionsFile)
if (-not $optionsFileExplicit) {
    $OptionsFile = Join-Path $scriptRoot "options.json"
}

$exampleOptionsFile = Join-Path $scriptRoot "options.json.example"

# ---------------------------------------------------------------------------
# LLM request log
# ---------------------------------------------------------------------------

$script:llmLogPath = $null

function Write-LlmLog {
    param([string]$Label, [string]$RequestJson, [string]$ResponseText, [string]$ErrorText)

    if ([string]::IsNullOrWhiteSpace($script:llmLogPath)) { return }

    $entry = [ordered]@{
        timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        label     = $Label
        request   = $RequestJson
        response  = $ResponseText
        error     = $ErrorText
    }

    $line = ($entry | ConvertTo-Json -Compress) + ","
    try {
        Add-Content -LiteralPath $script:llmLogPath -Value $line -Encoding UTF8
    }
    catch { }
}

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

function Get-NormalizedTagKey {
    # Collapses spelling/formatting variants ("Sci-Fi", "sci fi", "SciFi",
    # "sci_fi") down to a single comparison key ("scifi") so near-duplicate
    # tags/genres are recognised as the same term.
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    return ($Value.ToLowerInvariant() -replace '[^a-z0-9]', '')
}

function Format-TagCasing {
    # Light cosmetic cleanup for a brand-new tag/genre: trim, collapse
    # whitespace, and title-case words (respecting hyphens) while leaving
    # short all-caps acronyms (ASMR, POV, BDSM) alone.
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }

    $trimmed = ($Value.Trim() -replace '\s+', ' ')
    $ti = [System.Globalization.CultureInfo]::InvariantCulture.TextInfo
    $words = $trimmed -split ' ' | ForEach-Object {
        $w = $_
        if ($w -cmatch '^[A-Z0-9]{2,6}$') {
            $w
        }
        elseif ($w -match '^[a-zA-Z]+(-[a-zA-Z]+)*$') {
            ($w -split '-' | ForEach-Object { $ti.ToTitleCase($_.ToLowerInvariant()) }) -join '-'
        }
        else {
            $w
        }
    }
    return ($words -join ' ')
}

function Resolve-VocabTerms {
    # Maps suggested terms onto existing vocabulary spelling/casing where a
    # normalized-key match is found, formats genuinely new terms consistently,
    # and de-duplicates by normalized key (preserving first-seen order).
    param(
        [string[]]$Suggested,
        [System.Collections.Generic.Dictionary[string, string]]$NormMap
    )

    $result = New-Object System.Collections.Generic.List[string]
    $seenKeys = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($term in $Suggested) {
        if ([string]::IsNullOrWhiteSpace($term)) { continue }
        $key = Get-NormalizedTagKey $term
        if ($key -eq "" -or -not $seenKeys.Add($key)) { continue }

        if ($NormMap.ContainsKey($key)) {
            $result.Add($NormMap[$key])
        }
        else {
            $result.Add((Format-TagCasing $term))
        }
    }

    return @($result)
}

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

function Read-SrtText {
    param([string]$SrtPath)

    $lines = Get-Content -LiteralPath $SrtPath -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $lines) { return "" }

    $words = New-Object System.Collections.Generic.List[string]
    $inBlock = $false

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\d+$') {
            $inBlock = $false
            continue
        }
        if ($trimmed -match '^\d{2}:\d{2}:\d{2}[,\.]\d{3}\s+-->\s+\d{2}:\d{2}:\d{2}[,\.]\d{3}$') {
            $inBlock = $true
            continue
        }
        if ($inBlock -and $trimmed -ne "") {
            $clean = $trimmed -replace '<[^>]+>', ''
            $clean = $clean.Trim()
            if ($clean -ne "") {
                $words.Add($clean)
            }
        }
        if ($trimmed -eq "") {
            $inBlock = $false
        }
    }

    return ($words -join " ")
}

function Truncate-ToWordBudget {
    param([string]$Text, [int]$WordLimit)

    if ($WordLimit -le 0) { return $Text }
    $parts = $Text -split '\s+'
    if ($parts.Count -le $WordLimit) { return $Text }

    $half = [int]($WordLimit / 2)
    $headWords = $parts[0..($half - 1)]
    $tailStart = $parts.Count - ($WordLimit - $half)
    $tailWords = $parts[$tailStart..($parts.Count - 1)]
    return (($headWords -join " ") + " [...] " + ($tailWords -join " "))
}

function Get-VideoScreenshots {
    param(
        [string]$VideoPath,
        [string]$FfmpegBin,
        [string]$TempDir
    )

    $duration = $null
    try {
        $probe = & $FfmpegBin -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $VideoPath 2>$null
        if ($probe) {
            $duration = [double]::Parse($probe[0], [System.Globalization.CultureInfo]::InvariantCulture)
        }
    }
    catch { }

    if (-not $duration -or $duration -le 0) {
        Write-Host "  [visuals] Could not determine video duration, skipping screenshots."
        return @()
    }

    $fractions = @(0.25, 0.50, 0.75, 0.95)
    $b64List = New-Object System.Collections.Generic.List[string]

    foreach ($frac in $fractions) {
        $ts = [int]($duration * $frac)
        $outFile = Join-Path $TempDir ("screenshot_${ts}.jpg")
        try {
            & $FfmpegBin -v error -ss $ts -i $VideoPath -frames:v 1 -q:v 5 $outFile 2>$null | Out-Null
            if (Test-Path -LiteralPath $outFile) {
                $bytes = [System.IO.File]::ReadAllBytes($outFile)
                $b64List.Add([Convert]::ToBase64String($bytes))
                Remove-Item -LiteralPath $outFile -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-Host "  [visuals] Screenshot at ${ts}s failed: $($_.Exception.Message)"
        }
    }

    return @($b64List)
}

function Invoke-LlmJson {
    param(
        [string]$BaseUrl,
        [string]$ApiKey,
        [string]$Model,
        [object[]]$Messages,
        [string]$TaskLabel,
        [int]$PacingDelaySeconds = 0,
        [int]$MaxRetries = 2,
        [int]$RetryDelaySeconds = 5
    )

    $url = $BaseUrl.TrimEnd("/") + "/chat/completions"

    $body = [ordered]@{
        model       = $Model
        messages    = $Messages
        temperature = 0.3
        max_tokens  = 1000
    }

    $bodyJson = $body | ConvertTo-Json -Depth 10 -Compress

    $headers = @{
        "Authorization" = "Bearer $ApiKey"
        "Content-Type"  = "application/json"
    }

    if ($PacingDelaySeconds -gt 0) {
        Start-Sleep -Seconds $PacingDelaySeconds
    }

    $attempt = 0
    while ($true) {
        try {
            $response = Invoke-RestMethod -Uri $url -Method POST -Headers $headers -Body $bodyJson -TimeoutSec 120
            $content = $response.choices[0].message.content
            Write-LlmLog -Label $TaskLabel -RequestJson $bodyJson -ResponseText $content -ErrorText ""
            # Strip markdown code fences in case the model wraps the JSON
            $content = $content -replace '(?s)^```(?:json)?\s*', '' -replace '(?s)\s*```\s*$', ''
            return $content | ConvertFrom-Json
        }
        catch {
            $statusCode = $null
            $retryAfterSeconds = $null
            $resp = $_.Exception.Response
            if ($resp) {
                try { $statusCode = [int]$resp.StatusCode } catch { }
                try {
                    if ($resp.Headers -and $resp.Headers.RetryAfter) {
                        if ($resp.Headers.RetryAfter.Delta) {
                            $retryAfterSeconds = [int]$resp.Headers.RetryAfter.Delta.TotalSeconds
                        }
                        elseif ($resp.Headers.RetryAfter.Date) {
                            $retryAfterSeconds = [int](([datetimeoffset]$resp.Headers.RetryAfter.Date - [datetimeoffset]::UtcNow).TotalSeconds)
                        }
                    }
                }
                catch { }
                if (-not $retryAfterSeconds) {
                    try {
                        $val = $resp.Headers["Retry-After"]
                        if ($val) { $retryAfterSeconds = [int]$val }
                    }
                    catch { }
                }
            }

            if ($statusCode -eq 429 -and $attempt -lt $MaxRetries) {
                $wait = if ($retryAfterSeconds -and $retryAfterSeconds -gt 0) { $retryAfterSeconds } else { $RetryDelaySeconds * ($attempt + 1) }
                $attempt++
                Write-Host "    Rate limited (429) for ${TaskLabel}, retrying in ${wait}s (attempt $attempt/$MaxRetries)..."
                Start-Sleep -Seconds $wait
                continue
            }

            Write-LlmLog -Label $TaskLabel -RequestJson $bodyJson -ResponseText "" -ErrorText $_.Exception.Message
            throw "LLM request failed for ${TaskLabel}: $($_.Exception.Message)"
        }
    }
}

function Get-JellyfinVocabulary {
    param([string]$BaseUrl, [string]$ApiKey)

    $headers = @{ "X-MediaBrowser-Token" = $ApiKey }
    $tags = @()
    $genres = @()
    $base = $BaseUrl.TrimEnd("/")

    # Jellyfin has no standalone /Tags endpoint (404s) -- tags have to be
    # aggregated by paginating every item's Tags field instead.
    try {
        $usersResult = Invoke-RestMethod -Uri ($base + "/Users") -Headers $headers -TimeoutSec 30 -ErrorAction Stop
        $userId = $null
        if ($usersResult -and $usersResult.Count -gt 0) { $userId = $usersResult[0].Id }

        if ($userId) {
            $tagSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $startIndex = 0
            $pageLimit = 500
            do {
                $uri = "$base/Users/$userId/Items?Fields=Tags&Recursive=true&Limit=$pageLimit&StartIndex=$startIndex"
                $page = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 30 -ErrorAction Stop
                $items = @($page.Items)
                foreach ($it in $items) {
                    if ($it.Tags) { foreach ($t in $it.Tags) { if ($t) { $tagSet.Add($t) | Out-Null } } }
                }
                $startIndex += $pageLimit
                $totalCount = if ($page.TotalRecordCount) { $page.TotalRecordCount } else { $items.Count }
            } while ($items.Count -gt 0 -and $startIndex -lt $totalCount)

            $tags = @($tagSet)
        }
    }
    catch {
        Write-Host "  [jellyfin] Could not fetch tags: $($_.Exception.Message)"
    }

    try {
        $genresResult = Invoke-RestMethod -Uri ($base + "/Genres") -Headers $headers -TimeoutSec 30 -ErrorAction Stop
        if ($genresResult.Items) {
            $genres = @($genresResult.Items | ForEach-Object { $_.Name })
        }
    }
    catch {
        Write-Host "  [jellyfin] Could not fetch genres: $($_.Exception.Message)"
    }

    return [PSCustomObject]@{ Tags = $tags; Genres = $genres }
}

function Get-VocabularyCache {
    param([string]$CacheFile)

    if ([string]::IsNullOrWhiteSpace($CacheFile) -or -not (Test-Path -LiteralPath $CacheFile)) {
        return $null
    }
    try {
        $raw = Get-Content -LiteralPath $CacheFile -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    }
    catch {
        Write-Host "  [vocab-cache] Could not read cache file, ignoring: $($_.Exception.Message)"
        return $null
    }
}

function Save-VocabularyCache {
    param(
        [string]$CacheFile,
        [datetime]$FetchedAt,
        [string[]]$Tags,
        [string[]]$Genres
    )

    if ([string]::IsNullOrWhiteSpace($CacheFile)) { return }

    $obj = [ordered]@{
        FetchedAt = $FetchedAt.ToString("o")
        Tags      = @($Tags | Sort-Object -Unique)
        Genres    = @($Genres | Sort-Object -Unique)
    }
    try {
        $obj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $CacheFile -Encoding UTF8
    }
    catch {
        Write-Host "  [vocab-cache] Could not write cache file: $($_.Exception.Message)"
    }
}

function Merge-NfoFields {
    param(
        [string]$NfoPath,
        [string[]]$NewGenres,
        [string[]]$NewTags,
        [string]$NewPlot
    )

    $content = Get-Content -LiteralPath $NfoPath -Raw -Encoding UTF8

    # Collect existing genres and tags to avoid duplicates. Compared by
    # normalized key so spelling/casing/punctuation variants of an entry
    # already in the NFO ("Sci-Fi" vs "scifi") aren't re-added.
    $existingGenreKeys = [System.Collections.Generic.HashSet[string]]::new()
    $existingTagKeys   = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($m in [regex]::Matches($content, '<genre>([^<]*)</genre>')) {
        $key = Get-NormalizedTagKey $m.Groups[1].Value.Trim()
        if ($key -ne "") { $existingGenreKeys.Add($key) | Out-Null }
    }
    foreach ($m in [regex]::Matches($content, '<tag>([^<]*)</tag>')) {
        $key = Get-NormalizedTagKey $m.Groups[1].Value.Trim()
        if ($key -ne "") { $existingTagKeys.Add($key) | Out-Null }
    }

    $addedGenres = New-Object System.Collections.Generic.List[string]
    $addedTags   = New-Object System.Collections.Generic.List[string]

    foreach ($g in $NewGenres) {
        $key = Get-NormalizedTagKey $g
        if ($g -and $key -ne "" -and $existingGenreKeys.Add($key)) {
            $addedGenres.Add($g)
        }
    }
    foreach ($t in $NewTags) {
        $key = Get-NormalizedTagKey $t
        if ($t -and $key -ne "" -and $existingTagKeys.Add($key)) {
            $addedTags.Add($t)
        }
    }

    $insertLines = New-Object System.Collections.Generic.List[string]
    foreach ($g in $addedGenres) { $insertLines.Add("  <genre>$g</genre>") }
    foreach ($t in $addedTags)   { $insertLines.Add("  <tag>$t</tag>") }

    $plotUpdated = $false
    if (-not [string]::IsNullOrWhiteSpace($NewPlot)) {
        # Only update if plot is missing or empty
        if ($content -match '<plot>\s*</plot>' -or $content -notmatch '<plot>') {
            $escapedPlot = [System.Security.SecurityElement]::Escape($NewPlot)
            if ($content -match '<plot>\s*</plot>') {
                $content = $content -replace '<plot>\s*</plot>', "<plot>$escapedPlot</plot>"
            }
            else {
                $insertLines.Add("  <plot>$escapedPlot</plot>")
            }
            $plotUpdated = $true
        }
    }

    if ($insertLines.Count -gt 0) {
        $insertBlock = ($insertLines -join "`n") + "`n"
        # Insert before </movie> or </tvshow> closing tag
        if ($content -match '</movie>') {
            $content = $content -replace '(</movie>)', "$insertBlock`$1"
        }
        elseif ($content -match '</tvshow>') {
            $content = $content -replace '(</tvshow>)', "$insertBlock`$1"
        }
        else {
            # Fallback: append before last closing tag
            $content = $content.TrimEnd() + "`n" + $insertBlock
        }
    }

    Set-Content -LiteralPath $NfoPath -Value $content -Encoding UTF8 -NoNewline

    return [PSCustomObject]@{
        AddedGenres  = @($addedGenres)
        AddedTags    = @($addedTags)
        PlotUpdated  = $plotUpdated
    }
}

# ---------------------------------------------------------------------------
# Options file bootstrap
# ---------------------------------------------------------------------------

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
                Write-Host "Edit $OptionsFile to set your API keys, then re-run."
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

# ---------------------------------------------------------------------------
# Resolve parameters (CLI > options file > defaults)
# ---------------------------------------------------------------------------

$resolvedScanPath = if ($PSBoundParameters.ContainsKey("ScanPath")) {
    $ScanPath
} else {
    Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "ScanPath")
}

$resolvedJellyfinUrl = if ($PSBoundParameters.ContainsKey("JellyfinUrl")) {
    $JellyfinUrl
} else {
    Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "JellyfinUrl")
}

$resolvedJellyfinApiKey = if ($PSBoundParameters.ContainsKey("JellyfinApiKey")) {
    $JellyfinApiKey
} else {
    Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "JellyfinApiKey")
}

$resolvedLlmBaseUrl = if ($PSBoundParameters.ContainsKey("LlmBaseUrl")) {
    $LlmBaseUrl
} else {
    $v = Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "LlmBaseUrl")
    if ($null -ne $v) { $v } else { "https://api.openai.com/v1" }
}

$resolvedLlmApiKey = if ($PSBoundParameters.ContainsKey("LlmApiKey")) {
    $LlmApiKey
} else {
    Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "LlmApiKey")
}

$resolvedLlmModel = if ($PSBoundParameters.ContainsKey("LlmModel")) {
    $LlmModel
} else {
    $v = Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "LlmModel")
    if ($null -ne $v) { $v } else { "gpt-4o" }
}

$resolvedMaxFiles = if ($PSBoundParameters.ContainsKey("MaxFiles")) {
    $MaxFiles
} else {
    $v = Get-OptionValue -Options $fileOptions -Name "MaxFiles"
    if ($null -ne $v -and [string]$v -match '^\d+$') { [int]$v } else { 0 }
}

$resolvedAllowNewTags = if ($AllowNewTags.IsPresent) {
    $true
} else {
    $v = Get-OptionValue -Options $fileOptions -Name "AllowNewTags"
    if ($null -ne $v) { [bool]$v } else { $false }
}

$resolvedGenerateDescription = if ($GenerateDescription.IsPresent) {
    $true
} else {
    $v = Get-OptionValue -Options $fileOptions -Name "GenerateDescription"
    if ($null -ne $v) { [bool]$v } else { $false }
}

$resolvedUseVisuals = if ($UseVisuals.IsPresent) {
    $true
} else {
    $v = Get-OptionValue -Options $fileOptions -Name "UseVisuals"
    if ($null -ne $v) { [bool]$v } else { $false }
}

$resolvedFfmpegPath = if ($PSBoundParameters.ContainsKey("FfmpegPath")) {
    $FfmpegPath
} else {
    $v = Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "FfmpegPath")
    if ($null -ne $v) { $v } else { "ffmpeg" }
}

$resolvedLogFile = if ($PSBoundParameters.ContainsKey("LogFile")) {
    $LogFile
} else {
    Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "LogFile")
}

$resolvedVocabCacheFile = if ($PSBoundParameters.ContainsKey("VocabCacheFile")) {
    $VocabCacheFile
} else {
    $v = Normalize-OptionalString (Get-OptionValue -Options $fileOptions -Name "VocabCacheFile")
    if ($null -ne $v) { $v } else { "vidtag-vocab-cache.json" }
}

$resolvedVocabCacheMaxAgeHours = if ($PSBoundParameters.ContainsKey("VocabCacheMaxAgeHours")) {
    $VocabCacheMaxAgeHours
} else {
    $v = Get-OptionValue -Options $fileOptions -Name "VocabCacheMaxAgeHours"
    if ($null -ne $v -and [string]$v -match '^\d+$') { [int]$v } else { 24 }
}

$resolvedLlmRequestDelaySeconds = if ($PSBoundParameters.ContainsKey("LlmRequestDelaySeconds")) {
    $LlmRequestDelaySeconds
} else {
    $v = Get-OptionValue -Options $fileOptions -Name "LlmRequestDelaySeconds"
    if ($null -ne $v -and [string]$v -match '^\d+$') { [int]$v } else { 2 }
}

$resolvedLlmMaxRetries = if ($PSBoundParameters.ContainsKey("LlmMaxRetries")) {
    $LlmMaxRetries
} else {
    $v = Get-OptionValue -Options $fileOptions -Name "LlmMaxRetries"
    if ($null -ne $v -and [string]$v -match '^\d+$') { [int]$v } else { 2 }
}

$resolvedLlmRetryDelaySeconds = if ($PSBoundParameters.ContainsKey("LlmRetryDelaySeconds")) {
    $LlmRetryDelaySeconds
} else {
    $v = Get-OptionValue -Options $fileOptions -Name "LlmRetryDelaySeconds"
    if ($null -ne $v -and [string]$v -match '^\d+$') { [int]$v } else { 5 }
}

$resolvedRefreshJellyfinLibrary = if ($RefreshJellyfinLibrary.IsPresent) {
    $true
} else {
    $v = Get-OptionValue -Options $fileOptions -Name "RefreshJellyfinLibrary"
    if ($null -ne $v) { [bool]$v } else { $false }
}

# ---------------------------------------------------------------------------
# Validate required parameters
# ---------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($resolvedScanPath)) {
    throw "ScanPath is required. Provide -ScanPath or set ScanPath in options.json."
}

if ([string]::IsNullOrWhiteSpace($resolvedLlmApiKey)) {
    throw "LlmApiKey is required. Provide -LlmApiKey or set LlmApiKey in options.json."
}

if (-not (Test-Path -LiteralPath $resolvedScanPath)) {
    throw "ScanPath not found: $resolvedScanPath"
}

if ($resolvedMaxFiles -lt 0) {
    throw "MaxFiles must be zero (no limit) or a positive number."
}

# ---------------------------------------------------------------------------
# Scan for unprocessed transcript sidecar files
# ---------------------------------------------------------------------------

if (-not [string]::IsNullOrWhiteSpace($resolvedLogFile)) {
    # Resolve relative paths against scriptRoot so the log lands next to the script
    if (-not [System.IO.Path]::IsPathRooted($resolvedLogFile)) {
        $script:llmLogPath = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot $resolvedLogFile))
    } else {
        $script:llmLogPath = $resolvedLogFile
    }
    # Start a fresh log file for this run
    Set-Content -LiteralPath $script:llmLogPath -Value "// vidtag LLM log -- $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')" -Encoding UTF8
    Write-Host "LLM log: $script:llmLogPath"
}

$script:vocabCachePath = $null
if (-not [string]::IsNullOrWhiteSpace($resolvedVocabCacheFile)) {
    if (-not [System.IO.Path]::IsPathRooted($resolvedVocabCacheFile)) {
        $script:vocabCachePath = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot $resolvedVocabCacheFile))
    } else {
        $script:vocabCachePath = $resolvedVocabCacheFile
    }
}

Write-Host ""
Write-Host "vidtag -- LLM metadata enrichment"
Write-Host "Scanning: $resolvedScanPath"

$transcriptFiles = @(Get-ChildItem -LiteralPath $resolvedScanPath -Recurse -Filter "*.vidtranscribe.json" -File -ErrorAction SilentlyContinue)

if ($transcriptFiles.Count -eq 0) {
    Write-Host "No .vidtranscribe.json files found under: $resolvedScanPath"
    Write-Host "SUMMARY|tool=vidtag|status=noop|dry_run=$($DryRun.IsPresent.ToString().ToLowerInvariant())|scanned=0|to_process=0|skipped=0|tagged=0|descriptions=0|failed=0"
    exit 0
}

$toProcess = New-Object System.Collections.Generic.List[object]
$skipped = 0

foreach ($tf in $transcriptFiles) {
    $dir = $tf.DirectoryName
    $baseName = $tf.Name -replace '\.vidtranscribe\.json$', ''

    # Check if already processed
    $sidecarData = $null
    try {
        $raw = Get-Content -LiteralPath $tf.FullName -Raw
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $sidecarData = $raw | ConvertFrom-Json
        }
    }
    catch { }

    if ($sidecarData -and (Get-OptionValue -Options $sidecarData -Name "vidtag_processed") -eq $true) {
        $skipped++
        continue
    }

    # Find matching NFO
    $nfoPath = Join-Path $dir ($baseName + ".nfo")
    if (-not (Test-Path -LiteralPath $nfoPath -PathType Leaf)) {
        Write-Host "  Skipping (no .nfo found): $baseName"
        $skipped++
        continue
    }

    # Find best SRT: prefer .en.srt, fallback to any *.srt
    $enSrt = Join-Path $dir ($baseName + ".en.srt")
    $srtPath = $null
    if (Test-Path -LiteralPath $enSrt -PathType Leaf) {
        $srtPath = $enSrt
    }
    else {
        $anySrt = @(Get-ChildItem -LiteralPath $dir -Filter "$baseName*.srt" -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -ne ($baseName + ".srt") -or $true } |
                    Select-Object -First 1)
        if ($anySrt.Count -gt 0) {
            $srtPath = $anySrt[0].FullName
        }
    }

    if (-not $srtPath) {
        Write-Host "  Skipping (no .srt found): $baseName"
        $skipped++
        continue
    }

    # Find matching video file for visuals
    $videoPath = $null
    if ($resolvedUseVisuals) {
        $videoExts = @(".mp4", ".mkv", ".avi", ".m4v", ".mov")
        foreach ($ext in $videoExts) {
            $candidate = Join-Path $dir ($baseName + $ext)
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $videoPath = $candidate
                break
            }
        }
    }

    $toProcess.Add([PSCustomObject]@{
        BaseName     = $baseName
        Dir          = $dir
        NfoPath      = $nfoPath
        SrtPath      = $srtPath
        SidecarPath  = $tf.FullName
        SidecarData  = $sidecarData
        VideoPath    = $videoPath
    })

    if ($resolvedMaxFiles -gt 0 -and $toProcess.Count -ge $resolvedMaxFiles) {
        break
    }
}

$total = $transcriptFiles.Count
Write-Host "Found $total transcript(s): $($toProcess.Count) to process, $skipped skipped."
Write-Host ""

if ($toProcess.Count -eq 0) {
    Write-Host "SUMMARY|tool=vidtag|status=noop|dry_run=$($DryRun.IsPresent.ToString().ToLowerInvariant())|scanned=$total|to_process=0|skipped=$skipped|tagged=0|descriptions=0|failed=0"
    exit 0
}

if ($DryRun) {
    Write-Host "Dry run -- files that would be processed:"
    foreach ($item in $toProcess) {
        Write-Host "  $($item.BaseName)  [$($item.SrtPath)]"
    }
    Write-Host ""
    Write-Host "SUMMARY|tool=vidtag|status=noop|dry_run=true|scanned=$total|to_process=$($toProcess.Count)|skipped=$skipped|tagged=0|descriptions=0|failed=0"
    exit 0
}

if (-not $NoConfirm) {
    Write-Host "Settings:"
    Write-Host "  Model:              $resolvedLlmModel"
    Write-Host "  Allow new tags:     $resolvedAllowNewTags"
    Write-Host "  Generate plot:      $resolvedGenerateDescription"
    Write-Host "  Use visuals:        $resolvedUseVisuals"
    Write-Host "  Refresh library:    $resolvedRefreshJellyfinLibrary"
    Write-Host ""
    $confirm = Read-Host "Tag $($toProcess.Count) file(s)? (Y/N)"
    if ($confirm -notmatch '^[Yy]') {
        Write-Host "Aborted."
        Write-Host "SUMMARY|tool=vidtag|status=aborted|dry_run=false|scanned=$total|to_process=$($toProcess.Count)|skipped=$skipped|tagged=0|descriptions=0|failed=0"
        exit 0
    }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Fetch Jellyfin vocabulary (optional -- degrade gracefully if unavailable)
# Cached locally so a run doesn't require Jellyfin to be reachable, and so
# tags/genres this script itself writes are remembered without needing a
# fresh Jellyfin round-trip.
# ---------------------------------------------------------------------------

$vocabulary = [PSCustomObject]@{ Tags = @(); Genres = @() }
$vocabFetchedAt = Get-Date

$cachedVocab = Get-VocabularyCache -CacheFile $script:vocabCachePath
$cacheAgeHours = [double]::PositiveInfinity
if ($cachedVocab -and $cachedVocab.FetchedAt) {
    try { $cacheAgeHours = (New-TimeSpan -Start ([datetime]$cachedVocab.FetchedAt) -End (Get-Date)).TotalHours }
    catch { $cacheAgeHours = [double]::PositiveInfinity }
}

$jellyfinConfigured = -not [string]::IsNullOrWhiteSpace($resolvedJellyfinUrl) -and -not [string]::IsNullOrWhiteSpace($resolvedJellyfinApiKey)
$needLiveFetch = $jellyfinConfigured -and ($RefreshVocabulary.IsPresent -or $null -eq $cachedVocab -or $cacheAgeHours -ge $resolvedVocabCacheMaxAgeHours)

if ($needLiveFetch) {
    Write-Host "Fetching Jellyfin tag/genre vocabulary..."
    $live = Get-JellyfinVocabulary -BaseUrl $resolvedJellyfinUrl -ApiKey $resolvedJellyfinApiKey

    if ($live.Tags.Count -eq 0 -and $live.Genres.Count -eq 0 -and $cachedVocab) {
        # Treat a totally empty result as "Jellyfin unreachable" and fall back to cache.
        $vocabulary = [PSCustomObject]@{ Tags = @($cachedVocab.Tags); Genres = @($cachedVocab.Genres) }
        $vocabFetchedAt = [datetime]$cachedVocab.FetchedAt
        Write-Host "  Live fetch returned nothing -- using cached vocabulary from $($vocabFetchedAt.ToString('yyyy-MM-dd HH:mm')): Tags: $($vocabulary.Tags.Count)  Genres: $($vocabulary.Genres.Count)"
    }
    else {
        $mergedTags = @($live.Tags)
        $mergedGenres = @($live.Genres)
        if ($cachedVocab) {
            # Union with cache so locally-added tags/genres aren't lost even if
            # Jellyfin hasn't re-indexed them yet.
            $mergedTags = @(@($mergedTags) + @($cachedVocab.Tags) | Where-Object { $_ } | Sort-Object -Unique)
            $mergedGenres = @(@($mergedGenres) + @($cachedVocab.Genres) | Where-Object { $_ } | Sort-Object -Unique)
        }
        $vocabulary = [PSCustomObject]@{ Tags = $mergedTags; Genres = $mergedGenres }
        $vocabFetchedAt = Get-Date
        Save-VocabularyCache -CacheFile $script:vocabCachePath -FetchedAt $vocabFetchedAt -Tags $mergedTags -Genres $mergedGenres
        Write-Host "  Tags: $($vocabulary.Tags.Count)  Genres: $($vocabulary.Genres.Count)  (live, cached for $resolvedVocabCacheMaxAgeHours h)"
    }
    Write-Host ""
}
elseif ($cachedVocab) {
    $vocabulary = [PSCustomObject]@{ Tags = @($cachedVocab.Tags); Genres = @($cachedVocab.Genres) }
    $vocabFetchedAt = [datetime]$cachedVocab.FetchedAt
    Write-Host "Using cached Jellyfin vocabulary (age: $([int]$cacheAgeHours)h, max: ${resolvedVocabCacheMaxAgeHours}h): Tags: $($vocabulary.Tags.Count)  Genres: $($vocabulary.Genres.Count)"
    Write-Host ""
}
elseif ($jellyfinConfigured) {
    Write-Host "Jellyfin vocabulary fetch skipped and no cache available -- LLM will suggest from context only."
    Write-Host ""
}
else {
    Write-Host "Jellyfin URL/key not configured -- vocabulary fetch skipped. LLM will suggest from context only."
    Write-Host ""
}

# In-memory growable vocabulary sets: tags/genres this run adds to NFOs are
# folded in immediately so later files in the same run see them, and the
# cache file is updated at the end so future runs see them too.
$vocabTagSet   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$vocabGenreSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

# Normalized-key lookups (spelling/casing variants -> canonical vocabulary form)
# used to keep the LLM's suggestions consistent with what's already in use.
$vocabTagNormMap   = [System.Collections.Generic.Dictionary[string, string]]::new()
$vocabGenreNormMap = [System.Collections.Generic.Dictionary[string, string]]::new()

foreach ($t in $vocabulary.Tags) {
    if ($t -and $vocabTagSet.Add($t)) {
        $key = Get-NormalizedTagKey $t
        if ($key -ne "" -and -not $vocabTagNormMap.ContainsKey($key)) { $vocabTagNormMap[$key] = $t }
    }
}
foreach ($g in $vocabulary.Genres) {
    if ($g -and $vocabGenreSet.Add($g)) {
        $key = Get-NormalizedTagKey $g
        if ($key -ne "" -and -not $vocabGenreNormMap.ContainsKey($key)) { $vocabGenreNormMap[$key] = $g }
    }
}
$vocabDirty = $false


# ---------------------------------------------------------------------------
# Process each file
# ---------------------------------------------------------------------------

$tagged       = 0
$descriptions = 0
$failed       = 0
$index        = 0
$tempDir      = $null

if ($resolvedUseVisuals) {
    $tempDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "vidtag_screenshots_" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
}

try {
    foreach ($item in $toProcess) {
        $index++
        $safeName = ConvertTo-ProgressValue $item.BaseName
        Write-Host "PROGRESS|tool=vidtag|event=start|index=$index|total=$($toProcess.Count)|file=$safeName"
        Write-Host "  [$index/$($toProcess.Count)] $($item.BaseName)"

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $fileTagged = $false
        $fileDescribed = $false
        $fileError = $null

        try {
            # Read and truncate transcript
            $transcriptText = Read-SrtText -SrtPath $item.SrtPath
            $wordCount = ($transcriptText -split '\s+' | Where-Object { $_ -ne "" }).Count
            Write-Host "    Transcript words: $wordCount  (from: $(Split-Path -Leaf $item.SrtPath))"

            $truncated = Truncate-ToWordBudget -Text $transcriptText -WordLimit 16000

            # ----------------------------------------------------------------
            # Build LLM tagging prompt
            # ----------------------------------------------------------------

            # Extract existing plot from NFO to give the LLM extra context
            $nfoContent = Get-Content -LiteralPath $item.NfoPath -Raw -Encoding UTF8
            $existingPlot = $null
            if ($nfoContent -match '<plot>([^<]+)</plot>') {
                $existingPlot = $Matches[1].Trim()
            }

            $systemMsg = @"
You are a media metadata assistant. Given information about a video and a vocabulary of existing Jellyfin tags and genres, suggest appropriate metadata enrichment. Respond with a JSON object only.

The JSON must have exactly these keys:
- "genres": array of genre strings to add (from the provided existing_genres list; empty array if none fit)
- "tags": array of tag strings to add from the existing vocabulary
- "new_tags": array of new tag strings not in the existing vocabulary (only if the content clearly warrants them)

Rules:
- Only suggest genres/tags that genuinely describe the content.
- Prefer existing vocabulary over new tags.
- Keep genres broad (e.g. "Documentary", "Comedy"). Keep tags specific.
- Limit to at most 3 genres and 8 tags total combined.
- Return empty arrays if nothing clearly fits.
- The transcript is from an auto-generated subtitle file. Focus only on meaningful spoken dialogue. Ignore: bracketed or parenthesised sound descriptions (e.g. [moaning], (laughing)); and non-lexical vocalisations — repeated short exclamations with no semantic content (e.g. "Oh. Oh. Oh.", "Mm. Mm.", "Ah. Ah."). These are audio artefacts, not dialogue.
- If a plot summary is provided, treat it as the primary source for understanding the content. Use the transcript to fill in detail.
"@

            $userParts = New-Object System.Collections.Generic.List[string]
            $currentVocabJson = [ordered]@{
                existing_genres = @($vocabGenreSet | Sort-Object)
                existing_tags   = @($vocabTagSet | Sort-Object)
            } | ConvertTo-Json -Compress
            $userParts.Add("Vocabulary: $currentVocabJson")
            if (-not [string]::IsNullOrWhiteSpace($existingPlot)) {
                Write-Host "    Plot summary found, including in prompt."
                $userParts.Add("Plot summary: $existingPlot")
            }
            $userParts.Add("Transcript:`n$truncated")
            $userContent = $userParts -join "`n`n"

            $messages = @(
                [ordered]@{ role = "system"; content = $systemMsg }
            )

            # Visuals: attach screenshots as base64 image content blocks
            if ($resolvedUseVisuals -and $item.VideoPath) {
                Write-Host "    Extracting screenshots from: $(Split-Path -Leaf $item.VideoPath)"
                $screenshots = Get-VideoScreenshots -VideoPath $item.VideoPath -FfmpegBin $resolvedFfmpegPath -TempDir $tempDir

                if ($screenshots.Count -gt 0) {
                    $contentParts = New-Object System.Collections.Generic.List[object]
                    $contentParts.Add([ordered]@{ type = "text"; text = $userContent })
                    foreach ($b64 in $screenshots) {
                        $contentParts.Add([ordered]@{
                            type      = "image_url"
                            image_url = [ordered]@{
                                url    = "data:image/jpeg;base64,$b64"
                                detail = "low"
                            }
                        })
                    }
                    $messages += [ordered]@{ role = "user"; content = @($contentParts) }
                }
                else {
                    $messages += [ordered]@{ role = "user"; content = $userContent }
                }
            }
            else {
                $messages += [ordered]@{ role = "user"; content = $userContent }
            }

            Write-Host "    Calling LLM for tagging ($resolvedLlmModel)..."
            $llmResult = Invoke-LlmJson -BaseUrl $resolvedLlmBaseUrl -ApiKey $resolvedLlmApiKey `
                                         -Model $resolvedLlmModel -Messages $messages -TaskLabel $item.BaseName `
                                         -PacingDelaySeconds $resolvedLlmRequestDelaySeconds -MaxRetries $resolvedLlmMaxRetries -RetryDelaySeconds $resolvedLlmRetryDelaySeconds

            $suggestedGenres = @()
            $suggestedTags   = @()

            if ($llmResult.PSObject.Properties.Name -contains "genres" -and $llmResult.genres) {
                $rawGenres = @($llmResult.genres | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                $suggestedGenres = Resolve-VocabTerms -Suggested $rawGenres -NormMap $vocabGenreNormMap
            }
            if ($llmResult.PSObject.Properties.Name -contains "tags" -and $llmResult.tags) {
                $rawTags = @($llmResult.tags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                $suggestedTags = Resolve-VocabTerms -Suggested $rawTags -NormMap $vocabTagNormMap
            }

            # Handle new_tags -- separate ones that turn out to already exist (by
            # normalized spelling/casing) from genuinely new ones, since AllowNewTags
            # should only gate the latter.
            if ($llmResult.PSObject.Properties.Name -contains "new_tags" -and $llmResult.new_tags) {
                $rawNewTags = @($llmResult.new_tags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                $knownFromNew = New-Object System.Collections.Generic.List[string]
                $genuinelyNew = New-Object System.Collections.Generic.List[string]
                $seenNewKeys  = [System.Collections.Generic.HashSet[string]]::new()

                foreach ($t in $rawNewTags) {
                    $key = Get-NormalizedTagKey $t
                    if ($key -eq "" -or -not $seenNewKeys.Add($key)) { continue }
                    if ($vocabTagNormMap.ContainsKey($key)) {
                        $knownFromNew.Add($vocabTagNormMap[$key])
                    }
                    else {
                        $genuinelyNew.Add((Format-TagCasing $t))
                    }
                }

                if ($knownFromNew.Count -gt 0) {
                    $suggestedTags += @($knownFromNew)
                }
                if ($genuinelyNew.Count -gt 0) {
                    if ($resolvedAllowNewTags) {
                        Write-Host "    New tags accepted: $($genuinelyNew -join ', ')"
                        $suggestedTags += @($genuinelyNew)
                    }
                    else {
                        Write-Host "    New tags suggested (not applied, AllowNewTags=false): $($genuinelyNew -join ', ')"
                    }
                }
            }

            # Final pass: de-duplicate the combined tag list by normalized key, in
            # case "tags" and "new_tags" suggested the same term with different spelling.
            $suggestedTags = Resolve-VocabTerms -Suggested $suggestedTags -NormMap $vocabTagNormMap

            Write-Host "    Genres: $($suggestedGenres -join ', ')"
            Write-Host "    Tags:   $($suggestedTags -join ', ')"

            # ----------------------------------------------------------------
            # Optional description generation
            # ----------------------------------------------------------------

            $newPlot = $null
            if ($resolvedGenerateDescription -and $wordCount -ge 200) {
                $plotCheckContent = Get-Content -LiteralPath $item.NfoPath -Raw -Encoding UTF8
                $plotEmpty = ($plotCheckContent -match '<plot>\s*</plot>') -or ($plotCheckContent -notmatch '<plot>')

                if ($plotEmpty) {
                    Write-Host "    Calling LLM for plot description..."
                    $plotSystem = "You are a creative media copywriter. Write a 2-3 sentence plot description that works as an enticing hook for viewers. Be vivid and engaging -- do not write a neutral scene-by-scene summary. Return a JSON object with a single key: `"plot`"."
                    $plotUser   = "Transcript:`n$truncated"

                    $plotMessages = @(
                        [ordered]@{ role = "system"; content = $plotSystem }
                        [ordered]@{ role = "user";   content = $plotUser }
                    )

                    $plotResult = Invoke-LlmJson -BaseUrl $resolvedLlmBaseUrl -ApiKey $resolvedLlmApiKey `
                                                  -Model $resolvedLlmModel -Messages $plotMessages -TaskLabel "$($item.BaseName) [plot]" `
                                                  -PacingDelaySeconds $resolvedLlmRequestDelaySeconds -MaxRetries $resolvedLlmMaxRetries -RetryDelaySeconds $resolvedLlmRetryDelaySeconds

                    if ($plotResult.PSObject.Properties.Name -contains "plot") {
                        $newPlot = Normalize-OptionalString $plotResult.plot
                    }

                    if (-not [string]::IsNullOrWhiteSpace($newPlot)) {
                        Write-Host "    Plot: $($newPlot.Substring(0, [Math]::Min(80, $newPlot.Length)))..."
                    }
                }
                else {
                    Write-Host "    Plot already present, skipping description generation."
                }
            }
            elseif ($resolvedGenerateDescription -and $wordCount -lt 200) {
                Write-Host "    Transcript too short for description ($wordCount words < 200), skipping."
            }

            # ----------------------------------------------------------------
            # Write NFO
            # ----------------------------------------------------------------

            $mergeResult = Merge-NfoFields -NfoPath $item.NfoPath `
                                            -NewGenres $suggestedGenres `
                                            -NewTags $suggestedTags `
                                            -NewPlot $newPlot

            if ($mergeResult.AddedGenres.Count -gt 0 -or $mergeResult.AddedTags.Count -gt 0 -or $mergeResult.PlotUpdated) {
                Write-Host "    NFO updated: +$($mergeResult.AddedGenres.Count) genre(s), +$($mergeResult.AddedTags.Count) tag(s)$(if ($mergeResult.PlotUpdated) { ', plot set' })"
                $fileTagged = $true
                if ($mergeResult.PlotUpdated) { $fileDescribed = $true }

                # Grow the in-memory (and eventually cached) vocabulary with anything new,
                # so later files in this run -- and future runs -- see it.
                foreach ($g in $mergeResult.AddedGenres) {
                    if ($vocabGenreSet.Add($g)) {
                        $vocabDirty = $true
                        $key = Get-NormalizedTagKey $g
                        if ($key -ne "" -and -not $vocabGenreNormMap.ContainsKey($key)) { $vocabGenreNormMap[$key] = $g }
                    }
                }
                foreach ($t in $mergeResult.AddedTags) {
                    if ($vocabTagSet.Add($t)) {
                        $vocabDirty = $true
                        $key = Get-NormalizedTagKey $t
                        if ($key -ne "" -and -not $vocabTagNormMap.ContainsKey($key)) { $vocabTagNormMap[$key] = $t }
                    }
                }
            }
            else {
                Write-Host "    NFO unchanged (all suggestions already present or none suggested)."
            }

            # ----------------------------------------------------------------
            # Mark sidecar as processed
            # ----------------------------------------------------------------

            try {
                $sidecarObj = $item.SidecarData
                if ($null -eq $sidecarObj) {
                    $sidecarObj = [PSCustomObject]@{}
                }
                # Add or update vidtag_processed
                if ($sidecarObj.PSObject.Properties.Name -contains "vidtag_processed") {
                    $sidecarObj.vidtag_processed = $true
                }
                else {
                    $sidecarObj | Add-Member -MemberType NoteProperty -Name "vidtag_processed" -Value $true
                }
                $sidecarObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $item.SidecarPath -Encoding UTF8
            }
            catch {
                Write-Host "    WARNING: Could not update sidecar: $($_.Exception.Message)"
            }
        }
        catch {
            $fileError = $_.Exception.Message
            Write-Host "    ERROR: $fileError"
            $failed++
        }

        $stopwatch.Stop()
        $elapsed = [int]$stopwatch.Elapsed.TotalSeconds

        if ($null -eq $fileError) {
            if ($fileTagged) { $tagged++ }
            if ($fileDescribed) { $descriptions++ }
            Write-Host "PROGRESS|tool=vidtag|event=complete|index=$index|total=$($toProcess.Count)|file=$safeName|elapsed_seconds=$elapsed|tagged=$tagged|described=$descriptions|failed=$failed"
        }
        else {
            $safeError = ConvertTo-ProgressValue $fileError
            Write-Host "PROGRESS|tool=vidtag|event=complete|index=$index|total=$($toProcess.Count)|file=$safeName|elapsed_seconds=$elapsed|tagged=$tagged|described=$descriptions|failed=$failed|error=$safeError"
        }
    }
}
finally {
    if ($tempDir -and (Test-Path -LiteralPath $tempDir)) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($vocabDirty -and -not [string]::IsNullOrWhiteSpace($script:vocabCachePath)) {
    Save-VocabularyCache -CacheFile $script:vocabCachePath -FetchedAt $vocabFetchedAt -Tags @($vocabTagSet) -Genres @($vocabGenreSet)
    Write-Host ""
    Write-Host "Vocabulary cache updated with newly added tag(s)/genre(s): Tags: $($vocabTagSet.Count)  Genres: $($vocabGenreSet.Count)"
}

if ($resolvedRefreshJellyfinLibrary -and $tagged -gt 0) {
    if ($jellyfinConfigured) {
        Write-Host ""
        Write-Host "Triggering Jellyfin library scan..."
        try {
            $headers = @{ "X-MediaBrowser-Token" = $resolvedJellyfinApiKey }
            Invoke-RestMethod -Uri ($resolvedJellyfinUrl.TrimEnd("/") + "/Library/Refresh") -Method POST -Headers $headers -TimeoutSec 30 -ErrorAction Stop | Out-Null
            Write-Host "  Library scan triggered."
        }
        catch {
            Write-Host "  WARNING: Could not trigger Jellyfin library scan: $($_.Exception.Message)"
        }
    }
    else {
        Write-Host ""
        Write-Host "RefreshJellyfinLibrary is set but JellyfinUrl/JellyfinApiKey are not configured -- skipping."
    }
}

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "Done. Processed $($toProcess.Count) file(s): $tagged tagged, $descriptions plot(s) written, $failed failed."

$status = if ($failed -gt 0 -and $tagged -eq 0) { "failed" } elseif ($tagged -eq 0 -and $descriptions -eq 0) { "noop" } else { "ok" }
Write-Host "SUMMARY|tool=vidtag|status=$status|dry_run=false|scanned=$total|to_process=$($toProcess.Count)|skipped=$skipped|tagged=$tagged|descriptions=$descriptions|failed=$failed"

if ($failed -gt 0) { exit 1 } else { exit 0 }
