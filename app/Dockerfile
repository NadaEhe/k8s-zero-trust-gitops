# syntax=docker/dockerfile:1
#
# Multi-stage build:
#   1. "build" installs dependencies into a virtualenv (has pip, compilers, caches)
#   2. "runtime" copies only the virtualenv + source: smaller image, smaller attack surface
#
# The image runs as a non-root user with a read-only root filesystem in Kubernetes.

ARG PYTHON_IMAGE=python:3.13-slim-trixie

FROM ${PYTHON_IMAGE} AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
COPY requirements.txt .
RUN pip install --require-virtualenv -r requirements.txt \
 # pip is only needed to BUILD: remove it (and its vendored libraries) from the venv.
 && pip uninstall --yes pip

FROM ${PYTHON_IMAGE} AS runtime
ARG APP_VERSION=dev
LABEL org.opencontainers.image.title="taskapi" \
      org.opencontainers.image.description="Demo API for the k8s-zero-trust-gitops platform" \
      org.opencontainers.image.source="https://github.com/NadaEhe/k8s-zero-trust-gitops" \
      org.opencontainers.image.licenses="MIT"

# - Apply Debian security updates published after the base image was built.
# - Remove pip/setuptools from the system Python: no package manager at runtime,
#   so an attacker inside the container cannot install tools, and the vendored
#   libraries of pip disappear from the vulnerability scan.
# - Fixed numeric UID/GID so Kubernetes can check runAsNonRoot without a lookup.
RUN apt-get update \
 && apt-get upgrade --yes --no-install-recommends \
 && rm -rf /var/lib/apt/lists/* \
 && (python -m pip uninstall --yes pip setuptools wheel || true) \
 && groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

ENV PATH=/opt/venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app/src \
    APP_VERSION=${APP_VERSION}

COPY --from=build /opt/venv /opt/venv
COPY --chown=root:root src/ /app/src/
WORKDIR /app

USER 10001:10001
EXPOSE 8000 9090

# --timeout-graceful-shutdown: finish in-flight requests when Kubernetes sends SIGTERM.
# --proxy-headers: trust X-Forwarded-* from the Gateway (Envoy) to log the real client.
CMD ["uvicorn", "taskapi.main:app", "--host", "0.0.0.0", "--port", "8000", \
     "--proxy-headers", "--forwarded-allow-ips", "*", \
     "--timeout-graceful-shutdown", "20", "--no-access-log"]
