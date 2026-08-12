"""Prometheus instrumentation and health endpoints.

Three things are exposed:

* ``/healthz``  - liveness. Process is up. No dependencies touched, so a database blip
  never causes the orchestrator to kill an otherwise healthy container.
* ``/readyz``   - readiness. Database reachable. Fails the pod out of the load balancer
  without restarting it.
* ``/metrics``  - Prometheus exposition.

The Gemini counters are the interesting part: LLM spend is the operating cost that
actually scales with traffic here, and it is invisible unless you measure it per call.
"""
from __future__ import annotations

import os
import time

from django.db import connection
from django.http import HttpResponse, JsonResponse
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
    multiprocess,
)

APP_VERSION = os.environ.get("APP_VERSION", "dev")
ENVIRONMENT = os.environ.get("ENVIRONMENT", "local")

# prometheus_client opens its mmap files the moment a metric is defined, and raises
# FileNotFoundError if the directory is absent. Because this module is imported through
# the URLconf, that would take down *every* entrypoint sharing the image — including
# `manage.py migrate`, which Fly runs as its release_command before any web process
# exists. Creating it here makes the failure impossible regardless of how we are started.
_MULTIPROC_DIR = os.environ.get("PROMETHEUS_MULTIPROC_DIR")
if _MULTIPROC_DIR:
    try:
        os.makedirs(_MULTIPROC_DIR, exist_ok=True)
        # Existing is not the same as writable. A tmpfs mounted over the directory
        # arrives root-owned and masks the ownership the image set up, so the first
        # metric definition dies with EACCES. Prove we can write before committing.
        _probe = os.path.join(_MULTIPROC_DIR, f".probe-{os.getpid()}")
        with open(_probe, "wb"):
            pass
        os.unlink(_probe)
    except OSError:
        # Read-only filesystem, wrong owner, whatever: fall back to single-process
        # metrics rather than refusing to boot. Undercounting beats an outage.
        os.environ.pop("PROMETHEUS_MULTIPROC_DIR", None)
        _MULTIPROC_DIR = None

# Buckets tuned for this app: most API calls are tens of milliseconds, but anything
# routed through Gemini lands in the multi-second range, so the tail matters.
LATENCY_BUCKETS = (0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60)

http_requests = Counter(
    "surveyhub_http_requests_total",
    "HTTP requests by method, route and status class.",
    ["method", "route", "status"],
)
http_latency = Histogram(
    "surveyhub_http_request_duration_seconds",
    "HTTP request latency.",
    ["method", "route"],
    buckets=LATENCY_BUCKETS,
)
# multiprocess_mode matters under gunicorn. The default ('all') appends a pid label to
# every sample, so each worker restart strands a dead series forever and the graph grows
# teeth. 'livesum' adds up only the workers that are currently alive.
http_in_flight = Gauge(
    "surveyhub_http_requests_in_flight",
    "Requests currently being served.",
    multiprocess_mode="livesum",
)
# Every worker reports the same build, so collapse them into one series.
build_info = Gauge(
    "surveyhub_build_info",
    "Build metadata; always 1, the labels carry the payload.",
    ["version", "environment"],
    multiprocess_mode="max",
)
build_info.labels(version=APP_VERSION, environment=ENVIRONMENT).set(1)

# ---------------------------------------------------------------------------- Gemini
gemini_calls = Counter(
    "surveyhub_gemini_calls_total",
    "Gemini API calls by operation and outcome.",
    ["operation", "outcome"],
)
gemini_latency = Histogram(
    "surveyhub_gemini_duration_seconds",
    "Gemini call latency.",
    ["operation"],
    buckets=(0.25, 0.5, 1, 2, 5, 10, 20, 30, 60),
)
gemini_tokens = Counter(
    "surveyhub_gemini_tokens_total",
    "Gemini tokens consumed, split by direction.",
    ["operation", "direction"],
)
gemini_cost = Counter(
    "surveyhub_gemini_cost_usd_total",
    "Estimated Gemini spend in USD.",
    ["operation"],
)

