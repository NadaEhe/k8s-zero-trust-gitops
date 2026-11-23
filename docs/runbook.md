# Runbook

What to do when an alert fires or something looks wrong. Each alert's `runbook_url` points here.

## General triage

```bash
kubectl -n argocd get applications                 # is Git in sync with the cluster?
kubectl -n taskapi-prod get pods,deploy,hpa,pdb    # replicas, restarts, autoscaling
kubectl -n taskapi-prod get events --sort-by=.lastTimestamp | tail -20
kubectl -n taskapi-prod logs deploy/taskapi --tail=50
hubble observe -P --namespace taskapi-prod --verdict DROPPED --verdict DENIED
```

## TaskApiDown

**Meaning**: Prometheus cannot scrape any API pod for 2 minutes.

1. `kubectl -n <ns> get pods -l app.kubernetes.io/component=api`
   - `ImagePullBackOff`: the tag in `environments/<env>/values.yaml` does not exist in GHCR (or the package is private). Fix the tag in Git or `git revert` the deploy commit.
   - `CrashLoopBackOff`: `kubectl logs --previous` to see the crash.
   - `Pending`: `kubectl describe pod`, usually not enough CPU/memory on the nodes.
2. Pods Running but target down: the network policy may block Prometheus. Check `hubble observe -P --to-namespace <ns> --to-port 9090`. The Prometheus pod must carry `app.kubernetes.io/name=prometheus` in namespace `monitoring`.

## TaskApiHighErrorRate

**Meaning**: more than 5% (dev) / 1% (prod) of requests return 5xx for 5 minutes.

1. Grafana → *TaskAPI - Overview*: which route, since when? Did it start with a deploy (Argo CD history)?
2. Database: `kubectl -n <ns> get pods -l app.kubernetes.io/component=database`, then `kubectl -n <ns> logs statefulset/taskapi-postgresql`.
3. Recent deploy? Roll back with `git revert <deploy commit>`; Argo CD applies it.

## TaskApiHighLatencyP95

1. Is the HPA at `maxReplicas`? `kubectl -n taskapi-prod get hpa`. If so, raise `maxReplicas` or the CPU request in Git.
2. CPU throttling or memory pressure: `kubectl top pods -n <ns>`.
3. Slow database: check PostgreSQL CPU and connection count (`DB_POOL_MAX`).

## A request returns `403 Access denied`

This comes from **Cilium's Envoy proxy**, not from the application: the method/path is not in `networkPolicy.allowedHttp` of the chart. Confirm with:

```bash
hubble observe -P --namespace taskapi-dev --protocol http --verdict DENIED
```

If the new endpoint is legitimate, add it to the allow-list in `charts/taskapi/values.yaml` (reviewed in a PR like any other change).

## A connection times out between two pods

Most likely a missing allow rule (default-deny). Find the dropped flow:

```bash
hubble observe -P --verdict DROPPED --from-namespace <src-ns> --to-namespace <dst-ns>
```

## Argo CD application is OutOfSync / Degraded

- **OutOfSync** with `selfHeal`: someone changed the cluster manually; Argo CD reverts it at the next reconciliation.
- **Degraded**: open the app in the Argo CD UI, the failing resource is red; usually a pod that is not Ready (see TaskApiDown).
- **ComparisonError** on Helm charts: run `make lint` locally to reproduce the render error.

## Rebuild everything from scratch

The cluster is disposable, Git holds the desired state:

```bash
make down && make up
```

(Data in PostgreSQL is lost: this lab has no backups, see docs/decisions.md §9.)
