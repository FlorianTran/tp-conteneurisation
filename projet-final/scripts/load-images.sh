#!/usr/bin/env bash
# Build les 3 images et les charge dans le cluster minikube (sans passer par un
# registry distant) - cf. "Probleme rencontre : push registry" du TP-4.
set -euo pipefail

PROFILE="${MINIKUBE_PROFILE:-projet-final}"
REGISTRY="ghcr.io/floriantran"
TAG="${IMAGE_TAG:-latest}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for svc in catalogue orders frontend; do
  IMAGE="${REGISTRY}/projet-final-${svc}:${TAG}"
  echo ">> build ${IMAGE}"
  docker build -t "${IMAGE}" "${ROOT}/services/${svc}"
  echo ">> minikube image load ${IMAGE} (profil ${PROFILE})"
  minikube image load "${IMAGE}" -p "${PROFILE}"
done

echo "OK - 3 images chargees dans minikube (${PROFILE})."
