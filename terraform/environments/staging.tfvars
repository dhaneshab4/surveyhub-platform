environment       = "staging"
fly_region        = "lhr"
neon_region       = "aws-eu-west-2"
api_machine_count = 1
api_cpus          = 1
api_memory_mb     = 512
gunicorn_workers  = 2
pages_project     = "surveyhub-staging"

# Credentials come from TF_VAR_fly_api_token, TF_VAR_neon_api_key,
# TF_VAR_cloudflare_api_token and TF_VAR_cloudflare_account_id. Never put them here.
