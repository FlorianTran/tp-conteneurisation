#!/usr/bin/env bash
# Verifie que le frontend et les 2 APIs repondent 200 via l'Ingress.
# Usage : HOST=projet-final.local INGRESS_IP=$(minikube ip -p projet-final) ./smoke-test.sh
set -euo pipefail

HOST="${HOST:-projet-final.local}"
INGRESS_IP="${INGRESS_IP:-$(minikube ip -p "${MINIKUBE_PROFILE:-projet-final}")}"

echo "Ingress ${INGRESS_IP} (Host: ${HOST})"
fail=0

check() {
  local path="$1"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${HOST}" "http://${INGRESS_IP}${path}")
  if [ "${code}" = "200" ]; then
    echo "OK   ${path} -> ${code}"
  else
    echo "FAIL ${path} -> ${code}"
    fail=1
  fi
}

check "/"
check "/api/catalogue/products"
check "/api/orders/orders"

# Test POST : cree une commande via orders (validation produit via catalogue).
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  -H "Host: ${HOST}" -H "Content-Type: application/json" \
  -d '{"product_id":1,"quantity":2}' \
  "http://${INGRESS_IP}/api/orders/orders")
if [ "${code}" = "201" ]; then
  echo "OK   POST /api/orders/orders -> ${code}"
else
  echo "FAIL POST /api/orders/orders -> ${code}"
  fail=1
fi

exit ${fail}
