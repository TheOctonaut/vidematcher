import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from app.config import settings


def _config_root() -> Path:
    root = Path(settings.webui_config_dir)
    root.mkdir(parents=True, exist_ok=True)
    return root


def _tool_config_file(tool_key: str) -> Path:
    return _config_root() / f"{tool_key}.json"


def _allowed_keys_for_tool(tool: dict[str, Any]) -> set[str]:
    keys: set[str] = set()
    for entry in tool.get("string_params", []):
        keys.add(entry["config_key"])
    for entry in tool.get("array_params", []):
        keys.add(entry["config_key"])
    return keys


def _shared_defaults_path() -> Path:
    return Path(settings.shared_defaults_file)


def _normalize_loaded_config(tool: dict[str, Any], raw: dict[str, Any]) -> dict[str, Any]:
    allowed = _allowed_keys_for_tool(tool)
    normalized: dict[str, Any] = {}
    for key, value in raw.items():
        if key not in allowed:
            continue
        normalized[key] = value
    return normalized


def _builtin_defaults(tool_key: str) -> dict[str, Any]:
    if tool_key in {"videncode", "vidrecompress"}:
        return {"HandBrakeCliPath": "HandBrakeCLI", "OutputExtension": ".mp4"}
    return {}


def ensure_webui_config(tool: dict[str, Any]) -> dict[str, Any]:
    cfg_path = _tool_config_file(tool["key"])
    defaults = _builtin_defaults(tool["key"])
    defaults.update({k: v for k, v in tool.get("defaults", {}).items() if k not in defaults})

    if cfg_path.exists():
        data = json.loads(cfg_path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError(f"Invalid config file for {tool['key']}: expected JSON object.")
        loaded = _normalize_loaded_config(tool, data)
        for key, value in defaults.items():
            if key not in loaded:
                loaded[key] = value
        return loaded

    imported: dict[str, Any] = dict(defaults)
    shared_defaults: dict[str, Any] = {}
    defaults_path = _shared_defaults_path()
    if defaults_path.exists():
        defaults = json.loads(defaults_path.read_text(encoding="utf-8"))
        if isinstance(defaults, dict):
            shared_defaults = defaults
    options_file = str(tool.get("options_file", "")).strip()
    if options_file:
        options_path = Path(options_file)
        if options_path.exists():
            src = json.loads(options_path.read_text(encoding="utf-8"))
            if isinstance(src, dict):
                imported = _normalize_loaded_config(tool, src)
    for key in _allowed_keys_for_tool(tool):
        if key not in imported:
            if key in shared_defaults:
                imported[key] = shared_defaults[key]
            else:
                imported[key] = None

    cfg_path.write_text(json.dumps(imported, indent=2), encoding="utf-8")
    return imported


def save_webui_config(tool: dict[str, Any], updated_values: dict[str, Any]) -> Path:
    allowed = _allowed_keys_for_tool(tool)
    sanitized: dict[str, Any] = {}

    for key, value in updated_values.items():
        if key not in allowed:
            raise ValueError(f"Unsupported config key '{key}' for tool '{tool['key']}'.")
        sanitized[key] = value

    cfg_path = _tool_config_file(tool["key"])
    if cfg_path.exists():
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        backup = cfg_path.with_suffix(f".json.bak.{stamp}")
        backup.write_text(cfg_path.read_text(encoding="utf-8"), encoding="utf-8")

    cfg_path.write_text(json.dumps(sanitized, indent=2), encoding="utf-8")
    return cfg_path


def import_from_options_file(tool: dict[str, Any]) -> dict[str, Any]:
    options_file = str(tool.get("options_file", "")).strip()
    if not options_file:
        raise ValueError(f"No options file configured for tool '{tool['key']}'.")

    options_path = Path(options_file)
    if not options_path.exists():
        raise ValueError(f"Options file not found for tool '{tool['key']}': {options_file}")

    src = json.loads(options_path.read_text(encoding="utf-8"))
    if not isinstance(src, dict):
        raise ValueError(f"Invalid options JSON for tool '{tool['key']}': expected object.")

    normalized = _normalize_loaded_config(tool, src)
    save_webui_config(tool, normalized)
    return normalized
