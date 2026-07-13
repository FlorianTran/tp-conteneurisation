#!/usr/bin/env bash
# Verifie que le frontend et les 2 APIs repondent 200 via l'Ingress.
#
# Par defaut : essaie l'IP minikube (fonctionne sous Linux). Si elle n'est pas
# routable depuis l'hote (cas du driver docker sur macOS), bascule automatiquement
# sur un port-forward du controller ingress-nginx.
#
# Surcharges possibles : HOST=... BASE_URL=http://127.0.0.1:18080 ./smoke-test.sh
set -euo pipefail

HOST="${HOST:-projet-final.local}"
PROFILE="${MINIKUBE_PROFILE:-projet-final}"
PF_PID=""

cleanup() { [ -n "${PF_PID}" ] && kill "${PF_PID}" 2>/dev/null || true; }
trap cleanup EXIT

reachable() { curl -s -o /dev/null -m 3 -H "Host: ${HOST}" "${1}/" 2>/dev/null; }

if [ -n "${BASE_URL:-}" ]; then
  echo "BASE_URL fourni : ${BASE_URL}"
else
  IP=$(minikube ip -p "${PROFILE}" 2>/dev/null || true)
  if [ -n "${IP}" ] && reachable "http://${IP}"; then
    BASE_URL="http://${IP}"
    echo "Acces direct via l'IP minikube : ${BASE_URL}"
  else
    echo "IP minikube non routable depuis l'hote -> port-forward ingress-nginx sur 18080"
    kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 18080:80 >/dev/null 2>&1 &
    PF_PID=$!
    BASE_URL="http://127.0.0.1:18080"
    until reachable "${BASE_URL}"; do sleep 1; done
  fi
fi

echo "Ingress ${BASE_URL} (Host: ${HOST})"
fail=0

check() {
  local path="$1" expected="$2" method="${3:-GET}" data="${4:-}"
  local code
  if [ "${method}" = "POST" ]; then
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
      -H "Host: ${HOST}" -H "Content-Type: application/json" \
      -d "${data}" "${BASE_URL}${path}")
  else
    code=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${HOST}" "${BASE_URL}${path}")
  fi
  if [ "${code}" = "${expected}" ]; then
    echo "OK   ${method} ${path} -> ${code}"
  else
    echo "FAIL ${method} ${path} -> ${code} (attendu ${expected})"
    fail=1
  fi
}

check "/" 200
check "/api/catalogue/products" 200
check "/api/orders/orders" 200
check "/api/orders/orders" 201 POST '{"product_id":1,"quantity":2}'

exit ${fail}
