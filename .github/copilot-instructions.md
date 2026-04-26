# vidematcher Copilot Instructions

Use these instructions for all future changes in this repository.

## Project Intent

- This repo is a workflow made of multiple PowerShell tools, each in its own subfolder.
- Current tools:
  - `vidmatch/`: compare source vs target by basename (ignore extension).
  - `vidpicker/`: pick/move matching video files and clean source folders.
  - `videncode/`: encode files via HandBrakeCLI with a preset; skip already-processed; move output to destination.
  - `viddispatch/`: run the full pipeline (pick -> match -> encode -> reconcile cleanup) in one command.
- Keep behavior conservative and explicit, especially for destructive operations.

## Folder and File Conventions

For each workflow tool, keep this structure inside its own subfolder:

- Main script: `<tool>.ps1`
- UI script: `<tool>-ui.ps1` (WinForms)
- Explorer launcher: `launch-<tool>-ui.bat`
- Shortcut generator: `create-shortcut.ps1`
- Template config: `options.json.example` (committed)
- Runtime config: `options.json` (gitignored, created at runtime)
- Tool README: `README.md`

Root-level `README.md` is high-level and links to per-tool READMEs.

## Configuration Pattern (Keep Consistent)

- Config precedence must be:
  1. CLI arguments
  2. options file (`options.json` or `-OptionsFile`)
  3. script defaults (only for non-required settings)
- If options file is missing, prompt to create it.
- Prefer copying from `options.json.example` when available.
- `options.json.example` must always use generic placeholder paths, never environment-specific paths.
- Required path settings must not be hardcoded as active defaults in script behavior.

## PowerShell Script Bootstrap Pattern

Always resolve script root safely in this order in script body (not in `param()` defaults):

1. `$PSScriptRoot`
2. `Split-Path -Parent $PSCommandPath`
3. `(Get-Location).Path`

Reason: when scripts are launched as subprocesses, `$PSScriptRoot` can be empty during parameter binding.

## Windows / Compatibility Rules

- Target compatibility: Windows PowerShell 5.1 and PowerShell 7+.
- Do not use PowerShell 7-only syntax in shared scripts (for example, null-conditional `?.`).
- Keep files ASCII where possible; avoid special punctuation characters that can break parsing in PowerShell 5.1 due to encoding issues.

## UI Conventions (WinForms)

- Include STA relaunch guard in UI scripts:
  - If apartment is not STA, relaunch script with `-STA` and exit.
- Run backend script via `System.Diagnostics.Process` with:
  - `UseShellExecute = $false`
  - stdout/stderr redirected
  - `CreateNoWindow = $true`
- Normalize process output newlines before showing in textbox:
  - replace `\r?\n` with `[Environment]::NewLine`
- Validate required user inputs in UI before launching backend script.

## Launcher Conventions

- `launch-<tool>-ui.bat`:
  - prefer `pwsh` if present, fallback to `powershell`
  - run UI with `-NoProfile -ExecutionPolicy Bypass -STA -File`
- `create-shortcut.ps1`:
  - use COM `WScript.Shell.CreateShortcut()` to build `.lnk`
  - target `powershell.exe` with `-WindowStyle Hidden`
- Do not use `.vbs` launchers.
  - VBScript is disabled by default on newer Windows 11 versions (24H2+).

## Destructive Operation Safety

For scripts that move/delete files:

- Support `-DryRun` preview mode.
- Show an action summary before execution.
- Require confirmation unless explicitly bypassed with `-NoConfirm`.
- Handle destination conflicts safely (skip/report, no silent overwrite unless explicitly intended).

## Documentation Rules

- Keep each tool README aligned with current script behavior and parameters.
- Keep root README at high level (tool purpose + workflow + links).
- When behavior changes, update script + README + options template together.

## New Tool Checklist (Generic)

Use this checklist whenever adding any new workflow component. Do not assume sequence or numeric step order.

1. Create a dedicated tool subfolder under the repo root.
2. Add core files for that tool:
  - `<tool>.ps1`
  - `options.json.example`
  - `README.md`
3. Add optional UI and launchers when needed:
  - `<tool>-ui.ps1`
  - `launch-<tool>-ui.bat`
  - `create-shortcut.ps1`
4. Use the same config and safety patterns:
  - options precedence (CLI > options file > defaults)
  - missing options file prompt/create
  - required path values validated explicitly
  - dry run and confirm behavior for destructive actions
5. Ensure PowerShell compatibility and script-root safety pattern are applied.
6. Validate syntax for all `.ps1` files with a parse check before finishing.
7. Update docs in the same change:
  - tool README with accurate examples and options
  - root README with high-level purpose/link if adding a new tool
8. Keep templates generic and keep local runtime values out of committed files.

## Future Dispatcher Integration Guidelines

Design each tool so a future dispatcher can call it consistently without knowing tool internals.

- Keep a stable CLI surface:
  - required inputs as explicit named parameters
  - optional behavior behind switches (`-DryRun`, `-NoConfirm`, etc.)
  - support `-OptionsFile` consistently
- Keep output predictable for orchestration:
  - print a clear start line (what is being scanned/processed)
  - print a clear summary line (counts of moved/skipped/failed/deleted)
  - print warnings/errors in a parseable and human-readable way
- Recommended final stdout summary format:
  - `SUMMARY|tool=<tool>|status=<ok|noop|aborted|failed>|key1=value1|key2=value2`
  - emit exactly one final `SUMMARY|...` line on every successful or handled path
  - keep keys lowercase with underscores, values ASCII-safe, no extra spaces around `=`
