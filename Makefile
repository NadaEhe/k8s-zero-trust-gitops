# Everything you need, one command each. Run `make help` to see them.
SHELL := /usr/bin/env bash
include scripts/versions.env
export

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# --- Platform ----------------------------------------------------------------
.PHONY: up
up: ## Create the kind cluster and bootstrap the whole platform (Cilium + Argo CD)
	@./scripts/bootstrap.sh

.PHONY: down
down: ## Delete the cluster (everything is gone, Git keeps the desired state)
	kind delete cluster --name $(CLUSTER_NAME)

.PHONY: status
status: ## Show Argo CD applications and pods
	@kubectl -n argocd get applications
	@echo; kubectl get pods -n taskapi-dev -o wide; echo; kubectl get pods -n taskapi-prod -o wide

.PHONY: passwords
passwords: ## Print the Argo CD and Grafana admin passwords
	@printf "Argo CD  admin / "; kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
	@printf "Grafana  admin / "; kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo

.PHONY: load-image
load-image: ## Build the API image locally and load it into kind (no registry needed)
	@TAG=$$(grep -E '^\s+tag:' environments/dev/values.yaml | head -1 | sed -E 's/.*"(.*)".*/\1/'); \
	echo "Building ghcr.io/nadaehe/k8s-zero-trust-gitops/taskapi:$$TAG"; \
	docker build -t ghcr.io/nadaehe/k8s-zero-trust-gitops/taskapi:$$TAG --build-arg APP_VERSION=$$TAG app && \
	kind load docker-image ghcr.io/nadaehe/k8s-zero-trust-gitops/taskapi:$$TAG --name $(CLUSTER_NAME)

# --- Tests -------------------------------------------------------------------
.PHONY: test
test: ## End-to-end tests through the Gateway + zero-trust network tests (dev)
	@./scripts/smoke-test.sh dev
	@./scripts/policy-test.sh taskapi-dev

.PHONY: test-prod
test-prod: ## Same tests against prod
	@./scripts/smoke-test.sh prod
	@./scripts/policy-test.sh taskapi-prod

.PHONY: app-test
app-test: ## Unit/integration tests of the API (needs Docker for PostgreSQL)
	docker compose up -d --wait db
	cd app && python -m pytest

.PHONY: lint
lint: ## Lint the Helm chart and render both environments
	helm lint charts/taskapi -f environments/dev/values.yaml
	helm lint charts/taskapi -f environments/prod/values.yaml
	helm template taskapi charts/taskapi -f environments/prod/values.yaml >/dev/null && echo "templates render OK"

# --- Observability shortcuts -------------------------------------------------
.PHONY: hubble
hubble: ## Live view of network flows in taskapi-dev (needs the hubble CLI)
	hubble observe -P --namespace taskapi-dev --follow

.PHONY: hubble-denied
hubble-denied: ## Show only DENIED flows (policy drops and L7 403s)
	hubble observe -P --verdict DROPPED --verdict DENIED --follow

.PHONY: load
load: ## Generate traffic for 2 minutes (watch the HPA and Grafana react)
	@echo "Sending requests to prod for 120s... (Ctrl+C to stop)"
	@end=$$((SECONDS+120)); while [ $$SECONDS -lt $$end ]; do \
	  for i in $$(seq 1 20); do curl -s -o /dev/null -H 'Host: taskapi.localtest.me' http://127.0.0.1:8080/api/tasks & done; wait; \
	done
