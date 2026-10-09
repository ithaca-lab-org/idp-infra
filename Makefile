SHELL := /bin/bash
ENV   ?= envs/dev

.PHONY: help fmt check plan up down verify

help:
	@grep -E '^[a-z]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/ -/'

fmt: ## format all Terraform
	terraform fmt -recursive

check: ## fmt check, validate, tflint, checkov
	terraform fmt -check -recursive
	@for d in bootstrap $(ENV); do \
	  terraform -chdir=$$d init -backend=false -input=false >/dev/null && \
	  terraform -chdir=$$d validate || exit 1; \
	done
	tflint --init >/dev/null && tflint --recursive
	checkov --config-file .checkov.yaml -d .

plan: ## terraform plan for $(ENV)
	terraform -chdir=$(ENV) init -input=false
	terraform -chdir=$(ENV) plan -input=false

# up/down are for humans only (see CLAUDE.md). CI applies on merge to main.
up: ## build the platform (human only)
	terraform -chdir=$(ENV) init -input=false
	terraform -chdir=$(ENV) apply
	./scripts/verify.sh

down: ## tear down the destroyable stack (human only)
	terraform -chdir=$(ENV) destroy

verify: ## post-build checks
	./scripts/verify.sh
