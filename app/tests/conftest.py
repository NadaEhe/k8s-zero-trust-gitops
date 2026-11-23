"""Tests run against a REAL PostgreSQL (CI starts one as a service container).

Locally:  docker compose up -d db   then   pytest
"""

from __future__ import annotations

import os
from collections.abc import Iterator

import psycopg
import pytest
from fastapi.testclient import TestClient

os.environ.setdefault("METRICS_ENABLED", "false")
os.environ.setdefault("DB_HOST", "localhost")
os.environ.setdefault("DB_PORT", "5432")
os.environ.setdefault("DB_NAME", "taskapi")
os.environ.setdefault("DB_USER", "taskapi")
os.environ.setdefault("DB_PASSWORD", "taskapi")
os.environ.setdefault("APP_ENV", "test")

from taskapi.config import load_settings  # noqa: E402
from taskapi.main import create_app  # noqa: E402


@pytest.fixture()
def client() -> Iterator[TestClient]:
    settings = load_settings()
    app = create_app(settings)
    with TestClient(app) as test_client:
        # The first successful readiness check creates the schema.
        assert test_client.get("/readyz").status_code == 200
        with psycopg.connect(settings.conninfo, password=settings.db_password) as conn:
            conn.execute("TRUNCATE tasks RESTART IDENTITY")
        yield test_client
