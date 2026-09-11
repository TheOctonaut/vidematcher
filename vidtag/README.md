# vidtag

LLM-powered metadata enrichment for Jellyfin `.nfo` files. Reads transcripts
produced by `vidtranscribe` and uses a language model to suggest genres, tags,
and optionally a plot description.

**This tool is standalone — it is never part of the `viddispatch` pipeline.**

---

## How It Works

1. Scans a directory recursively for `*.vidtranscribe.json` sidecar files where
   `vidtag_processed` is absent or `false`, AND a matching `.nfo` exists.
2. Optionally fetches existing tags and genres from the Jellyfin API so the LLM
   works from your library's established vocabulary. Results are cached locally
   (see "Vocabulary caching" below) so this doesn't have to happen every run.
3. Reads the corresponding `.en.srt` subtitle (or the first `.srt` found if no
   English subtitle exists), truncates to ~4000 words, and sends it to the LLM.
4. Merges suggested `<genre>` and `<tag>` entries into the `.nfo` without
   removing existing ones.
5. Marks `vidtag_processed: true` in the sidecar so the file is skipped next run.
6. Optionally generates a 2-3 sentence plot hook if `<plot>` is empty and the
   transcript has at least 200 words (`-GenerateDescription`).
7. Optionally extracts 4 screenshots at 25%/50%/75%/95% duration and sends
   them to a vision-capable model for additional context (`-UseVisuals`).

---

## Requirements

- PowerShell 5.1 or 7+
- Network access to an OpenAI-compatible API endpoint
- `ffmpeg` on PATH (only required when `-UseVisuals` is set)
- A Jellyfin server (optional — enrichment works without it, LLM uses context
  only)

---

## Setup

1. Copy `options.json.example` to `options.json` in this folder.
2. Fill in `LlmApiKey` (required) and other settings.
3. Run `vidtag.ps1 -ScanPath C:\path\to\media`.

---

## Parameters

