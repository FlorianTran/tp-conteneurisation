#!/usr/bin/env bash
# Supprime la boutique. Par defaut garde le namespace monitoring et le cluster.
# --all supprime aussi le profil minikube.
set -euo pipefail

NS="boutique"
PROFILE="${MINIKUBE_PROFILE:-projet-final}"

echo ">> suppression du namespace ${NS} (pods, services, PVC, secrets...)"
kubectl delete namespace "${NS}" --ignore-not-found

if [ "${1:-}" = "--all" ]; then
  echo ">> suppression du namespace monitoring"
  kubectl delete namespace monitoring --ignore-not-found
  echo ">> suppression du profil minikube ${PROFILE}"
  minikube delete -p "${PROFILE}"
fi

echo "OK - teardown termine."
