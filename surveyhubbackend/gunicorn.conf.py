"""Gunicorn configuration.

The important part is ``child_exit``. In multiprocess mode prometheus_client writes one
set of mmap files per worker pid. When a worker dies — a restart, a reload, an OOM kill —
its files stay on disk and keep being collected, so counters from processes that no
longer exist are added into every scrape forever. Over a long-lived deployment the
numbers drift upward and the cardinality grows without bound.

``mark_process_dead`` retires those files as each worker exits.
"""
import os

from prometheus_client import multiprocess


def child_exit(server, worker):  # noqa: ARG001 - gunicorn calls this with both
    if os.environ.get("PROMETHEUS_MULTIPROC_DIR"):
        multiprocess.mark_process_dead(worker.pid)


def on_starting(server):  # noqa: ARG001
    """Start from a clean metrics directory.

    Stale files from a previous container generation would otherwise be collected as if
    they belonged to live workers.
    """
    path = os.environ.get("PROMETHEUS_MULTIPROC_DIR")
    if not path:
        return
    os.makedirs(path, exist_ok=True)
    for name in os.listdir(path):
        if name.endswith(".db"):
            try:
                os.unlink(os.path.join(path, name))
            except OSError:
                pass


# Defaults; the CMD in the Dockerfile can still override any of these.
bind = f"0.0.0.0:{os.environ.get('PORT', '8000')}"
workers = int(os.environ.get("GUNICORN_WORKERS", "3"))
threads = int(os.environ.get("GUNICORN_THREADS", "4"))
timeout = int(os.environ.get("GUNICORN_TIMEOUT", "90"))
graceful_timeout = 30
keepalive = 5
accesslog = "-"
errorlog = "-"
forwarded_allow_ips = "*"
# Recycle workers periodically so a slow leak never becomes an incident.
max_requests = 1000
max_requests_jitter = 100
