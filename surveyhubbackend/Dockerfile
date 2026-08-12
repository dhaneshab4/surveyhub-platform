# syntax=docker/dockerfile:1.7
#
# Multi-stage. The previous single-stage image shipped gcc and libpq-dev into production
# and ran as root; both are fixed here.
#
#   builder  - has the toolchain, builds a venv
#   runtime  - slim, no compiler, non-root, healthchecked

ARG PYTHON_VERSION=3.12-slim

# --------------------------------------------------------------------------- builder
FROM python:${PYTHON_VERSION} AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential libpq-dev \
    && rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt /tmp/requirements.txt
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --upgrade pip && pip install -r /tmp/requirements.txt

# --------------------------------------------------------------------------- runtime
FROM python:${PYTHON_VERSION} AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    PORT=8000 \
    PROMETHEUS_MULTIPROC_DIR=/tmp/prometheus

# libpq5 is the runtime half of libpq-dev; the compiler stays behind in the builder.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libpq5 curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 1001 app \
    && useradd --system --uid 1001 --gid app --create-home app \
    && mkdir -p /tmp/prometheus && chown app:app /tmp/prometheus

COPY --from=builder /opt/venv /opt/venv

WORKDIR /code
COPY --chown=app:app . /code

# collectstatic needs *a* key, never the real one. The runtime key arrives as a secret.
RUN SECRET_KEY="build-time-placeholder-not-used-at-runtime" DEBUG=False \
    python manage.py collectstatic --noinput \
    && chown -R app:app /code/staticfiles

USER app

EXPOSE 8000

# --noproxy '*' for the same reason the other images disable it: an injected HTTP_PROXY
# would send a loopback probe out to the corporate proxy and back as a 503.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS --noproxy '*' "http://127.0.0.1:${PORT}/healthz" || exit 1

# gunicorn.conf.py carries the tuning and, crucially, the child_exit hook that retires
# per-worker Prometheus files. Without it, metrics from dead workers are collected
# forever and every counter drifts upward.
CMD ["sh", "-c", "mkdir -p \"${PROMETHEUS_MULTIPROC_DIR:-/tmp/prometheus}\" \
     && exec gunicorn -c gunicorn.conf.py surveyhubbackend.wsgi:application"]
