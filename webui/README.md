# webui

Dockerized browser UI MVP for running video workflow scripts on a single host.

This first version gives you:

- a local web page to queue runs for core tools
- a Redis queue + worker so runs happen in background
- run logs + final `SUMMARY|...` line visible in browser
- a registry of all core scripts at `webui/app/tools.json` (PS7 script variants)
- WebUI-owned per-tool configs in `webui/runtime-configs/`

## What it runs

The worker executes registered scripts:

- `viddispatch/viddispatch.ps7.ps1`
- `vidpicker/vidpicker.ps7.ps1`
- `vidmatch/vidmatch.ps7.ps1`
- `videncode/videncode.ps7.ps1`
- `vidrecompress/vidrecompress.ps7.ps1`

Parameters are passed explicitly from the WebUI config for each tool.

On first use of a tool, WebUI imports values from that tool's existing `options.json`. After that, edits are stored in WebUI-only config files and used for runs.

## Prerequisites

- Docker Desktop
- existing `viddispatch` setup in this repo (including its `options.json`)

## Quick start

From this folder (`webui/`):

```powershell
Copy-Item .env.example .env
docker compose up --build
```

Open:

- http://localhost:6767

## Environment settings

Set these in `webui/.env`:

| Name | Default | Purpose |
| --- | --- | --- |
| `REDIS_URL` | `redis://redis:6379/0` | Queue backend |
| `DEFAULT_TOOL_KEY` | `viddispatch` | Registry tool key used as default run target |
| `WEBUI_CONFIG_DIR` | `/workspace/webui/runtime-configs` | WebUI-owned config storage path |
| `POWERSHELL_EXE` | `pwsh` | PowerShell executable used by worker |
| `ALLOW_DESTRUCTIVE` | `false` | If `false`, only dry runs are allowed |
| `RUN_TIMEOUT_SECONDS` | `21600` | Max run time per job |

## Notes for Windows host paths

Because this container runs on Linux, avoid Windows drive-letter paths inside the options file used by the worker.

Use container-visible paths for media folders (for example mounted folders under `/workspace` or other docker mounts), or keep early validation in `Dry run` mode first.

## Stopping

```powershell
docker compose down
```
