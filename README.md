# vidematcher

A set of PowerShell tools for managing a video file workflow on Windows.

## Tools

### [vidmatch](vidmatch/)

Compares two folders by filename (ignoring extension) and reports source files that have no match in the target.

Use this to find videos in a source folder that have not yet been processed into the target folder.

- Supports recursive scanning, per-side extension filtering, and optional CSV export
- Includes a WinForms UI (`vidmatch-ui.ps1`)

→ See [vidmatch/README.md](vidmatch/README.md)

---

### [vidpicker](vidpicker/)

Finds video files in a source folder (and subfolders), moves them to a destination folder, then cleans up the source subfolders.

Use this to harvest finished files out of a staging area and into a processing queue.

- Dry run mode for safe previewing
- Confirmation prompt before any destructive action
- Includes a WinForms UI (`vidpicker-ui.ps1`)

→ See [vidpicker/README.md](vidpicker/README.md)

---

### [videncode](videncode/)

Encodes video files using HandBrakeCLI with a named preset, skips files already present in the destination (by basename), and moves outputs to the destination on success.

Use this to batch-encode a staging folder without re-processing already-completed files.

- Custom preset support (built-in or imported from a JSON preset file)
- Accepts an explicit file list or scans a folder automatically
- Dry run mode; outputs staged to a temp folder before final move

→ See [videncode/README.md](videncode/README.md)

---

### [viddispatch](viddispatch/)

Runs the full pipeline in one command: picks files from staging, checks which ones haven't been encoded yet, and encodes them.

- Propagates `-DryRun` and `-NoConfirm` to all tools
- `-SkipPick` to skip straight to match+encode if files are already in the handbrake folder
- Stops immediately if any step fails

→ See [viddispatch/README.md](viddispatch/README.md)

---

## Workflow

```text
[Source staging area]
        |
    vidpicker        (move .avi/.mp4 files to handbrake folder, clean up source)
        |
[Handbrake folder] <----+
        |               |
    vidmatch            |  (compare handbrake folder against final folder;
        |               |   list files not yet encoded)
[Unmatched list] -------+
        |
    videncode        (encode unmatched files via HandBrakeCLI, move output to final folder)
        |
[Final folder]
```

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+

## Configuration

Each tool has its own `options.json` in its subfolder (gitignored).
Copy `options.json.example` to `options.json` and set your paths, or let the script prompt you to create it on first run.

## Launchers

Each tool ships with:

| File | Purpose |
| --- | --- |
| `launch-<tool>-ui.bat` | Double-click in Explorer to open the UI (brief console window) |
| `create-shortcut.ps1` | Run once to create a `.lnk` that opens the UI with no console window |

> **Note:** VBScript (`.vbs`) launchers are not provided — VBScript is disabled by default on Windows 11 24H2+.
