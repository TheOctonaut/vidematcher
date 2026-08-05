import json
from pathlib import Path
from typing import Any, Optional


REGISTRY_FILE = Path(__file__).with_name("tools.json")


def _normalize_registry(raw: dict[str, Any]) -> list[dict[str, Any]]:
    if "tools" not in raw or not isinstance(raw["tools"], list):
        raise ValueError("Invalid tools.json: missing tools list.")

    normalized: list[dict[str, Any]] = []
    keys: set[str] = set()
    for item in raw["tools"]:
        if not isinstance(item, dict):
            raise ValueError("Invalid tools.json: tool entry must be an object.")

        key = str(item.get("key", "")).strip()
        name = str(item.get("name", "")).strip()
        script_path = str(item.get("script_path", "")).strip()
        options_file = str(item.get("options_file", "")).strip()
        destructive = bool(item.get("destructive", False))
        switches = item.get("switches", [])
        string_params = item.get("string_params", [])
        array_params = item.get("array_params", [])
        defaults = item.get("defaults", {})
        summary = str(item.get("summary", "")).strip()

        if not key or not name or not script_path:
            raise ValueError("Invalid tools.json: tool requires key, name, and script_path.")
        if key in keys:
            raise ValueError(f"Invalid tools.json: duplicate key '{key}'.")
        if not isinstance(switches, list) or not isinstance(string_params, list) or not isinstance(array_params, list) or not isinstance(defaults, dict):
            raise ValueError("Invalid tools.json: switches, string_params, and array_params must be lists.")

        normalized_string_params: list[dict[str, str]] = []
        for param in string_params:
            if not isinstance(param, dict):
                raise ValueError("Invalid tools.json: string_params entry must be an object.")
            arg = str(param.get("arg", "")).strip()
            config_key = str(param.get("config_key", "")).strip()
            if not arg or not config_key:
                raise ValueError("Invalid tools.json: string_params entry requires arg and config_key.")
            normalized_string_params.append({"arg": arg, "config_key": config_key})

        normalized_array_params: list[dict[str, str]] = []
        for param in array_params:
            if not isinstance(param, dict):
                raise ValueError("Invalid tools.json: array_params entry must be an object.")
            arg = str(param.get("arg", "")).strip()
            config_key = str(param.get("config_key", "")).strip()
            if not arg or not config_key:
                raise ValueError("Invalid tools.json: array_params entry requires arg and config_key.")
            normalized_array_params.append({"arg": arg, "config_key": config_key})

        keys.add(key)
        normalized.append(
            {
                "key": key,
                "name": name,
                "script_path": script_path,
                "options_file": options_file,
                "destructive": destructive,
                "switches": [str(v).strip() for v in switches if str(v).strip()],
                "string_params": normalized_string_params,
                "array_params": normalized_array_params,
                "defaults": {str(k).strip(): v for k, v in defaults.items() if str(k).strip()},
                "summary": summary,
            }
        )

    return normalized


def load_tools() -> list[dict[str, Any]]:
    raw = json.loads(REGISTRY_FILE.read_text(encoding="utf-8"))
    return _normalize_registry(raw)


def get_tool_by_key(key: str) -> Optional[dict[str, Any]]:
    for tool in load_tools():
        if tool["key"] == key:
            return tool
    return None
