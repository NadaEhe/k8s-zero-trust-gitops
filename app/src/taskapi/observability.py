"""Prometheus metrics and JSON logging.

Metrics are served on a SEPARATE port (9090 by default), not on the public
API port. The network policy then only lets Prometheus reach that port, so
/metrics is never exposed through the Gateway.
"""

from __future__ import annotations

import json
import logging
import sys
import time
from collections.abc import Awaitable, Callable

from prometheus_client import Counter, Gauge, Histogram
from starlette.requests import Request
from starlette.responses import Response

HTTP_REQUESTS = Counter(
    "http_requests_total",
    "Total HTTP requests handled by the API.",
    ["method", "route", "status"],
)
HTTP_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds.",
    ["method", "route"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)
TASKS_CREATED = Counter("taskapi_tasks_created_total", "Number of tasks created.")
APP_INFO = Gauge("taskapi_build_info", "Build information.", ["version", "env"])

log = logging.getLogger("taskapi.access")


def _route_template(request: Request) -> str:
    """Use the route *template* (/api/tasks/{task_id}), never the raw path.

    Raw paths would create one time series per task id (high cardinality),
    which is a classic way to overload Prometheus.
    """
    route = request.scope.get("route")
    path = getattr(route, "path", None)
    return path if isinstance(path, str) else "unmatched"


async def metrics_middleware(
    request: Request, call_next: Callable[[Request], Awaitable[Response]]
) -> Response:
    start = time.perf_counter()
    status = 500
    try:
        response = await call_next(request)
        status = response.status_code
        return response
    finally:
        elapsed = time.perf_counter() - start
        route = _route_template(request)
        HTTP_REQUESTS.labels(request.method, route, str(status)).inc()
        HTTP_LATENCY.labels(request.method, route).observe(elapsed)
        if route not in {"/healthz", "/readyz"}:
            log.info(
                "request",
                extra={
                    "method": request.method,
                    "route": route,
                    "status": status,
                    "duration_ms": round(elapsed * 1000, 2),
                },
            )


class JsonFormatter(logging.Formatter):
    """One JSON object per line: easy to parse for Loki, Elastic, etc."""

    _extra_keys = ("method", "route", "status", "duration_ms")

    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        for key in self._extra_keys:
            if hasattr(record, key):
                payload[key] = getattr(record, key)
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        return json.dumps(payload)


def configure_logging(level: str) -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(level)
