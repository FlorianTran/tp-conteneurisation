# Compte-rendu TP Node + Docker Hub + K8s

## Commandes executees

npm init -y
npm i express
npm start
docker build -t tp-docker-hub-app .
docker images | grep tp-docker-hub-app
docker run --rm -p 3000:3000 tp-docker-hub-app
docker login
docker tag tp-docker-hub-app docker.io/xinferno/tp-docker-hub-app:1.0.0
docker push docker.io/xinferno/tp-docker-hub-app:1.0.0
minikube start --driver=docker
kubectl create secret generic regcred --from-file=.dockerconfigjson=~/.docker/config.json --type=kubernetes.io/dockerconfigjson
kubectl get secret regcred
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl get pods -o wide
kubectl describe pod -l app=tp-docker-hub-app
kubectl port-forward svc/tp-docker-hub-svc 8080:80
minikube addons enable metrics-server
kubectl apply -f k8s/hpa.yaml
kubectl get hpa

## Image Docker

docker images | grep tp-docker-hub-app = 199 MB (49 MB de contenu)
Image basee sur node:20-alpine, build multi-stage.

docker images | grep tp-docker-hub-app
tp-docker-hub-app                latest    e9f9d21c0eb0   199MB   49MB
xinferno/tp-docker-hub-app      1.0.0     e9f9d21c0eb0   199MB   49MB

## kubectl get pods -o wide (avant bonus, 1 replica)

kubectl get pods -o wide
NAME                                 READY   STATUS    RESTARTS   AGE   IP           NODE       NOMINATED NODE   READINESS GATES
tp-docker-hub-app-579b568bf7-7f5l6   1/1     Running   0          21s   10.244.0.6   minikube   <none>           <none>

## Acces web

Via kubectl port-forward svc/tp-docker-hub-svc 8080:80 ou minikube service tp-docker-hub-svc --url.
La page affiche "Bonjour depuis Node.js (conteneurise) !" et /healthz repond "ok".

kubectl port-forward svc/tp-docker-hub-svc 8080:80
Forwarding from 127.0.0.1:8080 -> 3000
Forwarding from [::1]:8080 -> 3000
Handling connection for 8080

## 3 optimisations du Dockerfile

1. Multi-stage build : le stage "deps" installe les dependances, le stage "runner" copie uniquement les node_modules sans garder le cache npm ni les outils de build. Ca separe le build du runtime.

2. Image alpine : node:20-alpine fait ~50 MB de base au lieu de ~1 GB pour node:20. Beaucoup moins de binaires inutiles.

3. Copie selective : on ne copie que server.js, public/ et package*.json dans l'image finale. Pas de fichiers de dev, pas de .git, pas de Dockerfile. Le .dockerignore empeche aussi node_modules de l'hote d'entrer dans le contexte.

## imagePullSecrets

imagePullSecrets permet a Kubernetes de s'authentifier aupres d'un registry prive pour pull l'image. Sans ca, le pull echoue avec ErrImagePull.
On l'a configure en creant un secret de type docker-registry depuis la config Docker locale (docker login stocke les credentials dans ~/.docker/config.json), puis en referencant ce secret dans le deployment avec imagePullSecrets: [{name: regcred}].

## Bonus

1. replicas passe a 2 : les 2 pods tournent en parallele, verifie avec kubectl get pods. Le rolling update remplace les pods un par un sans downtime.

2. resources ajoutes au deployment : requests 50m CPU / 64Mi RAM, limits 200m CPU / 128Mi RAM. Ca permet au scheduler de placer les pods correctement et d'eviter qu'un pod consomme toutes les ressources du noeud.

3. HorizontalPodAutoscaler : active via minikube addons enable metrics-server puis creation d'un hpa.yaml. Autoscale entre 2 et 5 replicas quand le CPU depasse 70% d'utilisation moyenne.

## kubectl get pods -o wide (apres bonus, 2 replicas + resources)

kubectl get pods -o wide
NAME                                 READY   STATUS    RESTARTS   AGE   IP            NODE       NOMINATED NODE   READINESS GATES
tp-docker-hub-app-86b7dd55c8-gkz5c   1/1     Running   0          10m   10.244.0.9    minikube   <none>           <none>
tp-docker-hub-app-86b7dd55c8-jbfdw   1/1     Running   0          10m   10.244.0.10   minikube   <none>           <none>

## kubectl get hpa (apres bonus)

kubectl get hpa
NAME                    REFERENCE                      TARGETS         MINPODS   MAXPODS   REPLICAS   AGE
tp-docker-hub-app-hpa   Deployment/tp-docker-hub-app   cpu: <unknown>/70%   2         5         2          15s
