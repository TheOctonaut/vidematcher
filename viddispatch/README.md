# viddispatch

Runs the full video processing pipeline in sequence:

1. **vidpicker** — move source video files from staging into the handbrake processing folder
2. **vidmatch** — compare the handbrake folder against the final folder to find files not yet encoded
3. **videncode** — encode the unmatched files via HandBrakeCLI and move outputs to the final folder
4. **reconcile cleanup** — compare handbrake leftovers to final files by basename and enforce size rules

Before step 1, dispatcher runs a **videncode preflight check** (dry-run, no changes) to validate
HandBrakeCLI/preset configuration. If preflight fails, dispatcher exits before moving or deleting files.

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+
- All three tool scripts present in the expected sibling subfolders (`vidpicker/`, `vidmatch/`, `videncode/`)
- Each tool's `options.json` set up with its own settings (preset, extensions, etc.)
- [HandBrake CLI](https://handbrake.fr/downloads2.php) configured in `videncode/options.json`

## Files

- `viddispatch.ps1`: main dispatcher script
- `options.json.example`: committed template
- `options.json`: local runtime config (created on demand, gitignored)

## Configuration Priority

Settings are resolved in this order:

1. Command-line arguments
2. Options file (`options.json` by default, or `-OptionsFile`)

If the options file is missing, the script prompts to create it.

## Required Settings

| Setting | Description |
| --- | --- |
| `StagingDir` | Source folder containing raw video files to pick up |
| `HandbrakeDir` | Processing folder (vidpicker destination; vidmatch + videncode source) |
| `FinalDir` | Final archive folder (vidmatch target; videncode destination) |

## Optional Settings

| Setting | Description |
| --- | --- |
| `VidpickerScript` | Override path to `vidpicker.ps1` (default: `../vidpicker/vidpicker.ps1`) |
| `VidmatchScript` | Override path to `vidmatch.ps1` (default: `../vidmatch/vidmatch.ps1`) |
| `VidencodeScript` | Override path to `videncode.ps1` (default: `../videncode/videncode.ps1`) |

## Parameters

| Parameter | Type | Description |
| --- | --- | --- |
| `-StagingDir` | string | Staging folder (overrides options.json) |
| `-HandbrakeDir` | string | Handbrake processing folder (overrides options.json) |
| `-FinalDir` | string | Final destination folder (overrides options.json) |
| `-OptionsFile` | string | Path to options JSON (default: `options.json` in script folder) |
| `-VidpickerScript` | string | Override path to vidpicker.ps1 |
| `-VidmatchScript` | string | Override path to vidmatch.ps1 |
| `-VidencodeScript` | string | Override path to videncode.ps1 |
| `-SkipPick` | switch | Skip the vidpicker step (useful if files are already in HandbrakeDir) |
| `-DryRun` | switch | Propagate dry run to all tools; no files are moved or encoded |
| `-NoConfirm` | switch | Propagate no-confirm to all tools; skip all confirmation prompts |

## Common Command Line Usage

### 1) Run the full pipeline using options.json

```powershell
.\viddispatch.ps1
```

### 2) Preview the pipeline without making any changes

```powershell
.\viddispatch.ps1 -DryRun
```

### 3) Run unattended (no prompts)

```powershell
.\viddispatch.ps1 -NoConfirm
```

### 4) Skip the pick step (files already in handbrake folder)

```powershell
.\viddispatch.ps1 -SkipPick
```

### 5) Override directories on the command line

```powershell
.\viddispatch.ps1 `
  -StagingDir "C:/path/to/staging" `
  -HandbrakeDir "C:/path/to/handbrake" `
  -FinalDir "C:/path/to/final" `
  -NoConfirm
```

## Pipeline Detail

### Step 1 - vidpicker

Moves video files from `StagingDir` to `HandbrakeDir`. Source subfolders that contained
matched files are deleted, and any empty ancestor folders are removed.

Skipped when `-SkipPick` is set.

### Step 2 - vidmatch

Scans `HandbrakeDir` and `FinalDir`, compares files by basename (ignoring extension).
Produces a list of files in `HandbrakeDir` that have no matching basename in `FinalDir`.

These are the files that have not yet been encoded.

If there are no unmatched files, the encode step is skipped and reconcile cleanup still runs.

### Step 3 - videncode

Encodes the unmatched files from step 2 using HandBrakeCLI. Each tool's own `options.json`
(in its subfolder) provides the preset name, preset import file, and other encode settings.

Outputs are staged to a temp folder first, then moved to `FinalDir` on success.

### Step 4 - post-encode reconcile cleanup

After the encode step (or after a no-unmatched result), the dispatcher scans video files in
`HandbrakeDir` and compares them to matching basenames in `FinalDir`.

Rules:

- If the smallest matching final file is larger than the handbrake source file:
remove the inflated final file(s), move the untouched handbrake source file into `FinalDir`, and emit noisy output markers (`[NOISY]`).

- If the smallest matching final file is smaller than the handbrake source file:
delete the handbrake source file.

- If sizes are equal:
keep the handbrake source file (no automatic deletion).

## Individual Tool Options

Each tool reads its own `options.json` for encoding settings (preset, extensions, HandBrakeCLI path, etc.).

- `viddispatch/options.json`: the three directory paths
- `videncode/options.json`: preset, HandBrakeCLI path, extensions
- `vidpicker/options.json`: pick extensions (not used directly by dispatcher; dirs are passed explicitly)
- `vidmatch/options.json`: not used during dispatch; dirs are passed explicitly

## Safety

- vidpicker will prompt for confirmation before moving/deleting files unless `-NoConfirm` is set.
- videncode will prompt for confirmation before encoding unless `-NoConfirm` is set.
- `-DryRun` propagates to both: no files are moved or encoded.
- A videncode preflight check runs first to ensure encode dependencies are available before destructive steps.
- If any step fails (non-zero exit), the pipeline stops immediately.

## SUMMARY Output

The dispatcher emits one parseable line on every handled path:

```text
SUMMARY|tool=viddispatch|status=ok|dry_run=false|skip_pick=false|picked=N|unmatched=N|encoded=N|encode_failed=N|moved=N|move_failed=N
SUMMARY|tool=viddispatch|status=ok|dry_run=false|skip_pick=false|picked=N|unmatched=N|encoded=N|encode_failed=N|moved=N|move_failed=N|reconcile_inspected=N|reconcile_replaced_inflated=N|reconcile_deleted_final_inflated=N|reconcile_deleted_handbrake_smaller=N|reconcile_kept_equal=N|reconcile_missing_final_match=N|reconcile_errors=N
```

Status values: `ok`, `noop`, `failed`, `aborted`

## Options File Example

`options.json.example`:

```json
{
  "StagingDir": "C:/path/to/staging",
  "HandbrakeDir": "C:/path/to/handbrake",
  "FinalDir": "C:/path/to/final"
}
```

## Notes

- `videncode/options.json` must be configured separately with the HandBrake preset and path settings.
- vidmatch and videncode both independently skip files already present in `FinalDir` (by basename). This means even if a file appears in the unmatched list from vidmatch, videncode will skip it if it was moved to `FinalDir` between the two steps.
- Source files in `HandbrakeDir` are never deleted by videncode. They remain after encoding.
