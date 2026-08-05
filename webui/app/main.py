import json
from urllib.parse import quote_plus
from typing import Any, Optional

from fastapi import FastAPI, Form, Query, Request
from fastapi.responses import RedirectResponse
from fastapi.templating import Jinja2Templates
from redis.exceptions import RedisError
from rq.job import Job
from rq.job import NoSuchJobError

from app.config import settings
from app.history import get_run_by_id, list_recent_runs
from app.history import init_history
from app.jobs import run_and_record_tool_job
from app.queueing import queue, redis_conn
from app.tool_registry import get_tool_by_key, load_tools
from app.validation import validate_all_tools, validate_tool
from app.webui_configs import ensure_webui_config, import_from_options_file, save_webui_config

app = FastAPI(title="vidematcher webui")
templates = Jinja2Templates(directory="app/templates")


@app.on_event("startup")
def startup() -> None:
    init_history()


@app.get("/healthz")
def healthz() -> dict:
    redis_ok = False
    try:
        redis_ok = bool(redis_conn.ping())
    except RedisError:
        redis_ok = False

    return {
        "status": "ok" if redis_ok else "degraded",
        "redis": redis_ok,
    }


@app.get("/")
def index(
    request: Request,
    job_id: Optional[str] = Query(default=None),
    tool_key: Optional[str] = Query(default=None),
    config_saved: bool = Query(default=False),
    config_imported: bool = Query(default=False),
    config_error: Optional[str] = Query(default=None),
    validate: bool = Query(default=True),
) -> object:
    job_data = None
    job_status = None
    error = None

    if job_id:
        try:
            job = Job.fetch(job_id, connection=redis_conn)
            job_status = job.get_status(refresh=True)
            if job.is_finished:
                job_data = job.result
            elif job.is_failed:
                if job.exc_info:
                    error = job.exc_info
                else:
                    error = "Job failed."
        except NoSuchJobError:
            error = f"Job not found: {job_id}"

    tools = load_tools()
    selected_tool = get_tool_by_key(tool_key or settings.default_tool_key)
    if selected_tool is None and len(tools) > 0:
        selected_tool = tools[0]

    # Load config for every tool so tabs can pre-populate without a round-trip.
    all_configs: dict[str, Any] = {}
    for tool in tools:
        try:
            all_configs[tool["key"]] = ensure_webui_config(tool)
        except ValueError:
            all_configs[tool["key"]] = {}

    selected_config: dict[str, Any] = {}
    if selected_tool is not None:
        selected_config = all_configs.get(selected_tool["key"], {})

    selected_validation = None
    all_validations = []
    if validate:
        if selected_tool is not None:
            selected_validation = validate_tool(selected_tool["key"])
        all_validations = validate_all_tools()

    return templates.TemplateResponse(
        request=request,
        name="index.html",
        context={
            "job_id": job_id,
            "job_status": job_status,
            "job_data": job_data,
            "error": error,
            "tools": tools,
            "all_configs": all_configs,
            "selected_tool": selected_tool,
            "selected_config": selected_config,
            "selected_validation": selected_validation,
            "all_validations": all_validations,
            "config_saved": config_saved,
            "config_imported": config_imported,
            "config_error": config_error,
            "allow_destructive": settings.allow_destructive,
            "recent_runs": list_recent_runs(10),
            "host_scripts_root": settings.host_scripts_root,
            "container_scripts_root": settings.container_scripts_root,
            "path_mount_map": settings.path_mount_map,
        },
    )


@app.get("/validate")
def validate(tool_key: str = Query(default="")) -> object:
    return validate_tool(tool_key)


@app.get("/runs/{run_id}")
def run_detail(run_id: int) -> object:
    run = get_run_by_id(run_id)
    if run is None:
        return RedirectResponse(url="/?config_error=Run+not+found", status_code=303)
    return run


@app.post("/runs")
def create_run(
    tool_key: str = Form(default=""),
    dry_run: bool = Form(default=False),
    no_confirm: bool = Form(default=False),
    skip_pick: bool = Form(default=False),
    destructive_ack: str = Form(default=""),
) -> object:
    selected_tool = get_tool_by_key(tool_key)
    if selected_tool is None:
        return RedirectResponse(url="/?config_error=Unknown+tool+selected", status_code=303)

    if selected_tool.get("destructive", False) and not dry_run and not settings.allow_destructive:
        return RedirectResponse(url=f"/?tool_key={selected_tool['key']}&config_error=Destructive+runs+are+disabled", status_code=303)

    if selected_tool.get("destructive", False) and not dry_run:
        if destructive_ack.strip().lower() != "i understand":
            return RedirectResponse(url=f"/?tool_key={selected_tool['key']}&config_error=Type+%27I+understand%27+to+confirm+destructive+runs", status_code=303)

    job = queue.enqueue(
        run_and_record_tool_job,
        tool_key=selected_tool["key"],
        dry_run=dry_run,
        no_confirm=no_confirm,
        skip_pick=skip_pick,
    )
    return RedirectResponse(url=f"/?job_id={job.id}&tool_key={selected_tool['key']}", status_code=303)


@app.post("/config/save")
async def save_config(request: Request) -> object:
    form_data = await request.form()
    tool_key = str(form_data.get("tool_key", "")).strip()
    selected_tool = get_tool_by_key(tool_key)
    if selected_tool is None:
        return RedirectResponse(url="/?config_error=Unknown+tool+selected", status_code=303)

    try:
        new_config: dict[str, Any] = {}
        for param in selected_tool.get("string_params", []):
            key = param["config_key"]
            val = str(form_data.get(f"cfg_{key}", "")).strip()
            if val:
                new_config[key] = val
        for param in selected_tool.get("array_params", []):
            key = param["config_key"]
            raw = str(form_data.get(f"cfg_{key}", "")).strip()
            if raw:
                values = [v.strip() for v in raw.splitlines() if v.strip()]
                if values:
                    new_config[key] = values
        save_webui_config(selected_tool, new_config)
    except (ValueError, Exception) as ex:
        error_text = quote_plus(str(ex))
        return RedirectResponse(url=f"/?tool_key={selected_tool['key']}&config_error={error_text}", status_code=303)

    return RedirectResponse(url=f"/?tool_key={selected_tool['key']}&config_saved=true", status_code=303)


@app.post("/config/import")
def import_config(
    tool_key: str = Form(default=""),
) -> object:
    selected_tool = get_tool_by_key(tool_key)
    if selected_tool is None:
        return RedirectResponse(url="/?config_error=Unknown+tool+selected", status_code=303)

    try:
        import_from_options_file(selected_tool)
    except ValueError as ex:
        error_text = quote_plus(str(ex))
        return RedirectResponse(url=f"/?tool_key={selected_tool['key']}&config_error={error_text}", status_code=303)

    return RedirectResponse(url=f"/?tool_key={selected_tool['key']}&config_imported=true", status_code=303)
