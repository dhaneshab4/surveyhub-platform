# Platform

The application in this repository was written by [Rakesh](https://github.com/Rakesh-git-2/surveyhub).
This document covers the platform layer built around it: containers, CI/CD, infrastructure
as code, observability and policy enforcement.

---

## Architecture

```
                    ┌──────────────────────────────────────────┐
   browser ────────▶│ Cloudflare Pages    static export        │
                    │ surveyhub-aha.pages.dev                  │
                    └───────────────────┬──────────────────────┘
                                        │ XHR (API URL baked at build time)
                                        ▼
                    ┌──────────────────────────────────────────┐
                    │ Fly.io  surveyhub-api                    │
                    │ gunicorn 3w x 4t, non-root, scale-to-zero│
                    │ /healthz  /readyz  /metrics              │
                    └───────┬──────────────────────┬───────────┘
                            │                      │
                   ┌────────▼────────┐    ┌────────▼─────────┐
                   │ Neon Postgres   │    │ Google Gemini    │
                   │ branch per env  │    │ metered + costed │
                   └─────────────────┘    └──────────────────┘

   CI ── test → scan → policy → build → GHCR
   CD ── staging → smoke → [approval] → production → smoke → rollback on failure
```

## What runs where

| Component | Platform | Notes |
|---|---|---|
| Frontend | Cloudflare Pages | Static export; the API URL is compiled into the bundle |
| API | Fly.io, `lhr` | Scale-to-zero off-production; rolling deploys in production |
| Database | Neon | One branch per environment, suspends when idle |
| Metrics | Prometheus + Grafana | Local via compose; Grafana Cloud free tier in production |
| Images | GHCR | Built once in CI, promoted by digest |
| State | Cloudflare R2 | S3-compatible Terraform backend |

Total running cost: zero, on free tiers.

---

## Service level objectives

Measured over a rolling 30 days.

| SLO | Target | Error budget |
|---|---|---|
| Availability — requests not returning 5xx | 99.5% | 0.5%, about 3h 39m per month |
| Latency — requests completing under 1s | 99.0% | 1% |

Alerting is multi-window, multi-burn-rate, per the Google SRE workbook. A page requires a
fast window and a slow window to agree, so a thirty-second blip does not wake anyone:

| Burn rate | Long window | Short window | Budget consumed | Action |
|---|---|---|---|---|
| 14.4x | 1h | 5m | 2% | page |
| 6x | 6h | 30m | 5% | page |
| 1x | 3d | — | 10% | ticket |

Rules live in `observability/rules/slo.yml`.

---

## Metrics

Standard RED metrics on every route, plus two things specific to this application.

**LLM cost.** Gemini is the operating expense that scales with traffic here, and it is
invisible unless measured per call. `surveyhub_gemini_cost_usd_total` and
`surveyhub_gemini_tokens_total` are exported per operation, with a dashboard panel for
cost per survey generated and an alert at $1/hour. A retry loop against a paid API is a
cost incident before it is ever an availability incident.

**Webhook delivery.** Outbound deliveries are fire-and-forget from a background thread,
so a silently failing endpoint would otherwise never surface.

To instrument the Gemini calls, wrap them in `surveys/ai_client.py`:

```python
from surveys.observability import record_gemini

start = time.perf_counter()
try:
    resp = client.models.generate_content(...)
    usage = getattr(resp, "usage_metadata", None)
    record_gemini(
        "generate_survey",
        outcome="success",
        duration=time.perf_counter() - start,
        input_tokens=getattr(usage, "prompt_token_count", 0),
        output_tokens=getattr(usage, "candidates_token_count", 0),
    )
except Exception:
    record_gemini("generate_survey", outcome="error",
                  duration=time.perf_counter() - start)
    raise
```

### Cardinality

Requests are labelled by **URL pattern**, never raw path. Labelling by path would mint a
new time series for every survey id and take Prometheus down within a day of real traffic.

### Multiprocess

Gunicorn workers each hold their own counters, so `PROMETHEUS_MULTIPROC_DIR` is set and
the registry merges across workers at scrape time. Two consequences worth knowing:

- Gauges need an explicit `multiprocess_mode`. The default appends a `pid` label, so
  every worker restart strands a dead series forever.
- `gunicorn.conf.py` implements `child_exit` to call `mark_process_dead`. Without it,
  files belonging to exited workers are collected indefinitely and counters drift up.

---

## Health endpoints

| Endpoint | Purpose | Touches the database |
|---|---|---|
| `/healthz` | Liveness — is the process alive | No |
| `/readyz` | Readiness — can it serve | Yes, `SELECT 1` |
| `/metrics` | Prometheus exposition | No |

The split matters. Fly's health check targets `/readyz`, so a database blip removes the
machine from rotation without restarting it. Pointing liveness at the database instead
turns a brief outage into a restart loop that makes it worse.

All three are listed in `SECURE_REDIRECT_EXEMPT`. Probes arrive over plain HTTP on the
internal network with no `X-Forwarded-Proto`, so without the exemption
`SECURE_SSL_REDIRECT` answers them with a 301 and an empty body — and a Docker
`HEALTHCHECK` using `curl -f` treats that redirect as success while proving nothing.

> `/metrics` is currently unauthenticated. Before this handles anything real, restrict it
> to the Fly private network (`.internal`) or put a bearer token in front of it.

---

## CI/CD

**CI** (`.github/workflows/ci.yml`) runs on every push and PR:

1. Backend — ruff, missing-migration check, `check --deploy`, tests with coverage against
   a real Postgres, then a live assertion that `/healthz`, `/readyz` and `/metrics` answer
2. Frontend — lint, static export, and an assertion that `out/index.html` exists, because
   `output: "export"` fails silently if a page opts into SSR
3. Security — Trivy for vulnerabilities, secrets and misconfiguration; SARIF to code
   scanning; gitleaks on history
4. Policy — hadolint on both Dockerfiles, conftest against the container and compose rules
5. Images — buildx to GHCR with SBOM and provenance, image scan, and a hard assertion that
   neither image runs as root

**CD** (`.github/workflows/cd.yml`) runs after CI is green on `main`:

staging → smoke test → GitHub environment approval → production → smoke test, with an
automatic `flyctl releases rollback` if the production smoke test fails.

### Required secrets

| Secret | Used for |
|---|---|
| `FLY_API_TOKEN` | Deploys |
| `CLOUDFLARE_API_TOKEN` | Pages publish |
| `CLOUDFLARE_ACCOUNT_ID` | Pages publish |

Add a required reviewer to the `production` environment in repo settings — that is the
approval gate, enforced by GitHub rather than by convention.

---

## Infrastructure as code

`terraform/` declares the Neon project, the Fly app and machines, and the Cloudflare Pages
project.

```bash
cp terraform/backend.hcl.example terraform/backend.hcl   # then fill it in
make tf-init
make tf-plan ENV=staging
make tf-apply ENV=staging
```

Two deliberate boundaries:

**Terraform owns infrastructure; CD owns releases.** `fly_machine.image` is in
`ignore_changes`, so Terraform will not revert the image CD just deployed. Mixing the two
means every code deploy needs cloud credentials and a plan.

**Secrets never enter Terraform state.** Machine `env` carries configuration only. The
Django `SECRET_KEY` is generated by Terraform but delivered through `flyctl secrets set`,
because anything in state sits in the R2 bucket in plaintext:

```bash
terraform output -raw bootstrap_secrets_command
```

---

## Policy as code

`policy/` holds Rego enforced by conftest in CI. Each rule exists because the violation is
invisible in testing and expensive later:

- Containers must not run as root, and must not reset to root after dropping privileges
- Base images must be pinned; no floating `:latest`
- No secrets in `ENV` — they persist in image history even if unset in a later layer
- `apt-get` must use `--no-install-recommends` and clear its lists
- Compose services must not run privileged, use host networking, or mount the Docker
  socket, and must not hardcode credentials

Run locally with `make policy`.

---

## Runbook

### Error budget burn

1. Check the Grafana dashboard, "Error rate vs burn-rate thresholds"
2. Identify the failing route in "Slowest routes" and the status breakdown
3. `flyctl logs --app surveyhub-api` for the exception
4. If it started at a deploy: `flyctl releases rollback <version> --app surveyhub-api`
5. If the database is implicated, check `/readyz` and the Neon dashboard for a suspended
   endpoint — Neon suspends on idle and the first request pays a cold start

### API down

`up{job="surveyhub-api"} == 0` means the scrape is failing, which is not necessarily an
outage. Check `flyctl status --app surveyhub-api` first. With `min_machines_running = 0`
a machine that has scaled to zero looks identical to a machine that has crashed.

### Gemini spend spike

Fires above $1/hour. Almost always a retry loop. Check
`surveyhub_gemini_calls_total{outcome!="success"}` — if failures are climbing alongside
cost, the retry policy in `ai_client.py` is amplifying an upstream error. The immediate
mitigation is to unset `GEMINI_API_KEY`; AI features degrade, the rest of the app serves.

### Database unreachable

`/readyz` returns 503 and Fly stops routing. Check the Neon dashboard for suspension or
connection-limit exhaustion. `conn_max_age=600` holds connections open for ten minutes,
which on a small Neon plan can exhaust the pool faster than expected under burst traffic.

---

## Local development

```bash
make up        # app + Prometheus + Grafana
make load      # synthetic traffic so the dashboard has data
make verify    # everything CI runs
make down
```

| Service | URL |
|---|---|
| App | http://localhost:3000 |
| API | http://localhost:8000 |
| Metrics | http://localhost:8000/metrics |
| Prometheus | http://localhost:9090 |
| Grafana | http://localhost:3001 |

---

## Bugs found and fixed while building this

Recorded because they are the kind of thing that only surfaces when you actually run it.

1. **The frontend image could never start.** `next.config.ts` sets `output: "export"`, so
   the build emits static files to `out/`. The Dockerfile copied `.next/standalone` and
   ran `node server.js`, neither of which exists in export mode. It also expected a
   `bun.lockb` that is not in the repo. Rebuilt to serve the export from nginx, which also
   makes local behaviour match Cloudflare Pages.

2. **The Fly static mount pointed at a directory that never existed.** `settings.py` sets
   `STATIC_ROOT = BASE_DIR/'staticfiles'`, but `fly.toml` declared
   `guest_path = '/code/static'`. The mount was inert and every static request fell
   through to WhiteNoise inside the Python process.

3. **Health endpoints returned 301 with an empty body.** `SECURE_SSL_REDIRECT` applies to
   internal probes, which have no `X-Forwarded-Proto`. Fixed with `SECURE_REDIRECT_EXEMPT`.

4. **`PROMETHEUS_MULTIPROC_DIR` could break every entrypoint.** prometheus_client opens
   its mmap files at import, and the module is imported through the URLconf — so a missing
   directory would crash `manage.py migrate`, which is exactly what Fly runs as its
   `release_command` before any web process exists. The directory is now created in the
   image and defensively at import, with a fallback to single-process metrics.

5. **Per-worker metric files were never retired.** Added the `child_exit` hook, and
   explicit `multiprocess_mode` on both gauges so worker restarts stop stranding series.

6. **256MB was not enough for three gunicorn workers.** Raised to 512MB; the OOM killer
   would have reaped workers under load.

Then found by actually running the full stack:

7. **The tmpfs mount masked the metrics directory.** A bare `tmpfs: - /tmp/prometheus`
   is created root-owned and shadows the directory the image chowned to the app user, so
   every metric write failed with EACCES. Mounted `mode=1777`, and the import-time guard
   now probes for writability rather than mere existence — existing and writable are not
   the same thing.

8. **A YAML folded scalar broke the compose command.** In `>` blocks, lines indented
   deeper than the first are kept literal, so a neatly wrapped gunicorn invocation
   retained its newlines and `sh` tried to run `--bind` as a command. Collapsed to one
   line; the flags belong in `gunicorn.conf.py` anyway.

9. **Every container healthcheck failed behind a corporate proxy.** Some Docker daemons
   inject `HTTP_PROXY` into all containers, and busybox `wget` ignores `NO_PROXY`, so a
   loopback probe was routed to the proxy and returned 503. The services were fine; the
   checks were lying. Added `--proxy=off` / `--noproxy '*'`.

10. **Prometheus was scraping the frontend's JSON health endpoint.** nginx serving a
    static export has no exposition endpoint, so the target sat permanently down with
    "unsupported Content-Type". Removed — the blackbox `uptime` job already measures the
    static site from outside, which is the right vantage point for it.

11. **The latency SLI silently matched nothing.** prometheus_client serialises the bucket
    boundary as `le="1.0"`, and Prometheus does not normalise the label when matching, so
    `le="1"` returned no data — a latency objective that quietly evaluates to nothing.
    Now matched with a regex.

12. **Healthy services rendered as blank panels.** An empty `5xx` selector makes the whole
    division return no data rather than zero, so a service with no errors looked broken.
    Added `or vector(0)` to the error-ratio and cost rules.
