# Compte-rendu TP App MySQL + Kubernetes

## Commandes executees

minikube node add
kubectl get nodes
npm init -y
npm i express mysql2
docker build -t localhost:5000/tp-app-mysql:1.0.0 .
minikube addons enable registry
minikube addons enable ingress
minikube addons enable metrics-server
kubectl port-forward -n kube-system service/registry 5000:80
docker push localhost:5000/tp-app-mysql:1.0.0 (echec, voir section probleme)
minikube image load localhost:5000/tp-app-mysql:1.0.0
kubectl create namespace tp-app-mysql
kubectl apply -f k8s/mysql-secret.yaml
kubectl apply -f k8s/mysql-pvc.yaml
kubectl get pvc -n tp-app-mysql
kubectl apply -f k8s/app-configmap.yaml
kubectl apply -f k8s/mysql-deployment.yaml
kubectl apply -f k8s/mysql-service.yaml
kubectl apply -f k8s/app-deployment.yaml
kubectl apply -f k8s/app-service.yaml
kubectl apply -f k8s/app-ingress.yaml
kubectl apply -f k8s/app-hpa.yaml
kubectl get all -n tp-app-mysql
kubectl get pods -n tp-app-mysql -o wide
minikube service node-app-service -n tp-app-mysql --url
curl http://127.0.0.1:61776/
curl http://127.0.0.1:61776/health
kubectl logs -l app=node-app -n tp-app-mysql
kubectl delete pod -l app=node-app -n tp-app-mysql --wait=false
kubectl get pods -n tp-app-mysql
kubectl get hpa -n tp-app-mysql

## Probleme rencontre : push vers le registry minikube

Le TP indique de push l'image via docker push localhost:5000/tp-app-mysql:1.0.0 apres un port-forward du service registry. Sur Windows avec le driver Docker, ca ne fonctionne pas : le push reste bloque indefiniment en "Waiting". Minikube indique d'ailleurs a l'activation du registry que le port est 49282, pas 5000.

Contournement : on utilise minikube image load localhost:5000/tp-app-mysql:1.0.0 qui charge l'image directement dans le runtime du cluster sans passer par le registry. Il faut alors ajouter imagePullPolicy: IfNotPresent dans le deployment pour que Kubernetes utilise l'image locale au lieu de tenter un pull.

## Probleme rencontre : worker node NotReady

Apres minikube node add, le noeud minikube-m02 reste en NotReady. Minikube affiche un warning "Le cluster a ete cree sans aucun CNI, l'ajout d'un noeud peut provoquer un reseau inoperant". Le podAntiAffinity etant en mode preferred (et non required), les 2 pods node-app tournent sur le meme noeud minikube, ce qui n'est pas bloquant.

## Logs

kubectl get nodes
NAME           STATUS     ROLES           AGE     VERSION
minikube       Ready      control-plane   2d22h   v1.35.1
minikube-m02   NotReady   <none>          4m      v1.35.1

kubectl get all -n tp-app-mysql
pod/mysql-79b6c697b-sbjmj       1/1     Running
pod/node-app-5598b6fdcb-cmnt8   1/1     Running
pod/node-app-5598b6fdcb-wqtvz   1/1     Running
service/mysql              ClusterIP   None           3306/TCP
service/node-app-service   NodePort    10.111.6.251   80:30080/TCP
deployment.apps/mysql      1/1
deployment.apps/node-app   2/2

kubectl get pods -n tp-app-mysql -o wide
NAME                        READY   STATUS    NODE
mysql-79b6c697b-sbjmj       1/1     Running   minikube
node-app-5598b6fdcb-cmnt8   1/1     Running   minikube
node-app-5598b6fdcb-wqtvz   1/1     Running   minikube

curl http://127.0.0.1:61776/
{"message":"Connexion MySQL OK","time":"2026-04-02T21:07:29.000Z"}

curl http://127.0.0.1:61776/health
{"status":"ok"}

kubectl get pvc -n tp-app-mysql
NAME        STATUS   CAPACITY   ACCESS MODES   STORAGECLASS
mysql-pvc   Bound    1Gi        RWO            standard

