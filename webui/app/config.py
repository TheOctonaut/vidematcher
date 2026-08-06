import os
import json


def _as_bool(value: str, default: bool) -> bool:
    if value is None:
        return default
    normalized = value.strip().lower()
    return normalized in {"1", "true", "yes", "on"}


class Settings:
    def __init__(self) -> None:
        self.redis_url = os.getenv("REDIS_URL", "redis://redis:6379/0")
        self.default_tool_key = os.getenv("DEFAULT_TOOL_KEY", "viddispatch")
        self.webui_config_dir = os.getenv("WEBUI_CONFIG_DIR", "/workspace/webui/runtime-configs")
        self.host_scripts_root = os.getenv("HOST_SCRIPTS_ROOT", "M:/Server/LocalDev/VSCode/Scripts/vidematcher")
        self.container_scripts_root = os.getenv("CONTAINER_SCRIPTS_ROOT", "/scripts")
        self.path_mount_map = self._load_mount_map(os.getenv("PATH_MOUNT_MAP", "[]"))
        self.shared_defaults_file = os.getenv("WEBUI_SHARED_DEFAULTS_FILE", "/scripts/webui-defaults.json")
        self.powershell_exe = os.getenv("POWERSHELL_EXE", "pwsh")
        self.allow_destructive = _as_bool(os.getenv("ALLOW_DESTRUCTIVE"), False)
        self.run_timeout_seconds = int(os.getenv("RUN_TIMEOUT_SECONDS", "21600"))

    def _load_mount_map(self, raw: str):
        try:
            data = json.loads(raw)
        except Exception:
            return []
        if not isinstance(data, list):
            return []
        items = []
        for entry in data:
            if isinstance(entry, dict):
                host = str(entry.get("host", "")).strip()
                container = str(entry.get("container", "")).strip()
                if host and container:
                    normalized_host = host.replace("\\", "/").rstrip("/")
                    items.append({"host": host, "host_norm": normalized_host, "container": container})
        return items


settings = Settings()
