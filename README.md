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

### [vidrecompress](vidrecompress/)

Re-encodes existing `.avi` files in-place using HandBrakeCLI, replacing each source file with the encoded `.mp4` only if the result is smaller. Files that already have a matching `.mp4` are skipped.

Use this to shrink a library of raw recordings without a separate destination folder.

- Dry run mode for safe previewing
- Confirmation prompt before any destructive action
- Cleans up partial temp files on error or interruption

→ See [vidrecompress/README.md](vidrecompress/README.md)

---

### [viddispatch](viddispatch/)

Runs the full pipeline in one command: picks files from staging, checks which ones haven't been encoded yet, and encodes them.

- Propagates `-DryRun` and `-NoConfirm` to all tools
- `-SkipPick` to skip straight to match+encode if files are already in the handbrake folder
- Stops immediately if any step fails

→ See [viddispatch/README.md](viddispatch/README.md)

---

### [vidwebmatch](vidwebmatch/)

Firefox WebExtension + Windows native helper that annotates `.avi` filenames on matching pages by checking a configured local video library root using basename matching (extension ignored).

- Statuses: `missing`, `avi_only`, `mp4_only`, `both`
- Batched native-messaging queries with helper-side index caching
- Includes Windows install/uninstall scripts for native-host registration
- Temporary Firefox add-on loaded from `vidwebmatch/extension/manifest.json`; helper installed with `vidwebmatch/install-helper.ps1`

→ See [vidwebmatch/README.md](vidwebmatch/README.md)

---

### [webui](webui/)

Dockerized browser UI MVP for queuing and monitoring `viddispatch` runs on a single host.

- FastAPI web app + Redis queue + RQ worker
- Dry-run-first control for safe initial browser validation
- Shows run output and final `SUMMARY|...` line

→ See [webui/README.md](webui/README.md)

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
