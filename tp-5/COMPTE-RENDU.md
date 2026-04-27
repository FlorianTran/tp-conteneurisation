# Compte-rendu TP5 : Namespaces, RBAC, quotas, PSS, NetworkPolicies

## Commandes executees

brew install minikube
minikube start -p tp5 --cni=calico --driver=docker
kubectl wait --for=condition=Ready pods -l k8s-app=calico-node -n kube-system --timeout=180s
kubectl apply -k k8s/overlays/dev/
kubectl apply -k k8s/overlays/staging/
kubectl apply -k k8s/overlays/prod/
kubectl get ns --show-labels | grep app-
kubectl get pods -A | grep -E "app-(dev|staging|prod)"
kubectl get resourcequota -A
kubectl get networkpolicy -n app-prod
openssl genrsa -out dev-user.key 2048
openssl req -new -key dev-user.key -subj "/CN=dev-user/O=developers" -out dev-user.csr
openssl x509 -req -in dev-user.csr -CA ~/.minikube/ca.crt -CAkey ~/.minikube/ca.key -CAcreateserial -out dev-user.crt -days 365
kubectl config set-credentials dev-user --client-certificate=dev-user.crt --client-key=dev-user.key
kubectl config set-context dev-user@tp5 --cluster=tp5 --user=dev-user
(idem pour qa-user et prod-deployer)
kubectl --context dev-user@tp5 auth can-i create deployment -n app-dev
kubectl --context dev-user@tp5 auth can-i get pods/log -n app-staging
kubectl --context dev-user@tp5 auth can-i get pods -n app-prod
kubectl --context qa-user@tp5 auth can-i patch deployment -n app-staging
kubectl --context qa-user@tp5 auth can-i create deployment -n app-staging
kubectl --context prod-deployer@tp5 auth can-i patch deployment -n app-prod
kubectl --context prod-deployer@tp5 auth can-i create --subresource=exec pods -n app-prod
kubectl run bad-pod --image=nginx -n app-prod
kubectl scale deployment demo-app --replicas=6 -n app-dev

## Probleme rencontre : NetworkPolicies non appliquees sans CNI

Au demarrage d'un profil minikube classique (sans --cni), les NetworkPolicies sont bien creees par l'API Kubernetes mais n'ont aucun effet. Le trafic passe entre namespaces meme quand une default-deny-all est presente. C'est parce que Kubernetes ne gere pas lui-meme le filtrage reseau : c'est le plugin CNI (Container Network Interface) qui se charge d'implementer les regles.

Contournement : demarrer un profil dedie avec Calico comme CNI, qui supporte les NetworkPolicies :
minikube start -p tp5 --cni=calico --driver=docker

Calico prend environ 60 secondes a initialiser tous ses pods dans le namespace kube-system. Les pods app-prod restent en ContainerCreating jusqu'a ce que calico-node soit Ready sur le noeud.

## Probleme rencontre : pod non-conforme PSS restricted refuse en prod

En essayant de lancer un pod nginx standard dans app-prod :
kubectl run bad-pod --image=nginx -n app-prod

Kubernetes refuse immediatement avec l'erreur suivante :
Error from server (Forbidden): pods "bad-pod" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "bad-pod" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "bad-pod" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "bad-pod" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "bad-pod" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")

C'est le comportement attendu. Le label pod-security.kubernetes.io/enforce: restricted sur le namespace app-prod bloque tout pod qui ne respecte pas les exigences du profil restricted : pas d'escalade de privileges, capabilities ALL droppees, runAsNonRoot, seccompProfile defini. L'image nginxinc/nginx-unprivileged:alpine repond a toutes ces contraintes.

## Probleme rencontre : quota depasse lors du scale

En tentant de scaler le deployment au-dela de la limite dans app-dev :
kubectl scale deployment demo-app --replicas=6 -n app-dev

Le ReplicaSet ne peut creer que jusqu'a 5 pods (quota pods: 5). Les pods supplementaires ne sont jamais crees et l'evenement indique :
Error creating: pods "demo-app-74664b45cc-2pnsh" is forbidden: exceeded quota: dev-quota, requested: pods=1, used: pods=5, limited: pods=5

Apres avoir ramene le deployment a 1 replica, les erreurs disparaissent.