kubectl get hpa -n tp-app-mysql
NAME           REFERENCE             TARGETS                         MINPODS   MAXPODS   REPLICAS
node-app-hpa   Deployment/node-app   cpu: <unknown>/50%, mem: /70%   2         6         2

Test de resilience :
kubectl delete pod -l app=node-app -n tp-app-mysql --wait=false
Les anciens pods passent en Terminating et 2 nouveaux pods sont recrees immediatement par le ReplicaSet.

## Quelle est la difference entre un Secret et un ConfigMap ?

Un Secret stocke des donnees sensibles (mots de passe, tokens) encodees en base64 et avec des restrictions d'acces. Un ConfigMap stocke des donnees non sensibles (config, variables d'env). On utilise Secret pour les credentials et ConfigMap pour le reste (host, port, etc.).

## Pourquoi MySQL replicas: 1 et l'app replicas: 2 ?

MySQL est stateful : il ecrit sur disque. Avoir 2 replicas MySQL avec un seul PVC causerait des corruptions de donnees (acces concurrent au meme volume). L'app Node.js est stateless, elle peut scaler horizontalement sans probleme car chaque instance se connecte a la meme base.

## Que se passe-t-il si on supprime le PVC et qu'on recree le pod MySQL ?

Les donnees sont perdues. Le PVC est le lien vers le volume persistant. Sans PVC, le nouveau pod demarre avec une base vide. C'est pour ca qu'il ne faut jamais supprimer un PVC en production sans backup.

## Role de podAntiAffinity

podAntiAffinity demande au scheduler de placer les pods sur des noeuds differents. En production, ca assure la haute disponibilite : si un noeud tombe, l'autre noeud a toujours un pod actif. Sans cette regle, le scheduler pourrait mettre tous les pods sur le meme noeud, et une panne de ce noeud entrainerait un downtime total.

## Difference entre ClusterIP, NodePort et LoadBalancer

ClusterIP : accessible uniquement depuis l'interieur du cluster. C'est le type par defaut, utilise pour la communication entre services (ex: app vers MySQL).
NodePort : expose le service sur un port fixe de chaque noeud (30000-32767). Accessible depuis l'exterieur via IP_NOEUD:PORT.
LoadBalancer : provisionne un load balancer externe (cloud). En local avec minikube ca ne fonctionne pas sans minikube tunnel.

## Pourquoi imagePullPolicy: IfNotPresent ici mais pas en prod ?

On a charge l'image directement dans minikube via minikube image load, donc il n'y a pas de registry a pull. imagePullPolicy: IfNotPresent dit a Kubernetes d'utiliser l'image locale si elle existe. En production, les images sont sur un registry (DockerHub, ECR, GCR...) et on veut toujours pull la derniere version pour s'assurer d'avoir le bon tag.

## Difference entre HPA et VPA

HPA (Horizontal) : ajoute ou supprime des pods en fonction de la charge. Scale horizontalement.
VPA (Vertical) : augmente ou diminue les resources (CPU/RAM) d'un pod existant. Scale verticalement.
Le HPA est prefere pour les apps stateless, le VPA pour les apps qui ne peuvent pas scaler horizontalement (comme une base de donnees).

## Pourquoi le scale down du HPA est plus lent que le scale up ?

Pour eviter le "flapping" : si le scale down etait aussi rapide que le scale up, on aurait des cycles rapides de creation/suppression de pods a chaque fluctuation de charge. Le delai (5 min par defaut) permet de s'assurer que la charge est vraiment redescendue durablement avant de supprimer des pods.

## Ingress : router /api et /admin vers des services differents

Il faudrait ajouter plusieurs paths dans les rules de l'Ingress :
- path: /api vers le service api-service
- path: /admin vers le service admin-service
Chaque path pointe vers un backend different avec son propre service et port.

## HTTPS avec certificat auto-signe

Il faudrait creer un Secret TLS contenant le certificat et la cle privee (kubectl create secret tls), puis referencer ce secret dans la section tls de l'Ingress. En production on utiliserait cert-manager pour automatiser le renouvellement avec Let's Encrypt.
