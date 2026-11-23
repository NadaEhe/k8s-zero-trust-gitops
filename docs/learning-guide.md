# Learning guide: understand this project piece by piece

Read the files in this order. Each step lists what to look at, what to run, and the questions an interviewer is likely to ask about it.

## Step 1: The application and its container
- Files: `app/src/taskapi/*.py`, `app/Dockerfile`, `docker-compose.yml`
- Run: `docker compose up --build`, open http://localhost:8000/api/docs
- Understand: liveness vs readiness (`/healthz` vs `/readyz`), why metrics are on port 9090, multi-stage build, non-root user.
- Questions: *Why must the liveness probe not check the database? Why a multi-stage Dockerfile? Why a fixed numeric UID?*

## Step 2: Kubernetes objects through the Helm chart
- Files: `charts/taskapi/templates/deployment.yaml`, `service.yaml`, `postgresql.yaml`, `availability.yaml`
- Run: `helm template taskapi charts/taskapi -f environments/dev/values.yaml | less`
- Understand: Deployment vs StatefulSet, Service and label selectors, PVC templates, HPA, PodDisruptionBudget, rolling update settings, probes, `securityContext`.
- Questions: *Deployment vs StatefulSet? What happens to a pod's data when it restarts? What does `maxUnavailable: 0` guarantee? What is a PDB for?*

## Step 3: The cluster and Cilium
- Files: `cluster/kind-config.yaml`, `cluster/cilium-values.yaml`, `scripts/bootstrap.sh`
- Run: `make up`, then `kubectl get nodes`, `kubectl -n kube-system get pods`, `cilium status`
- Understand: what a CNI does, why nodes are `NotReady` before Cilium, what kube-proxy does and how eBPF replaces it.
- Questions: *What is a CNI? What does kube-proxy do? Why eBPF?*

## Step 4: Gateway API
- Files: `gitops/platform/gateway/*.yaml`, `charts/taskapi/templates/httproute.yaml`
- Run: `kubectl get gateway,httproute -A`, `curl -H 'Host: taskapi-dev.localtest.me' 127.0.0.1:8080/api/info`
- Understand: GatewayClass / Gateway / HTTPRoute, who owns what, `allowedRoutes`.
- Questions: *Ingress vs Gateway API? Why was ingress-nginx retired?*

## Step 5: Zero-trust network policies
- Files: `charts/taskapi/templates/networkpolicies.yaml`, `scripts/policy-test.sh`
- Run: `make test`, `make hubble-denied` in a second terminal, then `curl -X PUT ...`
- Understand: default deny, additive allow rules, identities and entities (`ingress`, `host`), L7 HTTP rules, DNS rules.
- Questions: *How do you debug a connection that times out? Difference between a NetworkPolicy and a CiliumNetworkPolicy? What is lateral movement?*

## Step 6: GitOps with Argo CD
- Files: `gitops/root.yaml`, `gitops/apps/*.yaml`, `bootstrap/argocd/*`
- Run: open the Argo CD UI, change `replicaCount` in Git, watch the sync; `kubectl scale` manually and watch self-heal.
- Understand: app of apps, sync waves, `prune`, `selfHeal`, AppProjects, pull vs push deployment.
- Questions: *Why GitOps? How do you roll back? How does Argo CD detect a change? Push vs pull CD?*

## Step 7: CI/CD
- Files: `.github/workflows/*.yml`, `.github/dependabot.yml`
- Run: open a PR with a small change and watch the checks.
- Understand: job dependencies, permissions, the GitOps commit, promotion, SHA pinning.
- Questions: *How does a commit reach production? Why pin actions by SHA? Why is CI not allowed to `kubectl apply`?*

## Step 8: Observability
- Files: `charts/taskapi/templates/monitoring.yaml`, `gitops/apps/30-monitoring.yaml`, `gitops/platform/dashboards/`
- Run: `make load`, then watch Grafana and `kubectl -n taskapi-prod get hpa -w`.
- Understand: ServiceMonitor, PromQL `rate()`, histograms and percentiles, alert `for:` duration, label cardinality.
- Questions: *What are the four golden signals? Why not put the raw URL path in a metric label?*
