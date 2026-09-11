# vidui

A single WinForms UI for driving the standalone (non-`viddispatch`) tools:
**Transcribe** (`vidtranscribe`) and **Tag** (`vidtag`). Each tool gets its own
tab for its inputs, but the run button, progress bar, status line, and output
log are shared — both tools speak the same `PROGRESS|...`/`SUMMARY|...`
protocol, so one engine can drive either of them.

This UI is a thin front-end: it shells out to the real `vidtranscribe.ps1` /
`vidtag.ps1` scripts exactly as you would from the command line, and reads
each tool's own `options.json` for its field defaults. It does not read or
write options.json itself — edit each tool's `options.json` directly for
settings not exposed here (API keys, `ModelsPath`, `DockerImage`, etc.).

---

## Setup

1. Make sure `vidtranscribe/options.json` and `vidtag/options.json` already
   exist and are configured (copy from each tool's `options.json.example` if
   needed).
2. Run `launch-vidui.bat`, or generate a desktop-friendly shortcut once with:
   ```powershell
   .\create-shortcut.ps1
   ```
   then double-click the generated `vidui.lnk`.

## Usage

- **Transcribe tab**: pick a file or folder `Path`, optionally override
  `Language`, `Model`, `ComputeType`, `Device`, `MaxFiles`, toggle
  "Disable auto-translate" or "Dry Run", then click **Run**.
- **Tag tab**: pick a `Scan Path`, set `MaxFiles`, toggle any of
  Allow new tags / Generate plot description / Use visuals / Force refresh
  vocabulary / Refresh Jellyfin library / Dry Run, then click **Run**.
- The shared progress bar, status label, and output log below the tabs
  update live while the selected tool runs (parsed from its `PROGRESS|...`
  and `SUMMARY|...` lines). **Cancel** kills the running process (and its
  child processes, e.g. `ffmpeg`) via `taskkill /T /F`.
- Both tools are always launched with `-NoConfirm` since there's no console
  to answer the interactive Y/N prompt.

## Notes

- Only one run (either tab) can be active at a time; the tabs are disabled
  while a run is in progress.
- This tool intentionally does not expose every CLI parameter (e.g. Jellyfin
  URL/API key, LLM base URL/key/model, `ModelsPath`, `DockerImage`) — those
  are read from each tool's `options.json` as usual. Add more fields here if
  you find yourself needing to override them per-run often.
