from pathlib import Path
from typing import Any

from app.config import settings
from app.tool_registry import get_tool_by_key, load_tools
from app.webui_configs import ensure_webui_config


def _path_status(path_value: str | None) -> dict[str, Any]:
    if not path_value:
        return {"ok": False, "state": "blocked", "reason": "missing"}

    path = Path(path_value)
    if path.exists():
        return {"ok": True, "state": "ready", "reason": "exists"}
    return {"ok": False, "state": "blocked", "reason": f"missing: {path_value}"}


def _container_path_from_host(path_value: str | None) -> str | None:
    if not path_value:
        return None
    normalized = str(path_value).replace("\\", "/")
    for mapping in sorted(settings.path_mount_map, key=lambda item: len(item.get("host_norm", item["host"])), reverse=True):
        host_root = mapping.get("host_norm", mapping["host"]).replace("\\", "/").rstrip("/")
        container_root = mapping["container"].rstrip("/")
        if normalized == host_root or normalized.startswith(host_root + "/"):
            return normalized.replace(host_root, container_root, 1)
    return None


def _command_exists(command: str) -> bool:
    if not command:
        return False
    if Path(command).exists():
        return True
    return False


def _is_path_like(value: str) -> bool:
    text = value.replace("\\", "/")
    return "/" in text or ":" in text


def validate_tool(tool_key: str) -> dict[str, Any]:
    tool = get_tool_by_key(tool_key)
    if tool is None:
        return {
            "tool_key": tool_key,
            "state": "blocked",
            "checks": [],
            "reasons": [f"Unknown tool '{tool_key}'."],
        }

    reasons: list[str] = []
    checks: list[dict[str, Any]] = []

    script_check = _path_status(tool.get("script_path"))
    checks.append({"name": "script_path", **script_check})
    if not script_check["ok"]:
        reasons.append(f"Script missing: {tool.get('script_path')}")
    else:
        checks.append({
            "name": "script_container_path",
            "ok": True,
            "state": "ready",
            "reason": _container_path_from_host(tool.get("script_path")) or "not mapped",
        })

    try:
        config = ensure_webui_config(tool)
    except Exception as ex:
        config = {}
        reasons.append(f"Config error: {ex}")
        checks.append({"name": "webui_config", "ok": False, "state": "blocked", "reason": str(ex)})
    else:
        checks.append({"name": "webui_config", "ok": True, "state": "ready", "reason": "loaded"})

    for entry in tool.get("string_params", []):
        key = entry["config_key"]
        value = config.get(key)
        if value is None or str(value).strip() == "":
            checks.append({"name": key, "ok": False, "state": "blocked", "reason": "missing"})
            reasons.append(f"Missing required config: {key}")
            continue

        if key == "HandBrakeCliPath":
            if _command_exists(str(value)) or str(value).strip() == "HandBrakeCLI":
                checks.append({"name": key, "ok": True, "state": "ready", "reason": "command"})
            else:
                checks.append({"name": key, "ok": False, "state": "warning", "reason": f"not found: {value}"})
                reasons.append(f"HandBrakeCLI not found: {value}")
        elif key == "CsvOutputPath":
            parent = Path(str(value)).parent
            if str(parent):
                checks.append({"name": key, "ok": True, "state": "ready", "reason": f"writable target ({parent})"})
            else:
                checks.append({"name": key, "ok": False, "state": "blocked", "reason": f"invalid output path: {value}"})
                reasons.append(f"{key} is invalid: {value}")
        elif key.lower().endswith("dir") or key.lower().endswith("path"):
            container_path = _container_path_from_host(str(value))
            if container_path:
                path_check = _path_status(container_path)
                if path_check["ok"] or key.lower().endswith("tempdir"):
                    checks.append({"name": key, "ok": True, "state": "ready", "reason": f"{path_check['reason']} ({container_path})"})
                else:
                    checks.append({"name": key, **path_check, "reason": f"{path_check['reason']} ({container_path})"})
                    reasons.append(f"{key} is missing in container: {container_path}")
            else:
                checks.append({"name": key, "ok": False, "state": "blocked", "reason": f"not mapped: {value}"})
                reasons.append(f"{key} is not mapped for container use: {value}")
        else:
            checks.append({"name": key, "ok": True, "state": "ready", "reason": "set"})

    if tool.get("key") in {"videncode", "vidrecompress", "viddispatch"}:
        hb = config.get("HandBrakeCliPath")
        if hb and _is_path_like(str(hb)) and not _command_exists(str(hb)):
            checks.append({"name": "HandBrakeCliPath", "ok": False, "state": "warning", "reason": f"not found: {hb}"})
            reasons.append(f"HandBrakeCLI not found: {hb}")

    if tool.get("key") == "viddispatch":
        child_keys = ["vidpicker", "vidmatch", "videncode"]
        for child_key in child_keys:
            child = get_tool_by_key(child_key)
            if child is None:
                reasons.append(f"Missing child tool: {child_key}")
                checks.append({"name": child_key, "ok": False, "state": "blocked", "reason": "missing child tool"})
                continue
            child_script = _path_status(child.get("script_path"))
            checks.append({"name": f"{child_key}.script_path", **child_script})
            if not child_script["ok"]:
                reasons.append(f"{child_key} script missing")

    state = "ready"
    if reasons:
        state = "warning"
    if any(check.get("state") == "blocked" for check in checks):
        state = "blocked"

    return {
        "tool_key": tool["key"],
        "tool_name": tool["name"],
        "state": state,
        "checks": checks,
        "reasons": reasons,
        "config": config,
    }


def validate_all_tools() -> list[dict[str, Any]]:
    return [validate_tool(tool["key"]) for tool in load_tools()]