- Keep exit codes meaningful:
  - `0` for success (including no-op success)
  - non-zero for failures that should stop/flag orchestration
- Keep side effects explicit and controllable:
  - destructive actions must support dry-run preview
  - confirmation prompts should be bypassable for automation (`-NoConfirm`)
- Keep path handling dispatcher-safe:
  - always resolve script root using the established fallback pattern
  - avoid assumptions about current working directory
  - accept absolute or relative user inputs and validate clearly
- Keep tool boundaries clean:
  - one tool = one primary responsibility
  - avoid embedding cross-tool orchestration logic inside individual tools
  - let the dispatcher compose tool order and branching later
- Keep docs aligned with dispatcher readiness:
  - document parameters, exit behavior, and destructive safety controls
  - include one example suitable for unattended/automated execution

## Dispatcher Lessons From Real Runs

Carry these decisions forward for `viddispatch` and related tools.

- Prefer structured `SUMMARY|...` status over raw process exit code when both are available.
  - For streamed child processes (`Start-Process -PassThru` + redirected stdout/stderr), treat `SUMMARY|status=ok|...` and `SUMMARY|status=noop|...` as success.
  - Use exit code as a fallback when no summary line is present.
  - Reason: some host/process combinations can report misleading non-zero/null exit code even when work succeeded.
- Preserve streaming progress state in reference types when callbacks are scriptblocks.
  - In `OnStdoutLine`/`OnStderrLine` callbacks, use a hashtable/object (`$state`) for mutable counters instead of relying on scalar variables.
  - Reason: scalar assignments in callback scope can produce stale parent values and broken ETA/progress behavior.
- ETA guidance for encode progress:
  - Compute ETA from `PROGRESS|event=update` events (completed file boundaries), not `event=start`.
  - Show `estimating...` until at least one completed file establishes throughput.
  - Suppress ETA when final item is complete instead of printing misleading `0s`.
- Always clear stale progress UI at run start.
  - Call `Write-Progress -Activity "viddispatch pipeline" -Completed` before printing run header.
  - Start initial progress updates after confirmation prompts to avoid overlaying/garbling prompt output.
- Keep console mode operator-friendly by default.
  - Default to compact status output with a clean scorecard.
  - Keep full child stdout/stderr behind `-VerboseConsole`.
- Keep debug logging non-fatal.
  - If log file write fails (file lock/permission race), switch to a fallback log path and continue pipeline execution.
  - Never fail file operations solely because debug logging failed.
- For multi-file transport between dispatcher and tools, prefer list-file handoff.
  - Use a temp text file (`-InputFilesListFile`) for candidate paths.
  - Avoid large inline argument lists for file paths with spaces/special characters.
- Reconcile cleanup is a required post-encode safety net.
  - Do not skip reconcile after successful encode.
  - Ensure failure gating does not falsely abort before cleanup.
- Progress protocol expectations for encode tools:
  - Emit parseable `PROGRESS|tool=<tool>|event=<start|update|complete>|...` lines.
  - Keep key names stable (`index`, `total`, `file`, `elapsed_seconds`, `encoded`, `encode_failed`, `moved`, `move_failed`).
  - Keep values ASCII-safe and delimiter-safe (sanitize `|` in values).
- Validation discipline after any script changes:
  - Parse-check every touched `.ps1` file before finishing.
  - Prefer a small real-world smoke run when changes affect orchestration or progress rendering.

## Observed Operator Preferences

These are behavior/design preferences inferred from collaboration in this repo. Favor these defaults unless the user asks otherwise.

- Prefer practical signal over theoretical correctness.
  - Validate with realistic end-to-end runs and real logs, not only unit-level or synthetic checks.
  - When real run results disagree with expected behavior, trust observed outputs first and debug from evidence.
- Prioritize clear operator trust signals.
  - If a run fails, always show a concrete reason in plain language.
  - Keep the scorecard aligned with actual outcomes (avoid contradictory states like `failed` with zero failures).
  - Surface key counters in failure messages when possible.
- Favor concise, readable console UX.
  - Keep routine output compact and scannable.
  - Avoid visual artifacts (stale progress bars, overlayed output, noisy child logs in default mode).
  - Preserve a stable layout where final scorecard and summary are easy to find.
- Treat ETA as guidance, not filler.
  - Show ETA only when statistically meaningful.
  - Prefer `estimating...` or omitted ETA over misleading values.
- Keep automation resilient to non-critical faults.
  - Non-essential concerns (for example debug log lock conflicts) must degrade gracefully, not abort successful work.
- Protect destructive workflows with explicitness.
  - Retain dry-run previews, confirmation gates, and explicit summaries for move/delete operations.
  - Ensure cleanup/reconcile stages are not skipped by false negatives in earlier step checks.
- Maintain parity across PS5/PS7 implementations.
  - When changing shared orchestration behavior, update both script variants unless intentionally diverging.
  - Avoid features that silently work in one host but degrade in the other.
- Prefer root-cause fixes over cosmetic workarounds.
  - Solve the underlying decision logic (for example success/failure gating) rather than suppressing visible symptoms.
- Preserve continuity in long sessions.
  - After significant debugging rounds, encode decisions and pitfalls into repo instructions so future work starts with established context.

## Repository Hygiene

- `.gitignore` should include `options.json`, `*.csv`, and `*.lnk` patterns as needed.
- Never commit environment-specific `options.json`.
- Preserve user/local data while editing templates and docs.
