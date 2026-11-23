"""Database access: a small connection pool plus the queries the API needs."""

from __future__ import annotations

import logging
from typing import Any

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from taskapi.config import Settings

log = logging.getLogger(__name__)

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS tasks (
    id          BIGSERIAL PRIMARY KEY,
    title       VARCHAR(200) NOT NULL,
    done        BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);
"""


class Database:
    def __init__(self, settings: Settings) -> None:
        # open=False + open(wait=False): the API starts even if PostgreSQL is
        # not reachable yet. Liveness stays green, readiness stays red until
        # the database answers. Kubernetes then simply waits instead of
        # restarting the pod in a loop.
        self.pool = ConnectionPool(
            conninfo=settings.conninfo,
            kwargs={"password": settings.db_password, "row_factory": dict_row},
            min_size=settings.db_pool_min,
            max_size=settings.db_pool_max,
            timeout=3,  # must stay below the readiness probe timeout (5s)
            open=False,
            name="taskapi",
        )
        self.schema_ready = False

    def open(self) -> None:
        self.pool.open(wait=False)

    def close(self) -> None:
        self.pool.close()

    def ensure_schema(self) -> None:
        if self.schema_ready:
            return
        with self.pool.connection() as conn:
            conn.execute(SCHEMA_SQL)
        self.schema_ready = True
        log.info("database schema ready")

    def ping(self) -> None:
        with self.pool.connection() as conn:
            conn.execute("SELECT 1")

    # --- tasks -----------------------------------------------------------
    def list_tasks(self, limit: int) -> list[dict[str, Any]]:
        with self.pool.connection() as conn:
            cur = conn.execute(
                "SELECT id, title, done, created_at FROM tasks ORDER BY id DESC LIMIT %s",
                (limit,),
            )
            return list(cur.fetchall())

    def get_task(self, task_id: int) -> dict[str, Any] | None:
        with self.pool.connection() as conn:
            cur = conn.execute(
                "SELECT id, title, done, created_at FROM tasks WHERE id = %s", (task_id,)
            )
            return cur.fetchone()

    def create_task(self, title: str) -> dict[str, Any]:
        with self.pool.connection() as conn:
            cur = conn.execute(
                "INSERT INTO tasks (title) VALUES (%s) RETURNING id, title, done, created_at",
                (title,),
            )
            row = cur.fetchone()
            assert row is not None
            return row

    def set_done(self, task_id: int, done: bool) -> dict[str, Any] | None:
        with self.pool.connection() as conn:
            cur = conn.execute(
                "UPDATE tasks SET done = %s WHERE id = %s RETURNING id, title, done, created_at",
                (done, task_id),
            )
            return cur.fetchone()

    def delete_task(self, task_id: int) -> bool:
        with self.pool.connection() as conn:
            cur = conn.execute("DELETE FROM tasks WHERE id = %s", (task_id,))
            return cur.rowcount > 0
