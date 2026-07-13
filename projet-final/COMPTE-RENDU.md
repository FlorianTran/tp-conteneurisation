# Compte-rendu Projet Final : Clusteurisation de conteneurs

Application microservices (frontend nginx + 2 APIs Node/Express + PostgreSQL)
deployee sur Kubernetes (minikube + Calico), avec CI/CD, observabilite,
scalabilite, resilience et securite.

## Architecture

- **frontend** : nginx-unprivileged (page statique) qui appelle les 2 APIs via l'Ingress (same-origin, pas de CORS).
- **catalogue** : API Node/Express, `GET /products`, lit PostgreSQL.
- **orders** : API Node/Express, `GET/POST /orders`, valide le produit en appelant catalogue en DNS interne, puis ecrit dans PostgreSQL.
- **postgres** : StatefulSet + PVC, service headless, seed via ConfigMap.

## Commandes executees

minikube start -p projet-final --cni=calico --driver=docker --memory=6g --cpus=4
kubectl wait --for=condition=Ready pods -l k8s-app=calico-node -n kube-system --timeout=240s
minikube addons enable ingress -p projet-final
minikube addons enable metrics-server -p projet-final
scripts/load-images.sh                 # docker build + minikube image load des 3 images
scripts/deploy.sh                      # namespace, secrets, DB, apps, ingress, netpol, RBAC, HPA, backup
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install monitoring prometheus-community/kube-prometheus-stack -n monitoring --create-namespace -f monitoring/values-kube-prometheus.yaml
kubectl apply -f k8s/servicemonitor.yaml
kubectl apply -f monitoring/alert-rules.yaml
kubectl get all -n boutique
scripts/smoke-test.sh
kubectl top pods -n boutique
kubectl delete pod -l app=catalogue -n boutique          # test self-healing
kubectl rollout restart deployment/catalogue -n boutique # test rolling update
kubectl rollout undo deployment/catalogue -n boutique    # test rollback
kubectl run intrus --image=curlimages/curl --labels app=intrus ... # test NetworkPolicy
kubectl run loadgen --image=busybox ... (x5)             # test HPA
kubectl scale deployment/orders --replicas=0             # test alerte
kubectl create job --from=cronjob/postgres-backup backup-manuel -n boutique
kubectl auth can-i list pods --as=system:serviceaccount:boutique:orders-sa
trivy image ghcr.io/floriantran/projet-final-catalogue:latest

## Probleme rencontre : minikube image load au lieu de docker push (registry)

Comme au TP-4, on ne passe pas par un registry pour le dev local. Les 3 images
sont buildees puis injectees directement dans le runtime du cluster via
`minikube image load ghcr.io/floriantran/projet-final-<svc>:latest`. Les
deployments utilisent `imagePullPolicy: IfNotPresent` pour que Kubernetes prenne
l'image locale au lieu de tenter un pull vers ghcr.io (qui echouerait, l'image
n'y ayant jamais ete poussee en local). Le push reel vers GHCR n'a lieu qu'en CI,
sur la branche `main`.

## Probleme rencontre : Ingress injoignable via `minikube ip` (driver docker sur macOS)

Avec le driver docker sur macOS, l'IP retournee par `minikube ip` (192.168.58.2)
n'est pas routable depuis l'hote : le reseau du cluster tourne dans la VM docker.
`curl http://192.168.58.2/` timeout (exit 28).

Contournement pour les tests depuis l'hote : port-forward du controller ingress-nginx.

    kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 18080:80
    curl -H "Host: projet-final.local" http://127.0.0.1:18080/api/catalogue/products

En conditions reelles (cloud), l'Ingress serait expose par un LoadBalancer et le
host `projet-final.local` pointerait vers son IP publique. En local, l'alternative
est `minikube tunnel`. Le smoke-test respecte quand meme le chemin reel
Ingress -> Service -> Pod, ce qui valide aussi le path-routing et les NetworkPolicies.

## Probleme rencontre : `up == 0` ne se declenche jamais quand un Deployment tombe a 0

Premiere version de l'alerte "service down" : `up{service="orders-svc"} == 0`.
En scalant orders a 0 replica pour la tester, l'alerte n'a jamais fire.

