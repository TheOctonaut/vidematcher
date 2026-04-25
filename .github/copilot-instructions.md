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

## Repository Hygiene

- `.gitignore` should include `options.json`, `*.csv`, and `*.lnk` patterns as needed.
- Never commit environment-specific `options.json`.
- Preserve user/local data while editing templates and docs.
