# vidrecompress

Scans a folder for `.avi` files, encodes each with HandBrakeCLI, and **replaces the source with the `.mp4` only if the encoded result is smaller**. Files that already have a matching `.mp4` in the same directory are skipped automatically.

This is an in-place recompression workflow — not the normal collect → pick → match → encode → copy pipeline.

## Usage

```powershell
# PS7 (recommended)
.\vidrecompress.ps7.ps1 -SourceDir "C:\path\to\library" -TempDir "C:\path\to\temp-encode" -PresetName "My Preset"

# PS5
.\vidrecompress.ps1 -SourceDir "C:\path\to\library" -TempDir "C:\path\to\temp-encode" -PresetName "My Preset"

# Dry run (preview only, no changes)
.\vidrecompress.ps7.ps1 -DryRun

# Recurse into subdirectories
.\vidrecompress.ps7.ps1 -Recurse

# Unattended / scripted
.\vidrecompress.ps7.ps1 -NoConfirm

# Process largest files first (default)
.\vidrecompress.ps7.ps1 -ProcessOrder size_desc

# Process smallest files first (better for quick stop/pause responsiveness)
.\vidrecompress.ps7.ps1 -ProcessOrder size_asc
```

## Parameters

| Parameter | Required | Default | Description |
| --- | --- | --- | --- |
| `-SourceDir` | Yes* | — | Directory to scan for source files |
| `-TempDir` | Yes* | — | Directory for temporary encoded files |
| `-PresetName` | Yes* | — | HandBrake preset name |
| `-PresetImportFile` | No | — | Path to HandBrake `.json` preset file |
| `-HandBrakeCliPath` | No | `HandBrakeCLI` | Path to `HandBrakeCLI.exe` (or name if on PATH) |
| `-OutputExtension` | No | `.mp4` | Output file extension |
| `-SourceExtensions` | No | `.avi` | Source file extensions to scan |
| `-ProcessOrder` | No | `size_desc` | Candidate ordering: `name_asc`, `name_desc`, `size_asc`, `size_desc` |
| `-Recurse` | No | `false` | Scan subdirectories |
| `-OptionsFile` | No | sibling `options.json` | Path to options file |
| `-DryRun` | No | — | Preview without making changes |
| `-NoConfirm` | No | — | Skip confirmation prompt (also skips options file creation prompt) |
| `-VerboseConsole` | No | — | Print raw `PROGRESS\|` lines to console (default: suppressed) |

*Required unless provided via `options.json`.

## Configuration

Copy `options.json.example` to `options.json` in this folder and fill in your paths. On first run without an options file, the script will prompt you to create one.

Config precedence: CLI arguments > `options.json` > script defaults.

```json
{
  "SourceDir": "C:/path/to/library",
  "TempDir": "C:/path/to/temp-encode",
  "PresetName": "My Custom Preset",
  "PresetImportFile": "C:/path/to/custom-presets.json",
  "HandBrakeCliPath": "HandBrakeCLI",
  "OutputExtension": ".mp4",
  "SourceExtensions": [".avi"],
  "ProcessOrder": "size_desc",
  "Recurse": false
}
```

## Workflow

1. Scans `SourceDir` for files matching `SourceExtensions` (root only, or recursive with `-Recurse`).
2. Orders candidates using `ProcessOrder` (`size_desc` by default).
3. Skips any file whose basename already has a matching output file (e.g. `.mp4`) in the same directory.
4. Checks that `TempDir` has enough free space (`fileSize × 1.2 + 100 MB`); skips file and logs warning if not.
5. Encodes the file with HandBrakeCLI into `TempDir`.
6. Compares sizes:
   - **Encoded is smaller**: deletes the source `.avi`, moves the `.mp4` to the same directory.
   - **Encoded is same size or larger**: deletes the temp file, keeps the original (not a failure).
7. On error or interruption, cleans up any partial temp file for the current in-progress file.

## Console output

During the run a `Write-Progress` bar shows the current file, position, and ETA:

```
vidrecompress [12/88 | ExampleVideo_001... | ETA 6h 12m]
```

Each completed file prints one result line with per-file saved size and running session total:

```
Replaced: ExampleVideo_001.avi (382 MB -> 297 MB, saved 85.0 MB; total saved 1.3 GB)
Kept original: SomeFile.avi (encoded 391 MB >= source 386 MB)
```

After the run a scorecard is printed:

```
Recompress run
 status:            ok
 total:             28340.1s
 candidates:        88
 skipped_existing:  4
 encoded:           84   failed: 0
 replaced:          79   kept_original: 5
 space_saved:       8.0 GB
```

Raw `PROGRESS|` lines are suppressed by default. Use `-VerboseConsole` to print them (useful for scripted/dispatch consumption).

## Output lines

### PROGRESS (after each file, only with -VerboseConsole)

```
PROGRESS|tool=vidrecompress|event=update|index=N|total=M|file=<basename>|elapsed_seconds=N|encoded=E|replaced=R|kept_original=K|encode_failed=F
```

### SUMMARY (final line)

```
SUMMARY|tool=vidrecompress|status=<ok|noop|failed|stopped|interrupted>|dry_run=<true|false>|candidates=N|skipped_existing=N|skipped_no_space=N|encoded=N|encode_failed=N|replaced=N|kept_original=N|space_saved_mb=N|warnings=N
```

Status values:
- `ok` — completed (includes `kept_original > 0`, which is expected behaviour)
- `noop` — no candidates found or all skipped
- `failed` — at least one encode failed
- `stopped` — stop sentinel requested a clean stop between files
- `interrupted` — externally interrupted (for example Ctrl+C)
- `aborted` — user declined confirmation prompt

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success (including noop, aborted, kept original) |
| `1` | At least one encode failed |

## Safety

- Source files are **never deleted** unless the temp `.mp4` was successfully written and is strictly smaller.
- Partial temp files are cleaned up on error or interruption (only the current in-progress file, not the whole TempDir).
- `TempDir` and `SourceDir` must not be the same path.
- `-DryRun` makes no changes and prints what would happen.

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+
- [HandBrakeCLI](https://handbrake.fr/downloads2.php) on PATH or configured via `HandBrakeCliPath`