Raison : quand le Deployment tombe a 0 pod, le Service perd tous ses endpoints.
Le ServiceMonitor n'a alors plus aucune cible a scraper, donc la serie `up`
pour ce service **disparait** completement de Prometheus au lieu de valoir 0.
Une expression `up == 0` ne peut matcher qu'une cible existante dont le scrape
echoue (pod la mais /metrics KO), pas une cible qui n'existe plus.

Correction : s'appuyer sur kube-state-metrics, dont la serie reste exposee a 0 :

    kube_deployment_status_replicas_available{namespace="boutique", deployment=~"catalogue|orders"} == 0

Apres correction, l'alerte `ApiDeploymentDown` passe bien en `firing` apres 1 min,
et remonte dans l'Alertmanager (voir logs).

## Probleme rencontre : le label `service` des metriques est ecrase par le ServiceMonitor

Cote code, prom-client pose `setDefaultLabels({ service: 'catalogue' })`. Mais
apres scrape, le label `service` vaut `catalogue-svc` / `orders-svc` : le
ServiceMonitor applique un relabeling qui pose `service` = nom du Service k8s,
ecrasant la valeur du code. Les regles d'alerte et requetes PromQL ont donc ete
ecrites avec les vraies valeurs (`catalogue-svc`, `orders-svc`).

## Probleme rencontre : PostgreSQL et PSS restricted

Le namespace `boutique` est en `enforce: baseline` + `warn/audit: restricted`.
Les pods app (catalogue, orders, frontend) sont durcis `restricted` (runAsNonRoot,
drop ALL, readOnlyRootFilesystem, seccompProfile RuntimeDefault) et passent sans
warning. En revanche l'image `postgres:16-alpine` officielle chown son repertoire
de donnees au demarrage (entrypoint root -> gosu postgres) et ne satisfait pas
`restricted` sans bricolage (init container + fsGroup + volumes prepares). A
l'apply, Kubernetes affiche donc un warning (informatif, non bloquant car le
namespace enforce seulement `baseline`) :

    Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false ...
    runAsNonRoot != true (pod or container "postgres" must set securityContext.runAsNonRoot=true) ...

Choix assume : Postgres reste `baseline` (fsGroup: 999 pour les droits sur le
volume), les workloads applicatifs stateless sont `restricted`. C'est la nuance
PSS vue au TP-5 : on durcit ce qui peut l'etre, on documente ce qui ne peut pas.
Le meme warning apparait pour le CronJob de backup (image postgres).

## Logs

### kubectl get all -n boutique

    NAME                             READY   STATUS      RESTARTS   AGE
    pod/catalogue-69f68b99dd-7bbwp   1/1     Running     0          14m
    pod/catalogue-69f68b99dd-x24lk   1/1     Running     0          18m
    pod/frontend-846f649594-gn98c    1/1     Running     0          95m
    pod/frontend-846f649594-rsglq    1/1     Running     0          95m
    pod/orders-5b9ff9fb7f-ff68b      1/1     Running     0          5m13s
    pod/orders-5b9ff9fb7f-zsfg5      1/1     Running     0          5m13s
    pod/postgres-0                   1/1     Running     0          101m

    service/catalogue-svc   ClusterIP   10.107.27.156    <none>   80/TCP     95m
    service/frontend-svc    ClusterIP   10.97.52.246     <none>   80/TCP     95m
    service/orders-svc      ClusterIP   10.107.102.182   <none>   80/TCP     95m
    service/postgres        ClusterIP   None             <none>   5432/TCP   101m   (headless)

    deployment.apps/catalogue   2/2     2   2   95m
    deployment.apps/frontend    2/2     2   2   95m
    deployment.apps/orders      2/2     2   2   95m
    statefulset.apps/postgres   1/1             101m

    horizontalpodautoscaler.autoscaling/catalogue-hpa   Deployment/catalogue   cpu: 6%/50%   2   6   2
    cronjob.batch/postgres-backup   0 2 * * *   False   0   <none>   95m

### PVC (Bound) et labels PSS du namespace

    NAME                  STATUS   CAPACITY   ACCESS MODES   STORAGECLASS
    data-postgres-0       Bound    1Gi        RWO            standard
    postgres-backup-pvc   Bound    1Gi        RWO            standard

    boutique   ... pod-security.kubernetes.io/enforce=baseline,
                   pod-security.kubernetes.io/warn=restricted,
                   pod-security.kubernetes.io/audit=restricted

