"""HTTP API.

Endpoints
---------
GET    /healthz              liveness  (is the process alive?)
GET    /readyz               readiness (can it serve traffic? checks PostgreSQL)
GET    /api/info             version, environment and pod name
GET    /api/tasks            list tasks
POST   /api/tasks            create a task
GET    /api/tasks/{id}       read one task
PATCH  /api/tasks/{id}       mark a task done / not done
DELETE /api/tasks/{id}       delete a task
"""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import datetime

from fastapi import FastAPI, HTTPException, Query, Request, Response, status
from fastapi.responses import JSONResponse
from prometheus_client import start_http_server
from pydantic import BaseModel, Field

from taskapi.config import Settings, load_settings
from taskapi.db import Database
from taskapi.observability import (
    APP_INFO,
    TASKS_CREATED,
    configure_logging,
    metrics_middleware,
)

log = logging.getLogger("taskapi")


class TaskIn(BaseModel):
    title: str = Field(min_length=1, max_length=200)


class TaskPatch(BaseModel):
    done: bool


class TaskOut(BaseModel):
    id: int
    title: str
    done: bool
    created_at: datetime


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or load_settings()
    configure_logging(settings.log_level)
    db = Database(settings)

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        if settings.metrics_enabled:
            start_http_server(settings.metrics_port)
            log.info("metrics server listening on :%s", settings.metrics_port)
        APP_INFO.labels(settings.app_version, settings.app_env).set(1)
        # Non-blocking: the schema is created by the first successful /readyz
        # call, so the process starts instantly even if PostgreSQL is late.
        db.open()
        yield
        db.close()

    app = FastAPI(
        title="TaskAPI",
        version=settings.app_version,
        lifespan=lifespan,
        docs_url="/api/docs",
        openapi_url="/api/openapi.json",
        redoc_url=None,
    )
    app.middleware("http")(metrics_middleware)

    def get_or_404(task_id: int) -> dict:
        task = db.get_task(task_id)
        if task is None:
            raise HTTPException(status_code=404, detail="task not found")
        return task

    # --- probes ---------------------------------------------------------
    @app.get("/healthz", include_in_schema=False)
    def healthz() -> dict[str, str]:
        # Never touch the database here: a DB outage must not make
        # Kubernetes kill and restart healthy API processes.
        return {"status": "ok"}

    @app.get("/readyz", include_in_schema=False)
    def readyz() -> JSONResponse:
        try:
            db.ensure_schema()
            db.ping()
        except Exception as exc:
            log.warning("readiness check failed: %s", exc)
            return JSONResponse({"status": "unavailable"}, status_code=503)
        return JSONResponse({"status": "ready"})

    # --- API --------------------------------------------------------------
    @app.get("/api/info")
    def info(request: Request) -> dict[str, str]:
        return {
            "app": "taskapi",
            "version": settings.app_version,
            "env": settings.app_env,
            "pod": settings.pod_name,
            "client": request.client.host if request.client else "unknown",
        }

    @app.get("/api/tasks", response_model=list[TaskOut])
    def list_tasks(limit: int = Query(default=50, ge=1, le=200)) -> list[dict]:
        return db.list_tasks(limit)

    @app.post("/api/tasks", response_model=TaskOut, status_code=status.HTTP_201_CREATED)
    def create_task(body: TaskIn) -> dict:
        task = db.create_task(body.title.strip())
        TASKS_CREATED.inc()
        return task

    @app.get("/api/tasks/{task_id}", response_model=TaskOut)
    def get_task(task_id: int) -> dict:
        return get_or_404(task_id)

    @app.patch("/api/tasks/{task_id}", response_model=TaskOut)
    def patch_task(task_id: int, body: TaskPatch) -> dict:
        task = db.set_done(task_id, body.done)
        if task is None:
            raise HTTPException(status_code=404, detail="task not found")
        return task

    @app.delete("/api/tasks/{task_id}", status_code=status.HTTP_204_NO_CONTENT)
    def delete_task(task_id: int) -> Response:
        if not db.delete_task(task_id):
            raise HTTPException(status_code=404, detail="task not found")
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    return app


app = create_app()
