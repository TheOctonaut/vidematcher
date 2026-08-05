from datetime import datetime, timezone
import subprocess
from typing import Any

from app.config import settings
from app.history import record_run
from app.tool_registry import get_tool_by_key
from app.webui_configs import ensure_webui_config


def _append_if_set(args: list[str], name: str, value: Any) -> None:
    if value is None:
        return
    text = str(value).strip()
    if not text:
        return
    args.append(name)
    args.append(text)


def _append_array_if_set(args: list[str], name: str, value: Any) -> None:
    if value is None:
        return

    if isinstance(value, list):
        values = value
    else:
        values = [value]

    cleaned = [str(v).strip() for v in values if str(v).strip()]
    if not cleaned:
        return

    args.append(name)
    args.extend(cleaned)


def run_tool_job(
    tool_key: str,
    dry_run: bool,
    no_confirm: bool,
    skip_pick: bool = False,
) -> dict:
    tool = get_tool_by_key(tool_key)
    if tool is None:
        raise ValueError(f"Unknown tool key '{tool_key}'.")
    if tool.get("destructive", False) and not dry_run and not settings.allow_destructive:
        raise ValueError("Destructive runs are disabled. Set ALLOW_DESTRUCTIVE=true to enable.")

    command = [
        settings.powershell_exe,
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        tool["script_path"],
    ]
    webui_config = ensure_webui_config(tool)

    for entry in tool.get("string_params", []):
        _append_if_set(command, entry["arg"], webui_config.get(entry["config_key"]))
    for entry in tool.get("array_params", []):
        _append_array_if_set(command, entry["arg"], webui_config.get(entry["config_key"]))

    supported_switches = set(tool.get("switches", []))
    if dry_run and "-DryRun" in supported_switches:
        command.append("-DryRun")
    if no_confirm and "-NoConfirm" in supported_switches:
        command.append("-NoConfirm")
    if skip_pick and "-SkipPick" in supported_switches:
        command.append("-SkipPick")

    started_at = datetime.now(timezone.utc).isoformat()
    completed = subprocess.run(
        command,
        capture_output=True,
        text=True,
        timeout=settings.run_timeout_seconds,
    )
    finished_at = datetime.now(timezone.utc).isoformat()

    summary_line = None
    stdout_lines = completed.stdout.splitlines()
    for line in reversed(stdout_lines):
        if line.startswith("SUMMARY|"):
            summary_line = line
            break

    return {
        "started_at": started_at,
        "finished_at": finished_at,
        "tool_key": tool["key"],
        "command": command,
        "return_code": completed.returncode,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
        "summary_line": summary_line,
    }


def run_and_record_tool_job(tool_key: str, dry_run: bool, no_confirm: bool, skip_pick: bool = False) -> dict:
    result = run_tool_job(tool_key=tool_key, dry_run=dry_run, no_confirm=no_confirm, skip_pick=skip_pick)
    record_run(result)
    return result
