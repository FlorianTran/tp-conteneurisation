# Script de demo - soutenance

Deroule chronologique pour la soutenance, avec la **preuve attendue** a chaque
etape. Prevoir 3 terminaux (T1 = commandes, T2 = port-forward Ingress, T3 =
watch). Duree ~12 min.

## 0. Prerequis (avant la demo, deja fait)

Cluster demarre, images chargees, boutique + monitoring deployes. Verif :

```bash
kubectl get all -n boutique          # tout Running/Ready, HPA present, PVC Bound
```

Lancer les port-forwards :

```bash
# T2
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 18080:80
# autre onglet : Prometheus
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
```

## 1. L'app marche de bout en bout (A + B)

```bash
scripts/smoke-test.sh
```

**Preuve** : `/`, `/api/catalogue/products`, `/api/orders/orders` renvoient 200,
et le POST cree une commande (201). Montrer la page dans le navigateur :
`http://127.0.0.1:18080/` avec header Host (ou via /etc/hosts).

Montrer la communication inter-service (orders valide via catalogue) :

```bash
curl -H "Host: projet-final.local" -X POST -H "Content-Type: application/json" \
  -d '{"product_id":999,"quantity":1}' http://127.0.0.1:18080/api/orders/orders
# -> 422 : produit inexistant, orders a bien interroge catalogue
```

## 2. Objets Kubernetes (B)

```bash
kubectl get statefulset,deployment,svc,ingress,configmap,secret,pvc -n boutique
kubectl get pods -n boutique --show-labels
```

**Preuve** : StatefulSet (postgres) + Deployments (apps), service headless
(`postgres` ClusterIP None), Ingress, ConfigMaps + Secrets, PVC Bound.

## 3. Scalabilite - HPA (C)

```bash
# T3
kubectl get hpa catalogue-hpa -n boutique -w
```

Generer de la charge (5 pods busybox labellises app=orders) :

```bash
for i in 1 2 3 4 5; do
  kubectl run loadgen$i --image=busybox:1.36 -n boutique --labels app=orders \
    --restart=Never --command -- /bin/sh -c 'while true; do wget -q -O /dev/null http://catalogue-svc/products; done'
done
```

**Preuve** : dans T3, CPU depasse 50% et REPLICAS monte 2 -> 4 -> 6. Nettoyer :
`kubectl delete pod -l app=orders --field-selector ... ` (ou par nom loadgen*).

## 4. Resilience - self-healing + rolling update (C)

```bash
kubectl delete pod -l app=catalogue -n boutique
kubectl get pods -n boutique -l app=catalogue      # nouveaux pods recrees aussitot

kubectl rollout restart deployment/catalogue -n boutique
kubectl rollout status  deployment/catalogue -n boutique   # zero downtime
kubectl rollout undo    deployment/catalogue -n boutique   # rollback
```

**Preuve** : le ReplicaSet recree les pods tues ; le rollout se fait sans coupure ;
le undo restaure la revision precedente.

## 5. Securite - NetworkPolicy zero-trust (F)

```bash
kubectl run intrus --image=curlimages/curl -n boutique --labels app=intrus \
  --restart=Never --command -- sleep 300
kubectl exec intrus -n boutique -- curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" -m 5 http://catalogue-svc/products
kubectl delete pod intrus -n boutique
```

**Preuve** : `000 5.00s` (timeout) — le pod non autorise est bloque, alors que le
flux orders -> catalogue passe. Montrer aussi le RBAC :

```bash
kubectl auth can-i list pods -n boutique --as=system:serviceaccount:boutique:orders-sa      # yes
kubectl auth can-i list pods -n boutique --as=system:serviceaccount:boutique:catalogue-sa   # no
```

## 6. Observabilite - Prometheus + alerte (E)

Dans Prometheus (`http://localhost:9090`) :
- `/targets` : `boutique/catalogue` et `boutique/orders` = **UP**.
- PromQL : `sum by (service)(rate(http_requests_total[5m]))`.

Declencher une alerte :

```bash
kubectl scale deployment/orders -n boutique --replicas=0
# attendre ~1 min, page /alerts -> ApiDeploymentDown = FIRING
kubectl scale deployment/orders -n boutique --replicas=2   # restaurer
```

**Preuve** : `/alerts` montre `ApiDeploymentDown` en firing, visible aussi dans
Alertmanager. Montrer un dashboard Grafana (CPU/memoire des pods).

## 7. Bonus - backup (Runbook)

```bash
kubectl create job --from=cronjob/postgres-backup backup-demo -n boutique
kubectl logs -l job-name=backup-demo -n boutique
```

**Preuve** : `backup ecrit : /backups/boutique-<ts>.sql` dans le PVC.

## 8. CI/CD (D)

Montrer `.github/workflows/projet-final-ci.yml` :
- jobs lint-test -> build-scan-push (Trivy) -> push GHCR (sur main).
- job `deploy` en `if: false` : expliquer la limite runner heberge / minikube local.

Montrer un scan Trivy en local :

```bash
trivy image --severity HIGH,CRITICAL --ignore-unfixed ghcr.io/floriantran/projet-final-catalogue:latest
```

## Recap couverture du sujet

| Rubrique | Preuve |
|---|---|
| A. App microservices | smoke-test 200, POST 201, 422 inter-service |
| B. Deploiement K8s | StatefulSet+PVC, Deployments, headless svc, Ingress, ConfigMap/Secret, probes |
| C. Scalabilite & resilience | HPA 2->6, kill-pod self-healing, rolling update + undo |
| D. CI/CD | workflow lint/test -> build -> Trivy -> push GHCR |
| E. Observabilite | metrics-server, Prometheus scrape UP, PromQL, alerte firing, logs JSON |
| F. Securite | NetworkPolicy zero-trust bloque, RBAC least-privilege, PSS, secrets hors Git, Trivy |
| Bonus | CronJob backup pg_dump -> PVC |
