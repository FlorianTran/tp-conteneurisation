#!/usr/bin/env bash
# Deploiement reproductible et idempotent de la boutique sur minikube.
# Cree le namespace, les secrets (hors Git), puis applique k8s/ dans l'ordre.
set -euo pipefail

NS="boutique"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
K8S="${ROOT}/k8s"

# Credentials DB (surchageables par l'environnement). En vrai on tirerait ca
# d'un gestionnaire de secrets ; ici on garde des valeurs de dev.
DB_USER="${DB_USER:-boutique_app}"
DB_PASSWORD="${DB_PASSWORD:-boutique_dev_pwd}"
DB_NAME="${DB_NAME:-boutique}"

echo ">> namespace + PSS labels"
kubectl apply -f "${K8S}/namespace.yaml"

echo ">> secrets (crees hors Git via kubectl create secret)"
# Secret cote Postgres (variables POSTGRES_*).
kubectl create secret generic postgres-secret -n "${NS}" \
  --from-literal=POSTGRES_USER="${DB_USER}" \
  --from-literal=POSTGRES_PASSWORD="${DB_PASSWORD}" \
  --from-literal=POSTGRES_DB="${DB_NAME}" \
  --dry-run=client -o yaml | kubectl apply -f -
# Secret cote apps (variables DB_*).
kubectl create secret generic app-secret -n "${NS}" \
  --from-literal=DB_USER="${DB_USER}" \
  --from-literal=DB_PASSWORD="${DB_PASSWORD}" \
  --from-literal=DB_NAME="${DB_NAME}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ">> ConfigMaps generes depuis les sources uniques"
# init.sql depuis db/init.sql (source unique).
kubectl create configmap postgres-init -n "${NS}" \
  --from-file=init.sql="${ROOT}/db/init.sql" \
  --dry-run=client -o yaml | kubectl apply -f -
# nginx.conf depuis services/frontend/nginx.conf (source unique).
kubectl create configmap frontend-config -n "${NS}" \
  --from-file=nginx.conf="${ROOT}/services/frontend/nginx.conf" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ">> RBAC (ServiceAccounts + Role demonstratif)"
kubectl apply -f "${K8S}/rbac.yaml"

echo ">> Postgres (StatefulSet + service headless)"
kubectl apply -f "${K8S}/postgres-service.yaml"
kubectl apply -f "${K8S}/postgres-statefulset.yaml"

echo ">> attente Postgres pret (le 1er pull de l'image postgres peut etre long)"
kubectl rollout status statefulset/postgres -n "${NS}" --timeout=600s

echo ">> ConfigMaps applicatifs"
kubectl apply -f "${K8S}/catalogue-configmap.yaml"
kubectl apply -f "${K8S}/orders-configmap.yaml"

echo ">> Deploiements + services applicatifs"
kubectl apply -f "${K8S}/catalogue-deployment.yaml"
kubectl apply -f "${K8S}/catalogue-service.yaml"
kubectl apply -f "${K8S}/orders-deployment.yaml"
kubectl apply -f "${K8S}/orders-service.yaml"
kubectl apply -f "${K8S}/frontend-deployment.yaml"
kubectl apply -f "${K8S}/frontend-service.yaml"

echo ">> Ingress"
kubectl apply -f "${K8S}/ingress.yaml"

echo ">> NetworkPolicies (zero-trust)"
kubectl apply -f "${K8S}/networkpolicy.yaml"

echo ">> HPA"
kubectl apply -f "${K8S}/catalogue-hpa.yaml"

echo ">> Backup CronJob"
kubectl apply -f "${K8S}/backup-cronjob.yaml"

echo ">> ServiceMonitor + regles d'alerte (necessitent les CRD de kube-prometheus-stack)"
if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
  kubectl apply -f "${K8S}/servicemonitor.yaml"
  kubectl apply -f "${ROOT}/monitoring/alert-rules.yaml"
else
  echo "   (CRD monitoring absents - installer d'abord kube-prometheus-stack, cf. README)"
fi

echo ">> attente des deploiements applicatifs"
kubectl rollout status deployment/catalogue -n "${NS}" --timeout=120s
kubectl rollout status deployment/orders -n "${NS}" --timeout=120s
kubectl rollout status deployment/frontend -n "${NS}" --timeout=120s

echo ""
echo "OK - boutique deployee dans le namespace ${NS}."
kubectl get all -n "${NS}"