### Smoke-test (via le chemin reel Ingress -> Service -> Pod)

    GET /                        -> 200
    GET /api/catalogue/products  -> 200
    GET /api/orders/orders       -> 200

    # catalogue lit la DB :
    {"products":[{"id":1,"name":"Clavier mecanique","price":"89.90"},
                 {"id":2,"name":"Souris ergonomique","price":"45.00"},
                 {"id":3,"name":"Ecran 27 pouces","price":"249.99"},
                 {"id":4,"name":"Casque audio","price":"129.50"}]}

    # orders valide le produit via catalogue (DNS interne) puis ecrit :
    POST /api/orders/orders {"product_id":1,"quantity":2}
    -> 201 {"order":{"id":1,"product_id":1,"quantity":2,"created_at":"2026-07-13T10:48:44.039Z"}}

    # produit inexistant -> 422 (validation inter-service) :
    POST /api/orders/orders {"product_id":999,"quantity":1} -> 422

### Logs JSON structures (pino) - catalogue

    {"level":30,"time":1783945198675,"pid":1,"hostname":"catalogue-69f68b99dd-7bbwp",
     "req":{"method":"GET","url":"/ready","headers":{"user-agent":"kube-probe/1.35"}},
     "res":{"statusCode":200},"responseTime":1,"msg":"request completed"}

Les probes Kubernetes (`kube-probe/1.35`) tapent `/ready` et `/health`, chaque
requete est loguee en JSON une ligne (exploitable par un collecteur type Loki/ELK).

### kubectl top (metrics-server)

    NAME                         CPU(cores)   MEMORY(bytes)
    catalogue-69f68b99dd-fszbb   6m           89Mi
    catalogue-69f68b99dd-h6jpx   6m           30Mi
    frontend-846f649594-gn98c    1m           12Mi
    orders-5b9ff9fb7f-2dgcf      6m           30Mi
    postgres-0                   3m           45Mi

    NAME           CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
    projet-final   227m         3%       3571Mi          44%

### Resilience 1 : self-healing (kill-pod)

    -- avant --
    catalogue-69f68b99dd-fszbb   1/1   Running
    catalogue-69f68b99dd-h6jpx   1/1   Running
    >> kubectl delete pod catalogue-69f68b99dd-fszbb
    -- juste apres --
    catalogue-69f68b99dd-7xln9   0/1   Running       3s    (nouveau, recree par le ReplicaSet)
    catalogue-69f68b99dd-fszbb   1/1   Terminating         (ancien)
    catalogue-69f68b99dd-h6jpx   1/1   Running

Le ReplicaSet recree immediatement un pod pour maintenir `replicas: 2`.

### Resilience 2 : rolling update + rollback (zero downtime)

    >> kubectl rollout restart deployment/catalogue
    Waiting for deployment "catalogue" rollout to finish: 1 out of 2 new replicas have been updated...
    Waiting for deployment "catalogue" rollout to finish: 1 old replicas are pending termination...
    deployment "catalogue" successfully rolled out

    >> kubectl rollout history deployment/catalogue
    REVISION  CHANGE-CAUSE
    1         <none>
    2         <none>

    >> kubectl rollout undo deployment/catalogue
    deployment.apps/catalogue rolled back
    deployment "catalogue" successfully rolled out

La strategie RollingUpdate (maxUnavailable: 1, maxSurge: 1) garde au moins un
pod disponible pendant toute la bascule : aucune coupure de service.

### Scalabilite : HPA sous charge

5 generateurs de charge (busybox labellises `app=orders` pour etre autorises par
la NetworkPolicy) hammerent `catalogue-svc/products` :

    [60s]  cpu: 5%/50%     REPLICAS 2   pods Running=2
    [70s]  cpu: 283%/50%   REPLICAS 2   pods Running=4   (scale-up declenche)
    [90s]  cpu: 283%/50%   REPLICAS 4   pods Running=6
    [100s] cpu: 283%/50%   REPLICAS 6   pods Running=6   (max atteint)
    ...
    (arret de la charge)
    cpu: 6%/50%     REPLICAS 2   pods Running=2   (scale-down apres ~5 min de stabilisation)

