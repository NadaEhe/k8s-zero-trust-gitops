"""Configuration read from environment variables (12-factor style).

In Kubernetes these come from the Deployment: plain values from the Helm
chart, the database password from a Secret.
"""

from __future__ import annotations

import os
import socket
from dataclasses import dataclass

from taskapi import __version__


def _env_bool(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Settings:
    app_env: str
    app_version: str
    pod_name: str
    db_host: str
    db_port: int
    db_name: str
    db_user: str
    db_password: str
    db_pool_min: int
    db_pool_max: int
    metrics_enabled: bool
    metrics_port: int
    log_level: str

    @property
    def conninfo(self) -> str:
        # libpq keyword/value string. The password is passed separately
        # (see db.py) so it never ends up in a log line or error message.
        return (
            f"host={self.db_host} port={self.db_port} dbname={self.db_name} "
            f"user={self.db_user} connect_timeout=3 application_name=taskapi"
        )


def load_settings() -> Settings:
    return Settings(
        app_env=os.getenv("APP_ENV", "local"),
        app_version=os.getenv("APP_VERSION", __version__),
        pod_name=os.getenv("POD_NAME", socket.gethostname()),
        db_host=os.getenv("DB_HOST", "localhost"),
        db_port=int(os.getenv("DB_PORT", "5432")),
        db_name=os.getenv("DB_NAME", "taskapi"),
        db_user=os.getenv("DB_USER", "taskapi"),
        db_password=os.getenv("DB_PASSWORD", ""),
        db_pool_min=int(os.getenv("DB_POOL_MIN", "1")),
        db_pool_max=int(os.getenv("DB_POOL_MAX", "5")),
        metrics_enabled=_env_bool("METRICS_ENABLED", True),
        metrics_port=int(os.getenv("METRICS_PORT", "9090")),
        log_level=os.getenv("LOG_LEVEL", "INFO").upper(),
    )
