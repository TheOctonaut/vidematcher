# videncode

Encode video files using HandBrakeCLI with a specified preset, skipping files that already have a matching basename in the destination folder, and move completed outputs to the destination.

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+
- [HandBrake CLI](https://handbrake.fr/downloads2.php) (`HandBrakeCLI.exe`) installed and in PATH, or its path set in `options.json`

## Files

- `videncode.ps1`: main script
- `options.json.example`: committed template file
- `options.json`: local runtime config file (created on demand, gitignored)

## How It Works

1. Scans `DestDir` for existing files (by basename, ignoring extension).
2. Flushes any files in the `.videncode-ready` holding folder to `DestDir` if there is enough free space (see full-disk handling below).
3. Scans `SourceDir` (or uses an explicit `InputFiles` list) for candidate files matching `SourceExtensions`.
4. Any candidate whose basename already exists in `DestDir` or in `.videncode-ready` is skipped.
5. Remaining files are encoded one by one using HandBrakeCLI with the configured preset.
6. After each encode, a pre-flight space check decides where the output goes:
   - Enough space in `DestDir` → move directly to `DestDir`.
   - Not enough space → move to `.videncode-ready` (deferred for the next run).
7. Source files are never deleted by videncode.

Encoded files are temporarily written to a `.videncode-temp` folder inside `SourceDir`. They are moved out of temp (to `DestDir` or `.videncode-ready`) only on success, so partial outputs never land in either location.

### Full-disk handling

When `DestDir` is full or nearly full, videncode continues encoding rather than stopping. Each encoded output is space-checked before the move:

- If `DestDir` has at least `encodedSize + 100 MB` free, the file is moved there normally.
- Otherwise it is placed in `.videncode-ready` (a holding folder inside `SourceDir`). The source file is kept and skipped on future runs until the held file is flushed.

At the start of every run, videncode attempts to flush any pending `.videncode-ready` files to `DestDir` before encoding new files. Once the destination has space again, the next run automatically clears the backlog.

This means a run that could not move all files still exits with status `partial` (not `failed`) and continues to reconcile.

## Configuration Priority

Settings are resolved in this order:

1. Command-line arguments
2. Options file (`options.json` by default, or `-OptionsFile`)
3. Hardcoded defaults in the script

If the selected options file does not exist, the script prompts to create it.
When available, it copies from `options.json.example`.

## Defaults

- HandBrakeCliPath: `HandBrakeCLI` (resolved from PATH)
- OutputExtension: `.mp4`
- SourceExtensions: `[".avi", ".mp4", ".mkv"]`

Required:

- `SourceDir`: must be set via `-SourceDir` or in `options.json`
- `DestDir`: must be set via `-DestDir` or in `options.json`
- `PresetName`: must be set via `-PresetName` or in `options.json`

## Parameters

| Parameter | Type | Description |
| --- | --- | --- |
| `-SourceDir` | string | Folder to scan for input files |
| `-DestDir` | string | Folder to receive encoded output files |
| `-OptionsFile` | string | Path to options JSON file (default: `options.json` in script folder) |
| `-InputFiles` | string[] | Explicit list of files to encode (absolute or relative to SourceDir). Merges with `-InputFilesListFile` if both are provided. |
| `-InputFilesListFile` | string | Path to a UTF-8 text file containing one input file path per line. Useful for large batches and paths with spaces. |
| `-PresetName` | string | HandBrake preset name (case-sensitive) |
| `-PresetImportFile` | string | Path to a custom preset JSON file to import |
| `-HandBrakeCliPath` | string | Full path or command name for HandBrakeCLI |
| `-OutputExtension` | string | Extension for encoded output files (default: `.mp4`) |
| `-SourceExtensions` | string[] | Extensions to include when scanning SourceDir |
| `-DryRun` | switch | Preview what would be encoded without running anything |
| `-NoConfirm` | switch | Skip the confirmation prompt (also skips the options file creation prompt when the default options file is missing) |

## Common Command Line Usage

### 1) Run using settings from options.json

```powershell
.\videncode.ps1
```

### 2) Specify source, destination, and preset

```powershell
.\videncode.ps1 -SourceDir "C:/path/to/source" -DestDir "C:/path/to/dest" -PresetName "My Preset"
```

### 3) Encode a specific set of files only

```powershell
.\videncode.ps1 -InputFiles "movie1.avi","movie2.avi"
```

### 4) Use a custom preset file

```powershell
.\videncode.ps1 -PresetImportFile "C:/presets/custom.json" -PresetName "My Custom Preset"
```

### 5) Encode files from a list file

```powershell
.\videncode.ps1 -SourceDir "C:/path/to/source" -DestDir "C:/path/to/dest" -InputFilesListFile "C:/path/to/inputs.txt" -NoConfirm
```

### 6) Preview without encoding

```powershell
.\videncode.ps1 -DryRun
```

### 7) Run unattended

```powershell
.\videncode.ps1 -NoConfirm
```

### 8) Full example

```powershell
.\videncode.ps1 `
  -SourceDir "C:/path/to/source" `
  -DestDir "C:/path/to/dest" `
  -PresetName "My Custom Preset" `
  -PresetImportFile "C:/presets/custom.json" `
  -SourceExtensions .avi,.mp4 `
  -OutputExtension .mp4 `
  -NoConfirm
```

## Safety

- Files already matched in `DestDir` (by basename) are always skipped — no re-encoding.
- Files already held in `.videncode-ready` are skipped from encoding — they will be flushed on the next run.
- Outputs go to a temporary subfolder (`.videncode-temp`) first; only moved on success.
- Failed encodes leave the source file untouched; the temporary output is discarded.
- When `DestDir` is full, encoded outputs are held in `.videncode-ready` rather than discarded. The run continues and exits `partial` rather than `failed`.
- Use `-DryRun` to review the planned work before committing.
- Without `-NoConfirm`, a summary is shown and you must confirm before encoding starts.

## Options File Example

`options.json.example`:

```json
{
  "SourceDir": "C:/path/to/handbrake-input",
  "DestDir": "C:/path/to/final-destination",
  "PresetName": "My Custom Preset",
  "PresetImportFile": "C:/path/to/custom-presets.json",
  "HandBrakeCliPath": "HandBrakeCLI",
  "OutputExtension": ".mp4",
  "SourceExtensions": [".avi", ".mp4", ".mkv"]
}
```

## Notes

- Preset names are case-sensitive (HandBrakeCLI requirement).
- Extension and basename matching are case-insensitive.
- If two source files would produce the same output filename, the second one is skipped with a warning.
- `PresetImportFile` is optional. If not set, the preset must be one of HandBrake's built-in presets.
- `-InputFilesListFile` expects one path per line and is ideal when passing many files from another tool.