Le HPA scale de 2 a 6 pods (max) des que le CPU depasse 50% de la request (100m),
puis revient a 2 apres la periode de stabilisation par defaut (5 min).

### Securite 1 : NetworkPolicy zero-trust

Pod `intrus` (label non autorise) cree dans le namespace :

    >> curl -m 5 http://catalogue-svc/products
    catalogue-svc -> http_code=000 time=5.003900s   (timeout, exit 28)
    >> curl -m 5 http://postgres:5432
    postgres:5432 -> http_code=000 time=5.003582s    (timeout, exit 28)

    # chemin legitime (orders -> catalogue, autorise) :
    >> depuis un pod orders : wget http://catalogue-svc/products
    {"products":[{"id":1,"name":"Clavier mecanique",...

La `default-deny-all` bloque tout trafic non explicitement autorise. Seuls les
flux declares (ingress-nginx -> apps, orders -> catalogue, apps -> postgres,
monitoring -> /metrics) passent.

### Securite 2 : RBAC (least privilege)

    orders-sa    list pods     : yes   (Role pod-reader lie a ce SA)
    orders-sa    delete pods   : no
    orders-sa    create deploy : no
    catalogue-sa list pods     : no    (aucun binding)
    frontend-sa  list pods     : no

Seul `orders-sa` a le droit de lister les pods (Role `pod-reader` demonstratif).
Les autres SA n'ont aucun droit sur l'API (et automount desactive).

### Observabilite : Prometheus scrape les APIs + alerte

    # up{namespace="boutique"} : les 4 pods API sont scrapes
    catalogue-svc   catalogue-69f68b99dd-h6jpx   -> up= 1
    catalogue-svc   catalogue-69f68b99dd-fszbb   -> up= 1
    orders-svc      orders-5b9ff9fb7f-cwkh6      -> up= 1
    orders-svc      orders-5b9ff9fb7f-2dgcf      -> up= 1

    # metrique applicative (prom-client) :
    sum by (service)(rate(http_requests_total[5m]))
      catalogue-svc = 0.737 req/s
      orders-svc    = 0.730 req/s

    # regles chargees :
    ApiDeploymentDown  state= inactive  health= ok
    HighErrorRate      state= inactive  health= ok

    # alerte declenchee (orders scale a 0) :
    ApiDeploymentDown | state= firing | deployment= orders | severity= critical
    # remontee dans l'Alertmanager :
    ApiDeploymentDown | deployment= orders | state= active

### Bonus : backup pg_dump -> PVC

    >> kubectl create job --from=cronjob/postgres-backup backup-manuel -n boutique
    backup demarre a 20260713-120258
    backup ecrit : /backups/boutique-20260713-120258.sql
    -rw-r--r--    1 root     root        3.8K   boutique-20260713-120258.sql

### CI : scan Trivy (execute aussi en local, comme le fait le workflow)

    trivy image ghcr.io/floriantran/projet-final-catalogue:latest
    Node.js (node-pkg)  Total: 2 (HIGH: 2, CRITICAL: 0)
    picomatch  CVE-2026-33671  HIGH  fixed  4.0.3 -> 4.0.4  (ReDoS)
    sigstore   CVE-2026-48815  HIGH  fixed  3.1.0 -> 4.1.1

Les 2 HIGH sont dans le npm global embarque par l'image de base `node:22-alpine`
(pas dans les dependances de l'app). En CI on scanne en `exit-code: 0` (rapport,
ne casse pas le build) avec `ignore-unfixed`. En durcissant on utiliserait une
image `-slim` / `distroless` pour retirer npm de l'image finale.

## Probleme rencontre : job deploy en CI impossible sur runner heberge

Le workflow contient un job `deploy` **volontairement desactive** (`if: false`).
Un runner GitHub heberge tourne dans le cloud GitHub et n'a aucun acces reseau
au cluster minikube local (kubeconfig pointe sur une IP privee de la VM docker de
la machine de dev). Le deploiement se fait donc via `scripts/deploy.sh` en local.
En conditions reelles, on brancherait un **runner self-hosted** dans le reseau du
cluster (ou un cluster manage joignable), et le job deploy s'activerait. Limite
assumee et documentee, plutot qu'un faux job "vert" qui ne deploie rien.

---

## Questions conceptuelles

### 1. StatefulSet vs Deployment : pourquoi Postgres en StatefulSet ?

Un Deployment gere des pods **interchangeables et sans identite** : ils sont
crees dans un ordre quelconque, avec des noms aleatoires, et partagent (ou non)
un volume. Parfait pour du stateless (les APIs). Un StatefulSet donne a chaque
pod une **identite stable** : nom ordinal (`postgres-0`), volume dedie via
`volumeClaimTemplates` (chaque replica a SON PVC), et un ordre de demarrage/arret
deterministe. Postgres ecrit sur disque : il lui faut un stockage persistant
attache a une identite fixe, sinon un redemarrage repartirait sur un volume
different. D'ou le StatefulSet.

### 2. A quoi sert le service headless (clusterIP: None) ?

Un Service classique (ClusterIP) donne UNE IP virtuelle qui load-balance vers les
pods : on ne sait pas quel pod repond. Un StatefulSet a besoin d'adresser
**chaque** pod individuellement (ex: un replica primaire vs replicas de lecture).
Le service headless (`clusterIP: None`) ne cree pas d'IP virtuelle : le DNS
renvoie directement les IPs des pods, et chaque pod recoit un nom DNS stable
(`postgres-0.postgres.boutique.svc.cluster.local`). Ici avec 1 replica c'est
surtout le pattern correct impose par le StatefulSet ; les apps se connectent au
nom court `postgres`.

### 3. Comment l'Ingress route-t-il vers plusieurs services (path-routing) ?

L'Ingress est une regle L7 (HTTP) interpretee par le controller (ingress-nginx).
On declare plusieurs `paths`, chacun pointant vers un Service different :

    /api/catalogue(/|$)(.*)  -> catalogue-svc
    /api/orders(/|$)(.*)     -> orders-svc
    /()(.*)                  -> frontend-svc

L'annotation `rewrite-target: /$2` reecrit l'URL avant de l'envoyer au backend :
`/api/catalogue/products` devient `/products` cote catalogue (l'API n'a pas
connaissance du prefixe). Comme tout passe par le meme host, le frontend fait des
`fetch` same-origin : pas de CORS a gerer.

### 4. Que garantit RollingUpdate (maxSurge / maxUnavailable) ?

RollingUpdate remplace les pods **progressivement** au lieu de tout tuer d'un
coup. `maxUnavailable: 1` = au plus 1 pod indisponible pendant la bascule (donc
au moins 1 sert toujours le trafic). `maxSurge: 1` = au plus 1 pod surnumeraire
cree en plus temporairement. Combine avec les readiness probes, Kubernetes
n'envoie du trafic a un nouveau pod que lorsqu'il est `Ready` : la mise a jour se
fait sans coupure (zero downtime), et un `rollout undo` revient a la revision
precedente de la meme facon.

### 5. Comment fonctionne le HPA et pourquoi seulement sur catalogue ?

Le HPA (HorizontalPodAutoscaler) lit periodiquement les metriques (ici le CPU via
metrics-server), les compare a une cible (`averageUtilization: 50` par rapport a
la **request** CPU, pas la limit), et ajuste le nombre de replicas entre min et
max. CPU a 283% de la request de 100m -> il monte a 6 pods ; charge retombee ->
il redescend a 2 apres 5 min de stabilisation (anti-flapping). On l'a mis sur
catalogue car c'est le service en lecture susceptible de prendre du trafic ; il
faut imperativement des `requests` CPU definies, sinon le HPA n'a pas de reference
pour calculer le pourcentage.

### 6. Comment Prometheus decouvre-t-il les cibles a scraper (ServiceMonitor) ?

kube-prometheus-stack deploie le Prometheus Operator, qui watch des objets
`ServiceMonitor`. Un ServiceMonitor est un selecteur declaratif : "scrape les
Services qui matchent ce label, sur ce port, ce path, cet intervalle". Notre
ServiceMonitor selectionne les Services `app in (catalogue, orders)`, port `http`,
path `/metrics`, toutes les 15s. Le Prometheus de la stack ne prend en compte que
les ServiceMonitor portant `release: monitoring` (son `serviceMonitorSelector`),
d'ou ce label obligatoire. L'Operator regenere alors la config de scrape de
Prometheus automatiquement, sans redemarrage manuel.

### 7. Qu'est-ce qu'une NetworkPolicy et pourquoi une strategie zero-trust ?

Une NetworkPolicy est un pare-feu L3/L4 applique aux pods, implemente par le CNI
(Calico ici). Par defaut, tout pod peut parler a tout pod : une `default-deny-all`
(ingress + egress, podSelector vide) inverse ce comportement en tout bloquant.
On rouvre ensuite explicitement chaque flux legitime (ingress-nginx -> apps,
orders -> catalogue, apps -> postgres, DNS, monitoring -> /metrics). C'est le
principe zero-trust / least privilege : en cas de compromission d'un pod,
l'attaquant ne peut pas se deplacer lateralement (ex: un frontend compromis ne
peut PAS joindre postgres). Prouve par le pod `intrus` dont tous les curl
timeout. Sans CNI compatible (cf. TP-5), les policies seraient inertes.

### 8. PSS baseline vs restricted : pourquoi ce melange ?

Pod Security Standards definit 3 profils via des labels de namespace. `baseline`
interdit le plus dangereux (privileged, hostNetwork...). `restricted` est le plus
strict (runAsNonRoot, drop ALL capabilities, readOnlyRootFilesystem, seccompProfile).
Le namespace est en `enforce: baseline` (plancher applique a TOUS les pods) +
`warn/audit: restricted` (signale sans bloquer ce qui ne respecte pas restricted).
Les workloads applicatifs stateless (nos 3 services) sont durcis restricted et
passent sans warning. Postgres ne peut pas facilement etre restricted (chown du
data dir au boot) : il reste baseline et genere un warning informatif. On enforce
donc le plancher que TOUT le monde tient, et on durcit au cas par cas ce qui le
supporte.

### 9. RBAC et ServiceAccount : quel interet de `automountServiceAccountToken: false` ?

Par defaut, chaque pod recoit automatiquement le token de son ServiceAccount monte
dans le conteneur (`/var/run/secrets/kubernetes.io/serviceaccount/token`). Si l'app
n'appelle jamais l'API Kubernetes (cas de catalogue, frontend, postgres), ce token
est une surface d'attaque inutile : un pod compromis pourrait s'en servir. On le
desactive donc (`automountServiceAccountToken: false`). Seul `orders-sa` garde le
token monte, car on lui a lie un Role `pod-reader` a titre demonstratif — et ce
Role est en lecture seule (`get/list/watch pods`), rien d'autre : least privilege.

### 10. CI : comment le push vers GHCR s'authentifie-t-il ?

Le workflow GitHub Actions utilise le `GITHUB_TOKEN` injecte automatiquement dans
chaque run, avec la permission `packages: write`. L'etape `docker/login-action`
se connecte a `ghcr.io` avec `github.actor` / `GITHUB_TOKEN`, puis `docker push`
envoie les images taggees `<sha7>` et `latest`. Ce push n'a lieu que sur `main`
(`if: github.ref == 'refs/heads/main'`) : sur une Pull Request, on build et on
scanne (Trivy) mais on ne publie pas. Pas de secret a gerer manuellement, le token
est ephemere et scope au repo.

### 11. Pourquoi le job deploy de la CI ne peut pas cibler un minikube local ?

Un runner GitHub heberge s'execute sur l'infra cloud de GitHub. Le kubeconfig du
projet pointe sur l'API server de minikube, accessible uniquement via une IP
privee de la VM docker locale de la machine de dev. Le runner cloud n'a aucune
route reseau vers cette IP : impossible de `kubectl apply`. Solutions reelles :
(a) un runner self-hosted installe dans le reseau du cluster, (b) un cluster
manage (EKS/GKE/AKS) joignable depuis le cloud avec des credentials en secret.
Ici on assume la limite : le deploiement est manuel via `scripts/deploy.sh`, et le
job `deploy` reste dans le workflow en `if: false` pour montrer ou il se brancherait.
