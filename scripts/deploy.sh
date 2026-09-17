#!/usr/bin/env bash
# Deploys the full demo against whatever cluster your current kubeconfig
# context points at: self-hosted Supabase (via the community Operator) +
# kube-prometheus-stack (Prometheus + Grafana) + the postgres_exporter wiring
# in manifests/. See README.md for the walkthrough version of these same
# steps, with explanations.
set -euo pipefail

command -v kubectl >/dev/null || { echo "kubectl is required" >&2; exit 1; }
command -v helm >/dev/null || { echo "helm is required" >&2; exit 1; }

echo "==> Using kubeconfig context: $(kubectl config current-context)"
read -r -p "Continue deploying into this cluster? [y/N] " confirm
[[ "$confirm" == "y" || "$confirm" == "Y" ]] || exit 1

echo "==> Adding Helm repositories"
helm repo add supabase https://supabase-community.github.io/supabase-kubernetes
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

echo "==> Installing the Supabase Operator (namespace: supabase-operator)"
helm upgrade --install supabase-operator supabase/supabase-operator \
  --namespace supabase-operator \
  --create-namespace \
  --wait

echo "==> Deploying a self-hosted Supabase project (namespace: monitoring)"
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install supabase supabase/supabase-project \
  --namespace monitoring \
  --set fullnameOverride=supabase \
  --set project.publicUrl=http://localhost:8000 \
  --wait

echo "==> Installing kube-prometheus-stack (Prometheus + Grafana)"
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values values/kube-prometheus-stack-values.yaml \
  --wait

echo "==> Wiring up postgres_exporter, the ServiceMonitor, alert rules, and the dashboard"
kubectl apply -f manifests/postgres-exporter/
kubectl apply -f manifests/prometheus/
kubectl apply -f manifests/grafana/

cat <<'EOF'

==> Done. Next steps:

  # Grafana (admin / watching-postgres-oss)
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

  # Supabase Studio
  kubectl -n monitoring port-forward svc/supabase-envoy 8000:8000

  # Supabase credentials
  kubectl -n monitoring get secrets supabase-postgres-auth supabase-envoy-auth supabase-jwt \
    -o go-template='{{range .items}}{{if eq .metadata.name "supabase-postgres-auth"}}{{printf "%-18s: %s" "Database Password" (.data.password | base64decode)}}{{"\n"}}{{end}}{{if eq .metadata.name "supabase-envoy-auth"}}{{printf "%-18s: %s" "Studio Username" (.data.username | base64decode)}}{{"\n"}}{{printf "%-18s: %s" "Studio Password" (.data.password | base64decode)}}{{"\n"}}{{end}}{{end}}'

EOF
