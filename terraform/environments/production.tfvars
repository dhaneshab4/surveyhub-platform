environment = "production"
fly_region  = "lhr"
neon_region = "aws-eu-west-2"

# Two machines is the floor for a genuinely zero-downtime rolling deploy: with one,
# `strategy = "rolling"` still has a window where nothing is serving.
api_machine_count = 2
api_cpus          = 1
api_memory_mb     = 512
gunicorn_workers  = 3
pages_project     = "surveyhub"

# Credentials come from TF_VAR_* in CI. Never put them here.