# Published per-million-token pricing. Wrong numbers here are still far more useful
# than no numbers, and the ratio between operations stays correct either way.
PRICE_PER_MTOK = {
    "input": float(os.environ.get("GEMINI_PRICE_INPUT_PER_MTOK", "0.10")),
    "output": float(os.environ.get("GEMINI_PRICE_OUTPUT_PER_MTOK", "0.40")),
}

# -------------------------------------------------------------------------- webhooks
webhook_deliveries = Counter(
    "surveyhub_webhook_deliveries_total",
    "Outbound webhook deliveries by outcome.",
    ["outcome"],
)
webhook_latency = Histogram(
    "surveyhub_webhook_duration_seconds",
    "Outbound webhook delivery latency.",
    buckets=(0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30),
)

# --------------------------------------------------------------------------- domain
surveys_created = Counter("surveyhub_surveys_created_total", "Surveys created.")
responses_received = Counter(
    "surveyhub_responses_received_total", "Survey responses submitted.", ["anonymous"]
)


def record_gemini(operation: str, *, outcome: str, duration: float,
                  input_tokens: int = 0, output_tokens: int = 0) -> None:
    """Call this from ai_client.py around every Gemini request."""
    gemini_calls.labels(operation=operation, outcome=outcome).inc()
    gemini_latency.labels(operation=operation).observe(duration)
    if input_tokens:
        gemini_tokens.labels(operation=operation, direction="input").inc(input_tokens)
    if output_tokens:
        gemini_tokens.labels(operation=operation, direction="output").inc(output_tokens)
    cost = (input_tokens * PRICE_PER_MTOK["input"]
            + output_tokens * PRICE_PER_MTOK["output"]) / 1_000_000
    if cost:
        gemini_cost.labels(operation=operation).inc(cost)


class PrometheusMiddleware:
    """Times every request and labels it by URL pattern, never by raw path.

    Labelling by raw path would mint a new time series per survey id and blow up
    Prometheus cardinality within a day of real traffic.
    """

    SKIP = {"/metrics", "/healthz", "/readyz"}

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        if request.path in self.SKIP:
            return self.get_response(request)

        start = time.perf_counter()
        http_in_flight.inc()
        try:
            response = self.get_response(request)
            status = response.status_code
        except Exception:
            status = 500
            raise
        finally:
            http_in_flight.dec()
            elapsed = time.perf_counter() - start
            route = self._route(request)
            http_latency.labels(method=request.method, route=route).observe(elapsed)
            http_requests.labels(
                method=request.method, route=route, status=str(status)
            ).inc()
        return response

    @staticmethod
    def _route(request) -> str:
        match = getattr(request, "resolver_match", None)
        if match and match.route:
            return "/" + match.route.lstrip("/")
        return "unmatched"


def metrics_view(_request):
    """Prometheus scrape target.

    Under gunicorn each worker holds its own counters, so when PROMETHEUS_MULTIPROC_DIR
    is set the values are merged across workers before being served. Without it you
    would see one arbitrary worker's view and undercount by roughly the worker count.
    """
    if os.environ.get("PROMETHEUS_MULTIPROC_DIR"):
        registry = CollectorRegistry()
        multiprocess.MultiProcessCollector(registry)
        payload = generate_latest(registry)
    else:
        payload = generate_latest()
    return HttpResponse(payload, content_type=CONTENT_TYPE_LATEST)


def healthz(_request):
    """Liveness: deliberately dependency-free."""
    return JsonResponse({"status": "ok", "version": APP_VERSION,
                         "environment": ENVIRONMENT})


def readyz(_request):
    """Readiness: can we actually serve traffic?"""
    try:
        with connection.cursor() as cur:
            cur.execute("SELECT 1")
            cur.fetchone()
    except Exception as exc:
        return JsonResponse(
            {"status": "unavailable", "database": "down", "detail": str(exc)[:200]},
            status=503,
        )
    return JsonResponse({"status": "ready", "database": "up"})
