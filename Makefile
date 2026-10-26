SHELL := /bin/bash
ENV   ?= envs/dev

.PHONY: help fmt check plan up down verify tailscale-cleanup

help:
	@grep -E '^[a-z]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/ -/'

fmt: ## format all Terraform
	terraform fmt -recursive

check: ## fmt check, validate, tflint, checkov
	terraform fmt -check -recursive
	@for d in bootstrap envs/persistent envs/dev; do \
	  terraform -chdir=$$d init -backend=false -input=false >/dev/null && \
	  terraform -chdir=$$d validate || exit 1; \
	done
	tflint --init >/dev/null && tflint --recursive
	checkov --config-file .checkov.yaml -d .

plan: ## terraform plan for $(ENV) (envs/dev or envs/persistent)
	terraform -chdir=$(ENV) init -input=false
	terraform -chdir=$(ENV) plan -input=false

# up/down are for humans only (see CLAUDE.md) and only touch envs/dev (network + GKE).
# envs/persistent (KMS, registry, DNS, budget) is applied by CI on merge to main.
up: ## build the destroyable platform (human only)
	./scripts/precheck.sh
	@./scripts/tailscale-cleanup.sh --delete || echo "tailscale-cleanup failed: stale devices may remain (docs/tailscale.md)"
	terraform -chdir=$(ENV) init -input=false
	terraform -chdir=$(ENV) apply
	./scripts/bootstrap-secrets.sh
	./scripts/verify.sh

down: ## tear down network + GKE and deregister the cluster's Tailscale devices (human only)
	terraform -chdir=$(ENV) destroy
	@./scripts/tailscale-cleanup.sh --delete || echo "tailscale-cleanup failed: delete the stale devices by hand (docs/tailscale.md)"

tailscale-cleanup: ## list stale cluster devices in the tailnet (DELETE=1 removes them)
	./scripts/tailscale-cleanup.sh $(if $(DELETE),--delete,)

verify: ## post-build checks
	./scripts/verify.sh
