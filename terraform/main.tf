# SurveyHub infrastructure.
#
# Everything the application runs on, declared once and applied per environment:
#
#   Neon        serverless Postgres, one branch per environment
#   Fly.io      the Django API, scale-to-zero
#   Cloudflare  Pages project serving the static frontend export
#
# The application image itself is built and deployed by GitHub Actions, not here.
# Terraform owns the infrastructure; CD owns the release. Mixing the two means every
# code deploy needs cloud credentials and a plan, which is slow and over-privileged.

locals {
  name = "${var.project}-${var.environment}"

  common_tags = {
    project     = var.project
    environment = var.environment
    managed_by  = "terraform"
  }

  # Production keeps a machine warm; everything else scales to zero and accepts the
  # cold start in exchange for costing nothing while idle.
  min_machines = var.environment == "production" ? 1 : 0
}

# ------------------------------------------------------------------------ database

resource "neon_project" "this" {
  name      = local.name
  region_id = var.neon_region

  # Suspend quickly off-production. Every second of idle compute is billed.
  history_retention_seconds = var.environment == "production" ? 604800 : 86400

  branch {
    name          = var.environment
    database_name = "surveyhub"
    role_name     = "surveyhub"
  }
}

# ----------------------------------------------------------------------- api (fly)

resource "fly_app" "api" {
  name = "${local.name}-api"
  org  = var.fly_org
}

resource "fly_ip" "api_v4" {
  app        = fly_app.api.name
  type       = "v4"
  depends_on = [fly_app.api]
}

resource "fly_ip" "api_v6" {
  app        = fly_app.api.name
  type       = "v6"
  depends_on = [fly_app.api]
}

resource "random_password" "django_secret_key" {
  length  = 64
  special = true
  # Django's SECRET_KEY is used in HMAC signing; quoting hazards in shell and TOML
  # cause more outages than the extra entropy is worth.
  override_special = "!@#%^&*(-_=+)"
}

resource "fly_machine" "api" {
  count = var.api_machine_count

  app    = fly_app.api.name
  region = var.fly_region
  name   = "${local.name}-api-${count.index}"
  image  = var.api_image

  cpus     = var.api_cpus
  memorymb = var.api_memory_mb

  services = [{
    ports = [
      { port = 443, handlers = ["tls", "http"] },
      { port = 80, handlers = ["http"] },
    ]
    protocol     = "tcp"
    internal_port = 8000
  }]

  env = {
    PORT             = "8000"
    ENVIRONMENT      = var.environment
    DEBUG            = "False"
    ALLOWED_HOSTS    = "${local.name}-api.fly.dev"
    FRONTEND_URL     = "https://${var.pages_project}.pages.dev"
    GUNICORN_WORKERS = tostring(var.gunicorn_workers)
    LOG_LEVEL        = var.environment == "production" ? "INFO" : "DEBUG"
  }

  # Secrets are intentionally absent. `flyctl secrets set` writes them into Fly's own
  # encrypted store; putting them in env here would persist them in Terraform state
  # in plaintext. See PLATFORM.md for the bootstrap command.

  depends_on = [fly_app.api]

  lifecycle {
    # CD rolls new images out; Terraform must not fight it and revert to the pinned tag.
    ignore_changes = [image]
  }
}

# ------------------------------------------------------------------ frontend pages

resource "cloudflare_pages_project" "frontend" {
  account_id        = var.cloudflare_account_id
  name              = var.pages_project
  production_branch = "main"

  build_config {
    build_command       = "npm run build"
    destination_dir     = "out"
    root_dir            = "surveyhub-frontend"
    build_caching       = true
  }

  deployment_configs {
    production {
      environment_variables = {
        # Baked into the bundle at build time; a static export cannot read this later.
        NEXT_PUBLIC_API_URL   = "https://${local.name}-api.fly.dev"
        NEXT_TELEMETRY_DISABLED = "1"
      }
      compatibility_date = "2025-01-01"
    }

    preview {
      environment_variables = {
        NEXT_PUBLIC_API_URL     = "https://${var.project}-staging-api.fly.dev"
        NEXT_TELEMETRY_DISABLED = "1"
      }
      compatibility_date = "2025-01-01"
    }
  }
}
