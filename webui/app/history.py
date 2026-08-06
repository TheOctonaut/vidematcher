import json
import sqlite3
from pathlib import Path
from typing import Any

from app.config import settings


DB_PATH = Path(settings.webui_config_dir).parent / "webui-history.sqlite3"


def _get_conn() -> sqlite3.Connection:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_history() -> None:
    conn = _get_conn()
    try:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS run_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                tool_key TEXT NOT NULL,
                started_at TEXT NOT NULL,
                finished_at TEXT NOT NULL,
                status TEXT NOT NULL,
                return_code INTEGER NOT NULL,
                summary_line TEXT,
                command_json TEXT NOT NULL,
                stdout TEXT,
                stderr TEXT
            )
            """
        )
        conn.commit()
    finally:
        conn.close()


def record_run(result: dict[str, Any]) -> None:
    init_history()
    conn = _get_conn()
    try:
        status = "ok" if int(result.get("return_code", 1)) == 0 else "failed"
        if result.get("summary_line"):
            summary = str(result["summary_line"])
            if "status=noop" in summary:
                status = "noop"
            elif "status=partial" in summary:
                status = "partial"
            elif "status=aborted" in summary:
                status = "aborted"

        conn.execute(
            """
            INSERT INTO run_history (
                tool_key, started_at, finished_at, status, return_code,
                summary_line, command_json, stdout, stderr
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                result.get("tool_key"),
                result.get("started_at"),
                result.get("finished_at"),
                status,
                int(result.get("return_code", 1)),
                result.get("summary_line"),
                json.dumps(result.get("command", [])),
                result.get("stdout"),
                result.get("stderr"),
            ),
        )
        conn.commit()
    finally:
        conn.close()


def list_recent_runs(limit: int = 25) -> list[dict[str, Any]]:
    init_history()
    conn = _get_conn()
    try:
        rows = conn.execute(
            """
            SELECT id, tool_key, started_at, finished_at, status, return_code, summary_line
            FROM run_history
            ORDER BY id DESC
            LIMIT ?
            """,
            (limit,),
        ).fetchall()
        return [dict(row) for row in rows]
    finally:
        conn.close()


def get_run_by_id(run_id: int) -> dict[str, Any] | None:
    init_history()
    conn = _get_conn()
    try:
        row = conn.execute(
            """
            SELECT id, tool_key, started_at, finished_at, status, return_code, summary_line, command_json, stdout, stderr
            FROM run_history
            WHERE id = ?
            """,
            (run_id,),
        ).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()
