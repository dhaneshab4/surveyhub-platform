.DEFAULT_GOAL := help
SHELL := /bin/bash
COMPOSE := docker compose -f docker-compose.yml
COMPOSE_OBS := $(COMPOSE) -f docker-compose.observability.yml
BACKEND := surveyhubbackend
FRONTEND := surveyhub-frontend

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ------------------------------------------------------------------------ local

.PHONY: up
up: ## Start the app plus Prometheus and Grafana
	$(COMPOSE_OBS) up -d --build
	@echo
	@echo "  app         http://localhost:3000"
	@echo "  api         http://localhost:8000"
	@echo "  metrics     http://localhost:8000/metrics"
	@echo "  prometheus  http://localhost:9090"
	@echo "  grafana     http://localhost:3001"

.PHONY: app
app: ## Start just the application stack
	$(COMPOSE) up -d --build

.PHONY: down
down: ## Stop everything
	$(COMPOSE_OBS) down

.PHONY: clean
clean: ## Stop everything and delete volumes
	$(COMPOSE_OBS) down -v

.PHONY: logs
logs: ## Tail application logs
	$(COMPOSE) logs -f backend frontend

.PHONY: ps
ps: ## Show container status and health
	@$(COMPOSE_OBS) ps

# ------------------------------------------------------------------------ checks

.PHONY: test
test: ## Run the backend test suite
	cd $(BACKEND) && python manage.py test surveys -v 2

.PHONY: lint
lint: ## Lint backend and frontend
	cd $(BACKEND) && ruff check .
	cd $(FRONTEND) && npm run lint

.PHONY: policy
policy: ## Run the conftest container and compose policies
	conftest test --policy policy/ --parser dockerfile \
		$(BACKEND)/Dockerfile $(FRONTEND)/Dockerfile
	conftest test --policy policy/ docker-compose.yml

.PHONY: hadolint
hadolint: ## Lint both Dockerfiles
	docker run --rm -i hadolint/hadolint < $(BACKEND)/Dockerfile
	docker run --rm -i hadolint/hadolint < $(FRONTEND)/Dockerfile

.PHONY: scan
scan: ## Trivy scan of the repo and both images
	trivy fs --scanners vuln,secret,misconfig --severity HIGH,CRITICAL .
	trivy image --severity HIGH,CRITICAL --ignore-unfixed surveyhub-backend:local || true

.PHONY: smoke
smoke: ## Smoke test a deployment: make smoke URL=https://...
	@bash .github/scripts/smoke.sh $(or $(URL),http://localhost:8000)

.PHONY: verify
verify: lint test policy ## Everything CI runs, locally

# --------------------------------------------------------------------- terraform

.PHONY: tf-init
tf-init: ## terraform init with the remote backend
	cd terraform && terraform init -backend-config=backend.hcl

.PHONY: tf-plan
tf-plan: ## Plan an environment: make tf-plan ENV=staging
	cd terraform && terraform plan -var-file=environments/$(or $(ENV),staging).tfvars

.PHONY: tf-apply
tf-apply: ## Apply an environment: make tf-apply ENV=staging
	cd terraform && terraform apply -var-file=environments/$(or $(ENV),staging).tfvars

.PHONY: tf-fmt
tf-fmt: ## Format and validate terraform
	cd terraform && terraform fmt -recursive && terraform validate

# ------------------------------------------------------------------------ deploy

.PHONY: deploy-staging
deploy-staging: ## Deploy the API to staging
	cd $(BACKEND) && flyctl deploy --remote-only \
		--app surveyhub-api-staging --config fly.staging.toml
	@bash .github/scripts/smoke.sh https://surveyhub-api-staging.fly.dev

.PHONY: load
load: ## Fire synthetic traffic so the dashboard has something to show
	@command -v hey >/dev/null || { echo "install hey: brew install hey"; exit 1; }
	hey -z 60s -c 10 http://localhost:8000/healthz
	hey -z 30s -c 5  http://localhost:8000/api/surveys/
	@echo "check http://localhost:3001"
