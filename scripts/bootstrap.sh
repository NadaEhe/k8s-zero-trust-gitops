#!/usr/bin/env bash
# =============================================================================
# Bootstrap the local platform, from nothing to "Argo CD manages everything".
#
#   1. kind cluster (no CNI, no kube-proxy)
#   2. Namespaces (Pod Security "restricted", Gateway access labels)
#   3. CRDs needed BEFORE anything else (Gateway API, Prometheus Operator)
#   4. Cilium: networking, kube-proxy replacement, Gateway API, Hubble
#   5. Secrets (random passwords, never stored in Git)
#   6. Argo CD + the root "app of apps"  -> from here on, Git drives the cluster
#
# Steps 1-6 are the only imperative part. They are idempotent: re-running the
# script is safe.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/versions.env
source "${ROOT_DIR}/scripts/versions.env"

SKIP_CLUSTER="${SKIP_CLUSTER:-false}"   # CI creates the cluster itself
SKIP_ARGOCD="${SKIP_ARGOCD:-false}"     # CI tests the chart without Argo CD

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m    ✔ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is not installed. See README > Prerequisites."
}

random_password() {
  # 24 alphanumeric characters, from the kernel's random generator.
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true
}

create_secret_once() {
  # Only create the Secret if it does not exist yet: regenerating a database
  # password would lock the app out of an already initialised PostgreSQL.
  local ns="$1" name="$2"; shift 2
  if kubectl -n "$ns" get secret "$name" >/dev/null 2>&1; then
    ok "secret $ns/$name already exists (kept)"
  else
    kubectl -n "$ns" create secret generic "$name" "$@" >/dev/null
    ok "secret $ns/$name created"
  fi
}

# --- 0. prerequisites ---------------------------------------------------------
log "Checking prerequisites"
for tool in docker kubectl helm; do require "$tool"; done
[[ "$SKIP_CLUSTER" == "true" ]] || require kind
docker info >/dev/null 2>&1 || die "Docker is not running."
ok "docker, kubectl, helm found"

# --- 1. cluster -----------------------------------------------------------------
if [[ "$SKIP_CLUSTER" != "true" ]]; then
  log "Creating kind cluster '${CLUSTER_NAME}'"
  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    ok "cluster already exists"
  else
    kind create cluster --config "${ROOT_DIR}/cluster/kind-config.yaml" --wait 0s
  fi
  kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
fi

# --- 2. namespaces ----------------------------------------------------------------
log "Creating namespaces"
kubectl apply -f "${ROOT_DIR}/bootstrap/namespaces.yaml"
# kube-system hosts the Hubble UI, which we expose through the Gateway.
kubectl label namespace kube-system shared-gateway-access=true --overwrite >/dev/null

# --- 3. CRDs ----------------------------------------------------------------------
log "Installing Gateway API CRDs ${GATEWAY_API_VERSION} (standard channel)"
GW_BASE="https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GATEWAY_API_VERSION}/config/crd/standard"
for crd in gatewayclasses gateways httproutes referencegrants grpcroutes backendtlspolicies tlsroutes; do
  kubectl apply --server-side -f "${GW_BASE}/gateway.networking.k8s.io_${crd}.yaml" >/dev/null
done
ok "Gateway API CRDs installed"

log "Installing Prometheus Operator CRDs (ServiceMonitor, PrometheusRule...)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm upgrade --install prometheus-operator-crds prometheus-community/prometheus-operator-crds \
  --version "${PROMETHEUS_OPERATOR_CRDS_VERSION}" --namespace kube-system --wait >/dev/null
ok "Prometheus Operator CRDs installed"

# --- 4. Cilium --------------------------------------------------------------------
log "Installing Cilium ${CILIUM_VERSION} (this takes 1-3 minutes)"
helm repo add cilium https://helm.cilium.io --force-update >/dev/null
API_SERVER_HOST="${API_SERVER_HOST:-${CLUSTER_NAME}-control-plane}"
helm upgrade --install cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace kube-system \
  --values "${ROOT_DIR}/cluster/cilium-values.yaml" \
  --set k8sServiceHost="${API_SERVER_HOST}" \
  --set k8sServicePort=6443 \
  --wait --timeout 10m
kubectl wait --for=condition=Ready nodes --all --timeout=5m >/dev/null
ok "Cilium is running, all nodes are Ready"

# --- 5. secrets -------------------------------------------------------------------
log "Creating secrets (random passwords)"
for ns in taskapi-dev taskapi-prod; do
  create_secret_once "$ns" taskapi-db --from-literal=password="$(random_password)"
done
create_secret_once monitoring grafana-admin \
  --from-literal=admin-user=admin --from-literal=admin-password="$(random_password)"

# --- 6. Argo CD -------------------------------------------------------------------
if [[ "$SKIP_ARGOCD" != "true" ]]; then
  log "Installing Argo CD ${ARGOCD_VERSION}"
  kubectl apply -k "${ROOT_DIR}/bootstrap/argocd" --server-side --force-conflicts >/dev/null
  kubectl -n argocd rollout status deploy/argocd-server --timeout=5m >/dev/null
  kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=5m >/dev/null
  kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=5m >/dev/null
  # Pick up the patched config (insecure mode, health checks).
  kubectl -n argocd rollout restart deploy/argocd-server >/dev/null
  ok "Argo CD is running"

  log "Handing over to GitOps: applying the root application"
  kubectl apply -f "${ROOT_DIR}/gitops/root.yaml"
  ok "Argo CD now syncs everything under gitops/apps/ from GitHub"

  cat <<EOF

$(printf '\033[1;32m')Platform is bootstrapping. Argo CD needs ~3-5 minutes to sync every app.$(printf '\033[0m')
Follow it:   kubectl -n argocd get applications -w

  Argo CD   http://argocd.localtest.me:8080     user: admin   password: make passwords
  Grafana   http://grafana.localtest.me:8080    user: admin   password: make passwords
  Hubble    http://hubble.localtest.me:8080
  API dev   http://taskapi-dev.localtest.me:8080/api/docs
  API prod  http://taskapi.localtest.me:8080/api/docs

Then run:   make test      (end-to-end + zero-trust checks)
EOF
fi
