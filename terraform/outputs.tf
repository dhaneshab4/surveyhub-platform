output "api_url" {
  description = "Base URL of the deployed API."
  value       = "https://${fly_app.api.name}.fly.dev"
}

output "frontend_url" {
  description = "Base URL of the deployed frontend."
  value       = "https://${cloudflare_pages_project.frontend.subdomain}"
}

output "api_app_name" {
  description = "Fly app name, for flyctl commands and CD."
  value       = fly_app.api.name
}

output "database_host" {
  description = "Neon endpoint host."
  value       = neon_project.this.database_host
  sensitive   = true
}

output "database_url" {
  description = "Connection string. Feed this to `flyctl secrets set DATABASE_URL=...` rather than into the machine env, so it stays out of Terraform-managed config."
  value       = neon_project.this.connection_uri
  sensitive   = true
}

output "bootstrap_secrets_command" {
  description = "Run this once per environment after the first apply."
  value       = <<-EOT
    flyctl secrets set \
      SECRET_KEY='${random_password.django_secret_key.result}' \
      DATABASE_URL='<terraform output -raw database_url>' \
      GEMINI_API_KEY='<your key>' \
      --app ${fly_app.api.name}
  EOT
  sensitive   = true
}
