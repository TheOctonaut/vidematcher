# vidmatch

Compare files in a source folder against a target folder by filename (basename) while ignoring extension.

Example match logic:

- `myMovie.avi` in source matches `myMovie.mp4` in target
- `a.avi` matches `a.avi`
- `a.mp4` matches `a.avi`

The script reports source files that do not have a matching basename in the target.

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+

## Files

- `vidmatch.ps1`: main script
- `options.json.example`: committed template file
- `options.json`: local runtime config file (created on demand, gitignored)

## Configuration Priority

Settings are resolved in this order:

1. Command-line arguments
2. Options file (`options.json` by default, or `-OptionsFile`)
3. Hardcoded defaults in the script (for non-path settings only)

If the selected options file does not exist, the script prompts to create it.
When available, it copies from `options.json.example`.

## Defaults

- Recurse: `true`
- ShowRelativePaths: `false`
- CsvOutputPath: `null` (no CSV output)
- SourceExtensions: `[".avi", ".mp4"]`
- TargetExtensions: `[".avi", ".mp4"]`

Required:

- SourceDir: must be set via `-SourceDir` or in `options.json`
- TargetDir: must be set via `-TargetDir` or in `options.json`

## Common Command Line Usage

### 1) Run using paths from options.json

```powershell
.\vidmatch.ps1
```

### 2) Specify source and target folders

```powershell
.\vidmatch.ps1 -SourceDir "C:/path/to/source" -TargetDir "C:/path/to/target"
```

### 3) Non-recursive scan (top folder only)

```powershell
.\vidmatch.ps1 -NoRecurse
```

### 4) Show relative paths in output

```powershell
.\vidmatch.ps1 -ShowRelativePaths
```

### 5) Export unmatched list to CSV (optional)

```powershell
.\vidmatch.ps1 -CsvOutputPath ".\unmatched.csv"
```

### 6) Override valid filetypes for source and target independently

```powershell
.\vidmatch.ps1 -SourceExtensions .avi,.mkv -TargetExtensions .mp4,.m4v
```

### 7) Use a custom options file path

```powershell
.\vidmatch.ps1 -OptionsFile ".\my-options.json"
```

### 8) Full example combining common options

```powershell
.\vidmatch.ps1 `
  -SourceDir "C:/path/to/source" `
  -TargetDir "C:/path/to/target" `
  -ShowRelativePaths `
  -CsvOutputPath ".\reports\unmatched.csv" `
  -SourceExtensions .avi,.mp4 `
  -TargetExtensions .avi,.mp4
```

## Optional UI

This project includes a small Windows UI script with:

- Source folder input
- Target folder input
- Optional CSV output input
- Compare button
- On-screen output panel

Run it with:

```powershell
.\vidmatch-ui.ps1
```

Or launch from Windows Explorer/shortcut with:

```text
launch-vidmatch-ui.bat
```

For a no-console launch, first generate a Windows shortcut by running once:

```powershell
.\create-shortcut.ps1
```

This creates `vidmatch.lnk` in the project folder. Double-click it to launch the UI with no console window.

Tip:

- `vidmatch.lnk` is gitignored — each user runs `create-shortcut.ps1` once after cloning.
- VBScript (`.vbs`) is disabled by default on Windows 11 24H2+, which is why no `.vbs` launcher is provided.

Notes:

- The UI launches `vidmatch.ps1` in the background.
- If `options.json` exists, the UI pre-fills source/target/csv from that file.

## Options File Example

`options.json.example`:

```json
{
  "SourceDir": "C:/path/to/source",
  "TargetDir": "C:/path/to/target",
  "Recurse": true,
  "ShowRelativePaths": false,
  "CsvOutputPath": null,
  "SourceExtensions": [".avi", ".mp4"],
  "TargetExtensions": [".avi", ".mp4"]
}
```

## Notes

- Extension checks are case-insensitive.
- Basename matching is case-insensitive.
- CSV is only written when `CsvOutputPath` is provided by argument or options file.
