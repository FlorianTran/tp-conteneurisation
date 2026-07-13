# Projet Final - Clusteurisation de conteneurs

Application microservices deployee et **operee** sur Kubernetes (minikube + Calico),
avec CI/CD, observabilite, scalabilite, resilience et securite.

## Architecture

```
                              Internet / navigateur
                                       |
                                 [ Ingress nginx ]   host: projet-final.local
              /                        | /api/catalogue          | /api/orders
              v                        v                         v
      +---------------+        +----------------+        +----------------+
      |   frontend    |        |   catalogue    |        |     orders     |
      | nginx-unpriv  |        | Node/Express   |        | Node/Express   |
      | (page statique|        | GET /products  |<-------| POST /orders   |
      |  fetch /api)  |        | /metrics /ready|  DNS   | valide produit |
      +---------------+        +-------+--------+        +-------+--------+
        Deployment x2            Deployment x2 (HPA)       Deployment x2
                                       |                         |
                                       +-----------+-------------+
                                                   v
                                          +------------------+
                                          |    postgres      |  StatefulSet + PVC 1Gi
                                          | service headless |  init.sql via ConfigMap
                                          +------------------+
                                                   ^
                                          [ CronJob pg_dump -> PVC backup ]

  Observabilite : kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
                  ServiceMonitor -> scrape /metrics (catalogue, orders)
                  PrometheusRule -> alertes (ApiDeploymentDown, HighErrorRate)
  Securite      : NetworkPolicy zero-trust (Calico) + PSS baseline/restricted
                  + ServiceAccount par workload + RBAC + secrets hors Git
```

- **frontend** : `nginxinc/nginx-unprivileged` (UID 101, port 8080). Page statique
  qui appelle les 2 APIs via l'Ingress en same-origin (pas de CORS).
- **catalogue** : API Node/Express. `GET /products` (lit Postgres), `/health`
  (liveness), `/ready` (readiness testant la DB), `/metrics` (prom-client).
- **orders** : API Node/Express. `GET /orders`, `POST /orders` (valide le produit
  en appelant `catalogue-svc` en DNS interne, puis insere), `/health`, `/ready`,
  `/metrics`.
- **postgres** : `postgres:16-alpine` en StatefulSet (1 replica, PVC 1Gi),
  service headless, schema + seed montes via ConfigMap.

## Prerequis

- Docker
- minikube (driver docker) + kubectl
- helm (pour installer le monitoring uniquement)
- Node 22 (pour lancer les tests en local)
- trivy (optionnel, pour reproduire le scan en local)

## Deploiement (bout-en-bout, reproductible)

```bash
# 1. Cluster avec Calico (requis pour les NetworkPolicies) + addons
minikube start -p projet-final --cni=calico --driver=docker --memory=6g --cpus=4
kubectl wait --for=condition=Ready pods -l k8s-app=calico-node -n kube-system --timeout=240s
minikube addons enable ingress metrics-server -p projet-final

# 2. Build + charge les 3 images dans le cluster (pas de registry en local)
scripts/load-images.sh

# 3. Deploie la boutique (idempotent) : namespace, secrets, DB, apps,
#    ingress, netpol, RBAC, HPA, backup
scripts/deploy.sh

# 4. Monitoring (Helm sert UNIQUEMENT a installer la stack, l'app est en YAML brut)
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace -f monitoring/values-kube-prometheus.yaml
kubectl apply -f k8s/servicemonitor.yaml
kubectl apply -f monitoring/alert-rules.yaml

# 5. Verifie (voir "Acces" ci-dessous pour le port-forward)
scripts/smoke-test.sh
```

## Acces aux services

Le driver docker sur macOS ne rend pas `minikube ip` routable depuis l'hote. On
port-forward le controller Ingress :

```bash
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 18080:80
curl -H "Host: projet-final.local" http://127.0.0.1:18080/
curl -H "Host: projet-final.local" http://127.0.0.1:18080/api/catalogue/products
curl -H "Host: projet-final.local" http://127.0.0.1:18080/api/orders/orders
```

