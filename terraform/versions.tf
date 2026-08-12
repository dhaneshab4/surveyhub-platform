terraform {
  required_version = ">= 1.6.0"

  required_providers {
    # Fly has no first-party provider. This community one covers apps, machines,
    # volumes and certificates, which is everything this stack needs. Pinned tightly
    # because community providers move without much ceremony.
    fly = {
      source  = "fly-apps/fly"
      version = "~> 0.0.23"
    }
    neon = {
      source  = "kislerdm/neon"
      version = "~> 0.6"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.40"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Remote state. Local state is fine for one engineer on one laptop and a disaster the
  # moment CI also needs to plan. Cloudflare R2 speaks the S3 API and has a free tier.
  #
  # Bootstrap with:
  #   terraform init -backend-config=backend.hcl
  backend "s3" {
    key                         = "surveyhub/terraform.tfstate"
    region                      = "auto"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_path_style              = true
  }
}

provider "fly" {
  fly_api_token = var.fly_api_token
}

provider "neon" {
  api_key = var.neon_api_key
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