| Parameter | Type | Description |
|---|---|---|
| `-ScanPath` | string | Root directory to scan for `.vidtranscribe.json` files. Required. |
| `-OptionsFile` | string | Path to a custom options JSON file. |
| `-JellyfinUrl` | string | Jellyfin server base URL (e.g. `http://localhost:8096`). |
| `-JellyfinApiKey` | string | Jellyfin API key for vocabulary fetch. |
| `-LlmBaseUrl` | string | OpenAI-compatible API base URL. Default: `https://api.openai.com/v1`. |
| `-LlmApiKey` | string | API key for the LLM endpoint. Required. |
| `-LlmModel` | string | Model name. Default: `gpt-4o`. |
| `-MaxFiles` | int | Maximum files to process per run (0 = unlimited). |
| `-AllowNewTags` | switch | Accept LLM-suggested tags not in the Jellyfin vocabulary. |
| `-GenerateDescription` | switch | Write a plot description when `<plot>` is empty. |
| `-UseVisuals` | switch | Extract video screenshots and send to a vision model. |
| `-FfmpegPath` | string | Path to `ffmpeg`. Default: `ffmpeg` (on PATH). |
| `-VocabCacheFile` | string | Path to the vocabulary cache file. Default: `vidtag-vocab-cache.json` (relative to this folder). |
| `-VocabCacheMaxAgeHours` | int | How long a cached vocabulary is trusted before a live Jellyfin refetch is attempted. Default: `24`. |
| `-RefreshVocabulary` | switch | Force a live Jellyfin vocabulary refetch regardless of cache age. |
| `-LlmRequestDelaySeconds` | int | Pause before each LLM call to pace requests and avoid rate limits. Default: `2`. |
| `-LlmMaxRetries` | int | Retries on HTTP 429 (rate limited) responses before giving up. Default: `2`. |
| `-LlmRetryDelaySeconds` | int | Base backoff between 429 retries (honors the response's `Retry-After` header when present). Default: `5`. |
| `-RefreshJellyfinLibrary` | switch | Trigger a Jellyfin library scan (`POST /Library/Refresh`) at the end of the run, if at least one file was tagged. |
| `-DryRun` | switch | Preview files that would be processed without making changes. |
| `-NoConfirm` | switch | Skip the confirmation prompt (for automation). |

---

## options.json keys

```json
{
  "ScanPath": "C:/path/to/media",
  "JellyfinUrl": "http://localhost:8096",
  "JellyfinApiKey": "",
  "LlmBaseUrl": "https://api.openai.com/v1",
  "LlmApiKey": "",
  "LlmModel": "gpt-4o",
  "AllowNewTags": false,
  "MaxFiles": 0,
  "GenerateDescription": false,
  "UseVisuals": false,
  "FfmpegPath": "ffmpeg",
  "VocabCacheFile": "vidtag-vocab-cache.json",
  "VocabCacheMaxAgeHours": 24,
  "LlmRequestDelaySeconds": 2,
  "LlmMaxRetries": 2,
  "LlmRetryDelaySeconds": 5,
  "RefreshJellyfinLibrary": false
}
```

---

## Output

Progress lines during processing:

```
PROGRESS|tool=vidtag|event=start|index=1|total=5|file=My Movie
PROGRESS|tool=vidtag|event=complete|index=1|total=5|file=My Movie|elapsed_seconds=12|tagged=1|described=0|failed=0
```

Final summary line:

```
SUMMARY|tool=vidtag|status=ok|dry_run=false|scanned=10|to_process=5|skipped=5|tagged=4|descriptions=1|failed=0
```

Exit codes: `0` = success (including no-op), `1` = one or more files failed.

---

## Transcript truncation

Most videos in this library are short (under 30 minutes) so the full transcript
is included in almost all cases. The word budget is 16,000 words — only
unusually long or dense transcripts will be truncated. When truncation does
occur, a head+tail strategy is used: the first and last halves of the budget are
kept with `[...]` in the middle, preserving both the opening tone/genre signals
and the closing themes.

---

## AllowNewTags behaviour

When `AllowNewTags` is `false` (default), new tag suggestions from the LLM are
logged but **not** written to the NFO. This lets you review what the LLM would
add before enabling the switch.

When `AllowNewTags` is `true`, new tags are accepted silently and added to the
NFO alongside existing-vocabulary tags.

---

## Jellyfin library refresh

NFO changes are not picked up automatically on network shares. Two options:

- Manual: Dashboard → Libraries → "Scan All Libraries", or the three-dot menu
  on the specific library → "Scan Library Files".
- Automatic: set `-RefreshJellyfinLibrary` (or `RefreshJellyfinLibrary: true`
  in options.json). At the end of a run, if at least one file was actually
  tagged, `POST /Library/Refresh` is called on the Jellyfin server. This is
  best-effort — a failure here only prints a warning, it does not fail the run.

---

## Rate-limit pacing

To avoid tripping LLM provider rate limits during a batch:

- `LlmRequestDelaySeconds` (default 2) pauses briefly before every LLM call.
- On an HTTP 429 (rate limited) response, the call is retried automatically
  up to `LlmMaxRetries` times (default 2), honoring the response's
  `Retry-After` header when the provider sends one, otherwise backing off
  `LlmRetryDelaySeconds` (default 5) seconds, increasing with each retry.
- Set `LlmRequestDelaySeconds: 0` to disable pacing entirely.

---

## Vocabulary caching

Jellyfin's tag/genre vocabulary is cached to `VocabCacheFile` (default
`vidtag-vocab-cache.json` next to the script, gitignored) so the tool doesn't
need to hit Jellyfin on every run, and still works if Jellyfin is temporarily
offline.

- On each run, a live fetch is attempted only if the cache is missing, older
  than `VocabCacheMaxAgeHours` (default 24h), or `-RefreshVocabulary` is passed.
- A successful live fetch is **unioned** with the existing cache (not
  replaced), so anything the cache already knew about is kept even if
  Jellyfin's own index lags behind (e.g. before a scheduled library scan).
- If Jellyfin is unreachable and a cache exists, the run falls back to the
  cache automatically (with a console note) instead of failing or proceeding
  with an empty vocabulary.
- Any genre/tag this run actually writes to an `.nfo` is folded into the
  in-memory vocabulary immediately (so later files in the same run benefit)
  and the cache file is updated at the end of the run — so new tags/genres
  the tool itself creates are remembered without waiting on Jellyfin.

---

## Examples

```powershell
# Preview what would be processed
.\vidtag.ps1 -ScanPath C:\path\to\media -DryRun

# Tag up to 10 files, accepting new tags, no confirmation prompt
.\vidtag.ps1 -ScanPath C:\path\to\media -MaxFiles 10 -AllowNewTags -NoConfirm

# Full enrichment with plot descriptions and screenshots
.\vidtag.ps1 -ScanPath C:\path\to\media -GenerateDescription -UseVisuals -NoConfirm

# Use a local LLM (Ollama / LM Studio)
.\vidtag.ps1 -ScanPath C:\path\to\media -LlmBaseUrl http://localhost:11434/v1 -LlmApiKey "ollama" -LlmModel "llama3.2"
```