Alternative : ajouter `projet-final.local` -> `$(minikube ip -p projet-final)` dans
`/etc/hosts` et utiliser `minikube tunnel`.

Interfaces monitoring :

```bash
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090   # Prometheus
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80                          # Grafana (admin/admin)
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-alertmanager 9093:9093   # Alertmanager
```

## Choix techniques

- **Manifests k8s bruts** (pas de Helm pour l'app) : lisibilite pedagogique, on
  voit chaque objet. Helm sert seulement a installer kube-prometheus-stack.
- **Images chargees via `minikube image load`** (pas de push registry en local) :
  meme approche qu'au TP-4, `imagePullPolicy: IfNotPresent`. Le push GHCR reel est
  fait par la CI sur `main`.
- **Secrets hors Git** : `deploy.sh` cree les Secrets via `kubectl create secret
  --from-literal`. Les templates `*-secret.example.yaml` documentent les cles ;
  les vrais `*-secret.yaml` sont gitignore.
- **ConfigMaps generes depuis les sources uniques** : `init.sql` et `nginx.conf`
  sont injectes par `deploy.sh` via `--from-file` (pas de duplication de contenu).
- **PSS** : namespace `enforce: baseline` + `warn/audit: restricted`. Pods app
  durcis restricted, Postgres reste baseline (voir COMPTE-RENDU).

## Tests

```bash
cd services/catalogue && npm install && npm test   # node:test + supertest
cd services/orders    && npm install && npm test
```

## CI/CD

`.github/workflows/projet-final-ci.yml` (a la racine du repo, filtre sur
`projet-final/**`) :

1. **lint-test** (matrix catalogue/orders) : `npm install` -> `node --check` -> `npm test`.
2. **build-scan-push** (matrix des 3 services) : `docker build` -> **scan Trivy**
   (HIGH/CRITICAL, rapport non bloquant) -> push GHCR (`<sha7>` + `latest`),
   **uniquement sur `main`**.
3. **deploy** : documente mais **desactive** (`if: false`) — un runner GitHub
   heberge ne peut pas joindre un minikube local (voir Limites).

## Limites (assumees)

- **Le job deploy de la CI est desactive.** Un runner cloud n'a pas de route vers
  le cluster minikube local. En reel : runner self-hosted dans le reseau du cluster,
  ou cluster manage. Le deploiement se fait via `scripts/deploy.sh`.
- **Ingress non routable depuis l'hote** (driver docker macOS) : acces via
  port-forward ou `minikube tunnel`.
- **1 seul noeud** : le PVC est en RWO et le cluster mono-noeud. Le drain/anti-affinite
  multi-noeuds n'est pas demontre ici (optionnel dans le sujet).
- **Postgres 1 replica** : pas de HA base de donnees (hors perimetre) ; le backup
  CronJob attenue le risque de perte de donnees.

## Ameliorations possibles (bonus non retenus)

Chart Helm de l'app, deploiement blue/green ou canary, GitOps (ArgoCD/Flux),
tests de charge outilles (k6/vegeta), HA multi-noeuds avec anti-affinite et drain,
Postgres en replication. Non implementes volontairement (perimetre "propre sans
sur-ingenierie").

## Structure

```
projet-final/
  README.md COMPTE-RENDU.md RUNBOOK.md DEMO.md
  services/{catalogue,orders,frontend}/   # code + Dockerfile + tests
  db/init.sql                             # schema + seed
  k8s/                                    # tous les manifests (namespace, DB, apps, ingress, netpol, rbac, hpa, servicemonitor, backup)
  monitoring/                             # values Helm + PrometheusRule
  scripts/{load-images,deploy,smoke-test,teardown}.sh
.github/workflows/projet-final-ci.yml
```

## Teardown

```bash
scripts/teardown.sh          # supprime le namespace boutique
scripts/teardown.sh --all    # + monitoring + supprime le profil minikube
```
