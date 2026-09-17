# watching-postgres-oss

Demo code for a Grafana OSS Community lightning talk: **monitoring a
self-hosted (OSS) Supabase instance with a self-hosted (OSS) Grafana stack**,
end to end, deployable to any Kubernetes cluster.

Supabase and Grafana Cloud are both great products to pay for. This repo is
the other side of that coin: everything here is open source, runs on a
cluster you already have, and every dashboard/alert/scrape config is a file
you can put in a pull request instead of a click you have to remember you
made.

## What this deploys

| Piece | What it is | Where it comes from |
|---|---|---|
| Self-hosted Supabase | Postgres + Auth + Realtime + Storage + Studio, etc. | [`supabase-community/supabase-kubernetes`](https://github.com/supabase-community/supabase-kubernetes) Operator |
| Prometheus + Grafana | Metrics storage, dashboards, alerting | [`prometheus-community/kube-prometheus-stack`](https://github.com/prometheus-community/helm-charts) |
| `postgres_exporter` | Reads Supabase's own Postgres and republishes it as Prometheus metrics | [`prometheus-community/postgres_exporter`](https://github.com/prometheus-community/postgres_exporter), wired to the Supabase operator's generated Postgres Secret |
| A `ServiceMonitor` + `PrometheusRule` + dashboard `ConfigMap` | Tells Prometheus to scrape the exporter, alerts on 4 conditions, and a starter Grafana dashboard | `manifests/` in this repo |

Every piece is a plain Kubernetes manifest or Helm values file, checked into
`manifests/` and `values/` in this repo — nothing here is a black box.

## Prerequisites

- A Kubernetes cluster (1.28+) and a `kubectl` context pointed at it
- `helm` 3.x+
- Cluster capacity: this is a real (if minimal) Supabase deployment — plan
  for a few GB of RAM and a couple of `ReadWriteOnce` PVCs

## Deploy

Either run the whole thing:

```bash
./scripts/deploy.sh
```

...or walk through it step by step:

```bash
helm repo add supabase https://supabase-community.github.io/supabase-kubernetes
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# 1. The Supabase Operator (installs its CRDs + controller)
helm install supabase-operator supabase/supabase-operator \
  --namespace supabase-operator --create-namespace --wait

# 2. A self-hosted Supabase project — Postgres, Auth, Realtime, Storage, Studio...
kubectl create namespace monitoring
helm install supabase supabase/supabase-project \
  --namespace monitoring \
  --set fullnameOverride=supabase \
  --set project.publicUrl=http://localhost:8000 \
  --wait

# 3. Prometheus + Grafana
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values values/kube-prometheus-stack-values.yaml \
  --wait

# 4. postgres_exporter, wired to the Postgres Secret the Operator just created,
#    plus the ServiceMonitor, alert rules, and dashboard that use it
kubectl apply -f manifests/postgres-exporter/
kubectl apply -f manifests/prometheus/
kubectl apply -f manifests/grafana/
```

## Look at it

```bash
# Grafana — admin / watching-postgres-oss (see values/kube-prometheus-stack-values.yaml)
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# → http://localhost:3000 → Dashboards → "Watching Postgres (OSS)"

# Supabase Studio
kubectl -n monitoring port-forward svc/supabase-envoy 8000:8000
# → http://localhost:8000
```

## How the pieces actually connect

The Supabase Operator's `supabase-project` chart creates a `SingleDatabase`
resource, which the Operator turns into a Postgres `StatefulSet` + `Service`
(`supabase-postgres`) + credentials `Secret` (`supabase-postgres-auth`,
user `supabase_admin`). `manifests/postgres-exporter/deployment.yaml` points
straight at that Service and reads the password straight out of that Secret
— there's no separate database user to provision and no connection string to
hand-assemble.

`--auto-discover-databases` (in that same Deployment) is the flag that makes
the exporter see every database on the instance, not just the first one it's
told about — which matters here because a self-hosted Supabase instance is
exactly the "one Postgres server, several databases" shape that flag exists
for.

If you want to go deeper on that specific flag: I've spent the last few
weeks in `postgres_exporter`'s implementation of it, fixing a bug where
multi-database instances only ever got metrics for the first database.
Still open as
[`prometheus-community/postgres_exporter#1378`](https://github.com/prometheus-community/postgres_exporter/pull/1378).

## Tearing it down

```bash
helm uninstall kube-prometheus-stack supabase -n monitoring
helm uninstall supabase-operator -n supabase-operator
kubectl delete namespace monitoring supabase-operator
```

This does not attempt to reclaim `PersistentVolume`s your storage class
provisioned dynamically — check `kubectl get pv` afterward if you want those
back too.
