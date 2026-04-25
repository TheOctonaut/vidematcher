# vidpicker

Find video files in a source folder (and subfolders), move them to a destination folder, then delete source subfolders that contained matches (including their remaining contents).

Example:

- Scans `C:/path/to/source` recursively for `.avi` and `.mp4` files
- Moves each found file to `C:/path/to/dest/`
- Deletes the folder the file came from (including any leftover files in that folder)
- Removes any ancestor folders that are now empty (stopping at the source root)

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+

## Files

- `vidpicker.ps1`: main script
- `options.json.example`: committed template file
- `options.json`: local runtime config file (created on demand, gitignored)

## Configuration Priority

Settings are resolved in this order:

1. Command-line arguments
2. Options file (`options.json` by default, or `-OptionsFile`)
3. Hardcoded defaults in the script

If the selected options file does not exist, the script prompts to create it.
When available, it copies from `options.json.example`.

## Defaults

- Extensions: `[".avi", ".mp4"]`

Required:

- SourceDir: must be set via `-SourceDir` or in `options.json`
- DestDir: must be set via `-DestDir` or in `options.json`

## Common Command Line Usage

### 1) Run using paths from options.json

```powershell
.\vidpicker.ps1
```

### 2) Specify source and destination folders

```powershell
.\vidpicker.ps1 -SourceDir "C:/path/to/source" -DestDir "C:/path/to/dest"
```

### 3) Preview without making any changes (dry run)

```powershell
.\vidpicker.ps1 -DryRun
```

### 4) Skip the confirmation prompt

```powershell
.\vidpicker.ps1 -NoConfirm
```

### 5) Override the file extensions to look for

```powershell
.\vidpicker.ps1 -Extensions .avi,.mp4,.mkv
```

### 6) Use a custom options file path

```powershell
.\vidpicker.ps1 -OptionsFile ".\my-options.json"
```

### 7) Full example

```powershell
.\vidpicker.ps1 `
  -SourceDir "C:/path/to/source" `
  -DestDir "C:/path/to/dest" `
  -Extensions .avi,.mp4 `
  -NoConfirm
```

## Safety

Without `-NoConfirm`, the script always shows a summary of what it will do and prompts `Proceed? (Y/N)` before moving or deleting anything.

Use `-DryRun` to see the full plan without executing it.

## Folder Cleanup Behaviour

For every source subfolder that contained at least one matched file:

1. The matched files are moved to `DestDir`.
2. The entire source subfolder is deleted — including any remaining files in it.
3. Empty ancestor folders between that subfolder and the source root are also removed.

The source root itself (`SourceDir`) is never deleted.

## Name Conflict Handling

If a file with the same name already exists in `DestDir`, the source file is skipped and reported. No overwriting occurs.

## Optional UI

This project includes a small Windows UI with:

- Source folder input
- Destination folder input
- Dry Run checkbox (preview without changes)
- Run button
- On-screen output panel

Run it with:

```powershell
.\vidpicker-ui.ps1
```

Or launch from Windows Explorer/shortcut with:

```text
launch-vidpicker-ui.bat
```

For a no-console launch, first generate a Windows shortcut by running once:

```powershell
.\create-shortcut.ps1
```

This creates `vidpicker.lnk` in the project folder. Double-click it to launch the UI with no console window.

Tips:

- `vidpicker.lnk` is gitignored — each user runs `create-shortcut.ps1` once after cloning.
- VBScript (`.vbs`) is disabled by default on Windows 11 24H2+, which is why no `.vbs` launcher is provided.
- If `options.json` exists, the UI pre-fills source/destination from that file.

## Options File Example

`options.json.example`:

```json
{
  "SourceDir": "C:/path/to/source",
  "DestDir": "C:/path/to/dest",
  "Extensions": [".avi", ".mp4"]
}
```

## Notes

- Extension checks are case-insensitive.
- The destination folder is created automatically if it does not exist.
- Files are moved, not copied.
