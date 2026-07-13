# Runbook - Projet Final

Guide d'exploitation : diagnostic de panne, commandes utiles, operations courantes
(rollback, scale, restart, backup/restore). Namespace : `boutique`.
Profil minikube : `projet-final`.

## Vue d'ensemble rapide

```bash
kubectl get all -n boutique
kubectl get pods -n boutique -o wide
kubectl top pods -n boutique
kubectl get events -n boutique --sort-by=.lastTimestamp | tail -20
```

## Diagnostic de panne

### Un pod ne demarre pas / redemarre en boucle

```bash
kubectl get pods -n boutique
kubectl describe pod <pod> -n boutique          # section Events en bas
kubectl logs <pod> -n boutique                  # logs courants
kubectl logs <pod> -n boutique --previous       # logs du conteneur precedent (crash)
```

Causes frequentes :
- `CrashLoopBackOff` : erreur applicative -> voir les logs.
- `ImagePullBackOff` : image absente -> `scripts/load-images.sh` (local) ou verifier le tag.
- `CreateContainerConfigError` : Secret/ConfigMap manquant -> `kubectl get secret,cm -n boutique`.
- `Pending` : ressources insuffisantes ou PVC non lie -> `kubectl get pvc -n boutique`.

### Une API repond mal / 5xx

```bash
# readiness : l'API voit-elle la DB ?
kubectl exec deploy/catalogue -n boutique -- wget -qO- http://localhost:3000/ready
# logs JSON filtres sur les erreurs
kubectl logs -l app=catalogue -n boutique --tail=100 | grep -i '"level":50'
```

### La base de donnees est injoignable

```bash
kubectl get statefulset postgres -n boutique
kubectl logs postgres-0 -n boutique --tail=30
# test connexion depuis le pod postgres :
kubectl exec postgres-0 -n boutique -- sh -c 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
kubectl exec -it postgres-0 -n boutique -- psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c '\dt'
```

### Le trafic est bloque (suspicion NetworkPolicy)

```bash
kubectl get networkpolicy -n boutique
kubectl describe networkpolicy <nom> -n boutique
# test depuis un pod autorise (label app=orders) vs non autorise
kubectl exec deploy/orders -n boutique -c orders -- wget -qO- --timeout=5 http://catalogue-svc/products
```

Un timeout `http_code=000` cote pod non autorise est le comportement ATTENDU
(zero-trust). Un timeout cote flux legitime = policy trop stricte : verifier les
`podSelector` / `namespaceSelector`.

### L'Ingress renvoie 404 / 502

```bash
kubectl get ingress -n boutique
kubectl describe ingress boutique-ingress -n boutique
kubectl get pods -n ingress-nginx
kubectl logs -n ingress-nginx deploy/ingress-nginx-controller --tail=50
```

502 = le backend (Service/pods) ne repond pas -> verifier les endpoints :
`kubectl get endpoints -n boutique`.

## Operations courantes

### Redemarrer un service (sans downtime)

```bash
kubectl rollout restart deployment/catalogue -n boutique
kubectl rollout status deployment/catalogue -n boutique
```

### Rollback vers la revision precedente

```bash
kubectl rollout history deployment/catalogue -n boutique
kubectl rollout undo deployment/catalogue -n boutique
kubectl rollout undo deployment/catalogue -n boutique --to-revision=<N>   # revision precise
```

### Scaler manuellement

```bash
kubectl scale deployment/orders -n boutique --replicas=4
# catalogue est pilote par le HPA : le forcer a la main sera reajuste.
kubectl get hpa catalogue-hpa -n boutique
```

### Mettre a jour une image

```bash
# rebuild + recharge dans minikube
scripts/load-images.sh
# forcer la reprise de l'image (meme tag) :
kubectl rollout restart deployment/catalogue -n boutique
```

### Modifier un Secret / ConfigMap

```bash
# regenere le secret via kubectl create ... --dry-run | apply (voir deploy.sh)
# puis redemarrer les pods qui le consomment pour recharger l'env :
kubectl rollout restart deployment/catalogue deployment/orders -n boutique
```

## Backup / Restore

### Declencher un backup a la demande

```bash
kubectl create job --from=cronjob/postgres-backup backup-manuel-$(date +%s) -n boutique
kubectl logs -l job-name=<job> -n boutique
```

Le dump est ecrit dans le PVC `postgres-backup-pvc` (`/backups/boutique-<ts>.sql`).

### Lister les dumps disponibles

```bash
kubectl run inspect-backups --rm -i --image=postgres:16-alpine -n boutique \
  --overrides='{"spec":{"volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"postgres-backup-pvc"}}],"containers":[{"name":"c","image":"postgres:16-alpine","command":["ls","-lh","/backups"],"volumeMounts":[{"name":"b","mountPath":"/backups"}]}]}}'
```

### Restaurer un dump

```bash
# copier le fichier depuis le PVC puis :
kubectl exec -i postgres-0 -n boutique -- psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" < boutique-<ts>.sql
```

## Observabilite

```bash
# Prometheus : cibles scrapees
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
#   http://localhost:9090/targets   ->  boutique/catalogue, boutique/orders = UP
#   PromQL utiles :
#     up{namespace="boutique"}
#     sum by (service)(rate(http_requests_total[5m]))
#     rate(http_requests_total{status=~"5.."}[5m])

# Alertes actives
#   http://localhost:9090/alerts    -> ApiDeploymentDown / HighErrorRate

# Grafana (admin/admin)
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
```

## Escalade / verifications finales

- `kubectl get pods -A | grep -v Running | grep -v Completed` : rien d'anormal ?
- `kubectl top nodes` : le noeud n'est pas sature ?
- `kubectl get pvc -n boutique` : tous `Bound` ?
- `kubectl get hpa -n boutique` : cible CPU coherente (pas `<unknown>`, sinon
  metrics-server KO : `kubectl get deploy metrics-server -n kube-system`).
