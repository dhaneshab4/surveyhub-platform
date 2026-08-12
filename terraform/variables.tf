variable "project" {
  description = "Project slug used to name every resource."
  type        = string
  default     = "surveyhub"
}

variable "environment" {
  description = "Deployment environment."
  type        = string

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be one of: staging, production."
  }
}

# ------------------------------------------------------------------- credentials
# Supplied by TF_VAR_* in CI, never committed. Marked sensitive so they are redacted
# from plan output and the CI log.

variable "fly_api_token" {
  description = "Fly.io API token."
  type        = string
  sensitive   = true
}

variable "neon_api_key" {
  description = "Neon API key."
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Pages:Edit."
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account id."
  type        = string
  sensitive   = true
}

# ------------------------------------------------------------------------ placement

variable "fly_org" {
  description = "Fly.io organisation slug."
  type        = string
  default     = "personal"
}

variable "fly_region" {
  description = "Fly region. Keep this near your users and near the database."
  type        = string
  default     = "lhr" # London — lowest latency to Dublin of the free-tier regions
}

variable "neon_region" {
  description = "Neon region id. Cross-region round trips dominate request latency, so this should match fly_region."
  type        = string
  default     = "aws-eu-west-2"
}

# ---------------------------------------------------------------------- api sizing

variable "api_image" {
  description = "Container image for the API. CD overwrites this on deploy; the value here is only the bootstrap tag."
  type        = string
  default     = "ghcr.io/dhaneshab4/surveyhub/backend:latest"
}

variable "api_machine_count" {
  description = "Number of API machines. Two is the minimum for a zero-downtime rolling deploy."
  type        = number
  default     = 1
}

variable "api_cpus" {
  description = "vCPUs per API machine."
  type        = number
  default     = 1
}

variable "api_memory_mb" {
  description = "Memory per API machine. Gunicorn with 3 workers needs roughly 90MB per worker under load."
  type        = number
  default     = 512
}

variable "gunicorn_workers" {
  description = "Gunicorn worker processes. Rule of thumb is (2 x cores) + 1, capped by available memory."
  type        = number
  default     = 3
}

# ------------------------------------------------------------------------ frontend

variable "pages_project" {
  description = "Cloudflare Pages project name."
  type        = string
  default     = "surveyhub"
}