## Logs

kubectl get ns --show-labels | grep app-
app-dev       Active   environment=dev,...,pod-security.kubernetes.io/enforce=baseline,...
app-staging   Active   environment=staging,...,pod-security.kubernetes.io/enforce=baseline,...
app-prod      Active   environment=prod,...,pod-security.kubernetes.io/enforce=restricted,...

kubectl get pods -A | grep -E "app-(dev|staging|prod)"
app-dev       demo-app-74664b45cc-5qkcj   1/1   Running   0   2m
app-prod      demo-app-74664b45cc-t259g   1/1   Running   0   2m
app-staging   demo-app-74664b45cc-d75jl   1/1   Running   0   2m

kubectl get resourcequota -A
NAMESPACE     NAME            REQUEST                                                        LIMIT
app-dev       dev-quota       pods: 1/5, requests.cpu: 100m/1, requests.memory: 128Mi/1Gi    limits.cpu: 200m/2, limits.memory: 256Mi/2Gi
app-staging   staging-quota   pods: 1/10, requests.cpu: 100m/2, requests.memory: 128Mi/2Gi   limits.cpu: 200m/4, limits.memory: 256Mi/4Gi
app-prod      prod-quota      pods: 1/20, requests.cpu: 100m/4, requests.memory: 128Mi/4Gi   limits.cpu: 200m/8, limits.memory: 256Mi/8Gi

kubectl get networkpolicy -n app-prod
NAME                  POD-SELECTOR   AGE
allow-dns-egress      <none>         2m
allow-ingress-nginx   <none>         2m
default-deny-all      <none>         2m

Tests RBAC :
dev-user@tp5 create deployment -n app-dev               yes
dev-user@tp5 delete deployment -n app-dev               yes
dev-user@tp5 get pods/log -n app-staging                yes
dev-user@tp5 get pods -n app-prod                       no
qa-user@tp5 patch deployment -n app-staging             yes
qa-user@tp5 create deployment -n app-staging            no
prod-deployer@tp5 patch deployment -n app-prod          yes
prod-deployer@tp5 create --subresource=exec pods -n app-prod   no
prod-deployer@tp5 get pods/log -n app-prod              yes

Test HTML servi par nginx :
curl http://demo-app-svc.app-dev.svc.cluster.local
<!DOCTYPE html>
<html>
<head><title>Demo App</title></head>
<body>
  <h1>Demo App</h1>
  <p>ENV: dev</p>
  <p>LOG: debug</p>
</body>
</html>

Test NetworkPolicy depuis app-dev vers app-prod :
curl -m 5 http://demo-app-svc.app-prod.svc.cluster.local
HTTP 000 time=5.003s   (timeout, trafic bloque par default-deny-all)

## Qu'est-ce qu'un namespace Kubernetes et pourquoi en creer plusieurs ?

Un namespace est une partition logique du cluster. Les ressources (pods, services, configmaps...) sont isolees par namespace : un pod dans app-dev ne peut pas acceder au service dans app-prod par son nom DNS court. Les quotas et les politiques RBAC s'appliquent par namespace, ce qui permet de donner des droits differents a chaque environnement. En production, on separe dev/staging/prod pour eviter qu'un bug ou une mauvaise manipulation en dev n'impacte la production.

## Qu'est-ce que Kustomize et pourquoi l'utiliser ici ?

Kustomize permet de gerer des variantes d'une meme configuration Kubernetes sans dupliquer les fichiers. On definit une base commune (deployment, service, configmap) et des overlays par environnement qui patchent ou ajoutent des ressources. La commande kubectl apply -k fusionne la base et l'overlay avant d'envoyer le tout a l'API. Sans Kustomize, il faudrait maintenir trois copies du deployment.yaml (une par env) et synchroniser chaque changement a la main, ce qui est une source d'erreur.

## Comment Kubernetes verifie-t-il l'identite d'un utilisateur ?

Kubernetes n'a pas de systeme d'utilisateurs interne. Il s'appuie sur des mecanismes externes. Le plus courant en local est le certificat x509 : l'utilisateur possede une cle privee et un certificat signe par la CA du cluster. Quand il envoie une requete kubectl, le certificat est presente en TLS. Kubernetes extrait le Common Name (CN) du certificat comme nom d'utilisateur et l'Organization (O) comme groupe. Il n'y a pas de commande pour creer un utilisateur Kubernetes : on genere juste un certificat et on configure kubectl avec kubectl config set-credentials.

