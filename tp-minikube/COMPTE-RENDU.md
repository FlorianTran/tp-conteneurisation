# Compte-rendu TP Minikube

## Verifications de base

kubectl config current-context = minikube
kubectl get nodes = 1 noeud minikube en status Ready, Kubernetes v1.35.1
kubectl get pods -n tp-minikube = 1 pod web-nginx en status Running
kubectl get svc -n tp-minikube = service web-nginx-svc de type ClusterIP sur le port 80

## Contexte courant et nombre de noeuds ?

Contexte courant : minikube. 1 seul noeud (cluster local single-node).

## Image exacte utilisee ?

nginx:1.27 (digest nginx@sha256:6784fb...)

## Evenements confirmant le demarrage ?

Pulling image "nginx:1.27" puis Successfully pulled image, Container created, Container started.

## A quoi sert un Service dans Kubernetes ?

Un Service fournit un point d'acces reseau stable (IP + DNS interne) vers un ensemble de pods. Les pods sont ephemeres et changent d'IP, le Service abstrait ca en routant le trafic vers les pods qui matchent le selector.

## Pourquoi pas d'IP publique en local ?

Minikube tourne dans un container Docker, il n'a pas acces a un load balancer cloud. Le type ClusterIP n'est accessible que depuis l'interieur du cluster. Pour y acceder depuis l'hote on utilise minikube service --url qui cree un tunnel.

## Que se passe-t-il au niveau des pods lors d'un changement d'image ?

Kubernetes cree un nouveau pod avec la nouvelle image (nginx:1.26), attend qu'il soit Ready, puis termine l'ancien pod. C'est un rolling update par defaut.

## Qu'est-ce qu'un rollout ?

C'est le processus de deploiement progressif d'une nouvelle version. Ca permet de mettre a jour sans downtime et de revenir en arriere (kubectl rollout undo) si la nouvelle version pose probleme.

## Exposition du service

Utilisation de minikube service web-nginx-svc -n tp-minikube --url qui a renvoye http://127.0.0.1:54579. La page nginx par defaut s'affiche.

## Difficultes rencontrees

1. Le service est de type ClusterIP donc pas directement accessible depuis Windows. minikube service --url cree un tunnel pour le dev local, mais il faut le savoir.

2. Le terminal doit rester ouvert avec le driver Docker sur Windows pour que le tunnel reste actif. Si on le ferme, l'acces est perdu.
