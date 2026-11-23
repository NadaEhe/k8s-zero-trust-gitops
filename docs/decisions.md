# Design decisions

Short "architecture decision records": what was chosen, why, and what was traded off.

## 1. Cilium as CNI, with kube-proxy replacement

**Choice**: Cilium (eBPF) instead of kindnet/Calico/Flannel, and no kube-proxy.

**Why**
- Enforces **L3/L4 and L7 (HTTP, DNS)** policies in one tool. Calico and the standard `NetworkPolicy` API stop at L4.
- **Hubble** shows every flow with its verdict (forwarded / dropped / denied), which makes policies debuggable instead of "it times out, why?".
- eBPF service load-balancing replaces kube-proxy's iptables rules, which grow linearly with the number of services.
- It also ships a **Gateway API** implementation (Envoy), so no separate ingress controller is needed.

**Trade-off**: more moving parts than a basic CNI, and L7 policies send traffic through Envoy (small latency cost). Kubelet probes are allowed by Cilium's default "allow from local host" behaviour.

## 2. Gateway API instead of Ingress

**Choice**: a shared `Gateway` + one `HTTPRoute` per app.

**Why**
- The community `ingress-nginx` controller was retired (announced November 2025), and the Kubernetes project recommends the Gateway API as the successor of Ingress.
- Role separation: the **platform team owns the Gateway** (listeners, which namespaces may attach); **app teams own their routes**. This is enforced by `allowedRoutes` + the `shared-gateway-access` namespace label.
- Portable: the same HTTPRoute works with Cilium, Envoy Gateway, Traefik, Istio, GKE, etc.

**Trade-off**: host-network mode is used so kind needs no LoadBalancer. In a cloud cluster the Gateway would get a LoadBalancer service instead.

## 3. Argo CD, pull-based GitOps, app of apps

**Choice**: Argo CD pulls from Git. CI never runs `kubectl` or `helm` against the cluster.

**Why**
- **Security**: the cluster needs no inbound access from CI, and CI holds no cluster credentials. A leaked CI token cannot deploy anything that does not go through Git.
- **Auditability**: every change to the cluster is a commit (who, when, why, review). Rollback = `git revert`.
- **Drift correction**: `selfHeal` reverts manual changes.
- **App of apps** + **sync waves**: CRD-dependent and platform apps (wave -2/-1) are healthy before workloads (wave 1).
- **AppProjects** as guardrails: the `taskapi` project can only deploy namespaced resources into `taskapi-*`.

**Alternative considered**: Flux. Equally valid; Argo CD was chosen for its UI (useful to demo and to debug) and its wide adoption in job offers.

## 4. What is bootstrapped imperatively (and why only that)

The CNI must exist before any pod (including Argo CD) can run, and some CRDs (Gateway API, Prometheus Operator) must exist before Cilium can create its resources. So `scripts/bootstrap.sh` installs exactly: namespaces, CRDs, Cilium, secrets, Argo CD, and the root Application. Everything else is GitOps. The script is idempotent.

## 5. One chart, values per environment, image tag in Git

- `charts/taskapi` is environment-agnostic; `environments/<env>/values.yaml` holds the differences (replicas, HPA, thresholds, hostname).
- The **image tag lives in Git**. CI writes `sha-<commit>` into dev; promotion to prod copies the same tag ("build once, deploy many"). Never `latest`: a tag must identify exactly one build.

## 6. Default-deny + explicit allow-lists

- A standard `NetworkPolicy` with an empty selector denies all ingress and egress in the namespace.
- `CiliumNetworkPolicy` objects then open precise paths (see README diagram). Policies are additive allow-lists, so the result is easy to reason about.
- The **metrics port is separate** (9090) from the API port (8000): Prometheus can reach metrics, the Gateway cannot, so `/metrics` is never public.
- DNS egress is limited to `*.<namespace>.svc.cluster.local`: the API cannot resolve any external name, which also closes DNS-based data exfiltration.

## 7. Workload hardening

Pod Security Admission `restricted` is **enforced** on application namespaces, so a non-compliant pod is rejected at admission, not just reported. Containers run as fixed non-root UIDs with a read-only root filesystem (writable `emptyDir` only where needed), all capabilities dropped, and no service-account token (the API never calls the Kubernetes API).

## 8. Probes designed for failure modes

- **Liveness** (`/healthz`) never touches the database: a DB outage must not cause restart loops of healthy processes.
- **Readiness** (`/readyz`) checks the database: pods without DB access stop receiving traffic.
- **Startup probe** protects slow starts; **preStop sleep** + `maxUnavailable: 0` + **PodDisruptionBudget** give zero-downtime rollouts and node drains.

## 9. PostgreSQL as a simple StatefulSet

Good enough to demonstrate stateful workloads (stable identity, PersistentVolumeClaim templates, non-root Postgres with a read-only root filesystem). **Not** production-grade: no replication, no backups, no failover. In production: a managed service or an operator such as CloudNativePG.

## 10. Supply-chain security in CI

- All third-party actions are pinned to full commit SHAs. Tags are mutable: in March 2026 attackers force-pushed 75 of 76 tags of `aquasecurity/trivy-action` to steal CI secrets (CVE-2026-33634). SHA pins were not affected.
- Workflow tokens are read-only by default; jobs request only the permissions they need.
- Images are scanned (Trivy), and pushed with an SBOM and build provenance.