## Quelle est la difference entre Role et ClusterRole ?

Un Role s'applique dans un namespace specifique. Il ne peut donner des droits que sur des ressources de ce namespace (pods, deployments, services...). Un ClusterRole s'applique a l'ensemble du cluster et peut couvrir des ressources globales (nodes, persistentvolumes, namespaces eux-memes). On utilise Role quand on veut confiner les droits d'un utilisateur a un environnement precis, et ClusterRole quand on gere des acces transversaux (ex: un operateur qui surveille tous les namespaces).

## Comment fonctionne RBAC dans Kubernetes ?

RBAC (Role-Based Access Control) repose sur trois objets : Role (ou ClusterRole) qui definit les permissions, Subject qui designe qui (user, group, serviceaccount), et RoleBinding (ou ClusterRoleBinding) qui associe le Role au Subject. Chaque requete kubectl passe par l'API server qui consulte les bindings pour verifier si l'utilisateur a le droit d'effectuer l'action demandee (verbe) sur la ressource cible dans le namespace concerne. Par defaut, tout est interdit : il faut explicitement accorder chaque droit.

## Qu'est-ce qu'un ResourceQuota et un LimitRange ?

Un ResourceQuota fixe des plafonds au niveau du namespace : nombre total de pods, CPU et memoire cumules de toutes les requetes/limits dans le namespace. Si le plafond est atteint, Kubernetes refuse de creer de nouveaux pods. Un LimitRange fixe des valeurs par defaut et des bornes au niveau du conteneur individuel : si un pod est cree sans requests/limits, le LimitRange les injecte automatiquement. Les deux se complementent : LimitRange evite les pods sans resources, ResourceQuota evite que le namespace consomme tout le cluster.

## Qu'est-ce que Pod Security Standards (PSS) ?

PSS est le mecanisme natif de Kubernetes (depuis 1.23) pour enforcer des profils de securite sur les pods. Il remplace PodSecurityPolicy, supprime depuis Kubernetes 1.25. Il definit trois profils : privileged (aucune restriction), baseline (interdictions minimales : pas de hostNetwork, pas de privileged containers...) et restricted (le plus strict : runAsNonRoot obligatoire, readOnlyRootFilesystem recommande, capabilities droppees, seccompProfile requis). Les profils s'appliquent via des labels sur le namespace. L'image nginxinc/nginx-unprivileged:alpine est pensee pour fonctionner sous le profil restricted.

## Pourquoi utiliser nginxinc/nginx-unprivileged plutot que nginx:alpine ?

L'image nginx officielle tourne en root (UID 0) et ecoute sur le port 80, ce qui est incompatible avec PSS restricted qui exige runAsNonRoot. nginxinc/nginx-unprivileged tourne avec l'UID 101 (utilisateur nginx) et ecoute sur le port 8080. Cela permet de satisfaire toutes les contraintes PSS restricted sans init container ni modification de la configuration nginx.

## Pourquoi la NetworkPolicy default-deny-all uniquement en prod ?

La strategie zero-trust (tout bloquer par defaut, n'ouvrir que ce qui est necessaire) est la bonne pratique en production car elle limite la surface d'attaque en cas de compromission d'un pod. En dev et staging, on privilegia la facilite de debug : un default-deny rendrait les tests de connectivite plus complexes et ralentirait le cycle de developpement. En prod, le trafic autorise est clairement identifie : entrees depuis l'ingress-nginx uniquement, sorties DNS uniquement.

## Difference entre PSS enforce, warn et audit ?

Les trois modes fonctionnent sur les memes profils mais ont des effets differents. enforce : le pod est refuse si il viole le profil, c'est le blocage reel. warn : un avertissement est affiche dans la reponse kubectl mais le pod est quand meme cree. audit : la violation est enregistree dans les logs d'audit du cluster mais rien n'est bloque ni affiche. On utilise souvent warn et audit sur le profil restricted dans des namespaces baseline : ca permet de detecter les pods non-conformes avant de durcir le namespace en enforce restricted.
