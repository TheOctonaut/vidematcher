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

## Workflow

```
[Source staging area]
        |
    vidpicker        (move .avi/.mp4 files → handbrake folder, clean up source)
        |
[Handbrake folder]
        |
    vidmatch         (check processed files exist in target / archive)
        |
[Target / archive]
```

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+

## Configuration

Each tool has its own `options.json` in its subfolder (gitignored).
Copy `options.json.example` to `options.json` and set your paths, or let the script prompt you to create it on first run.

## Launchers

Each tool ships with:

| File | Purpose |
|---|---|
| `launch-<tool>-ui.bat` | Double-click in Explorer to open the UI (brief console window) |
| `create-shortcut.ps1` | Run once to create a `.lnk` that opens the UI with no console window |

> **Note:** VBScript (`.vbs`) launchers are not provided — VBScript is disabled by default on Windows 11 24H2+.
