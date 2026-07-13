# tp-conteneurisation

Travaux pratiques et projet final du cours de **conteneurisation** (Docker &
Kubernetes). Le depot suit une progression : de l'optimisation d'une image Docker
(TP-1) jusqu'au deploiement et a l'exploitation d'une application microservices
complete sur Kubernetes (projet final).

Chaque dossier contient son propre `COMPTE-RENDU.md` : commandes brutes executees,
sections « Probleme rencontre » reellement vecues, logs colles, et questions
conceptuelles. Les comptes-rendus sont rediges en francais sans accents.

## Contenu

| Dossier | Sujet | Points cles |
|---|---|---|
| [`tp-1/`](tp-1/COMPTE-RENDU.md) | Docker - optimisation d'image | Dockerfile classique vs multi-stage, reduction de la taille d'image |
| [`tp-2/`](tp-2/COMPTE-RENDU.md) | Minikube | Premiers pas Kubernetes : Deployment + Service |
| [`tp-3/`](tp-3/COMPTE-RENDU.md) | Node + Docker Hub + K8s | Build/push d'une image sur un registry, deploiement sur minikube |
| [`tp-4/`](tp-4/COMPTE-RENDU.md) | App + MySQL sur Kubernetes | Secret/ConfigMap, PVC, Ingress, HPA, resilience |
| [`tp-5/`](tp-5/COMPTE-RENDU.md) | Namespaces, RBAC, quotas, PSS, NetworkPolicies | Multi-environnements (Kustomize), securite cluster, Calico |
| [`projet-final/`](projet-final/README.md) | **Projet final** : microservices sur K8s, operes de bout en bout | App 3 services + PostgreSQL, CI/CD, observabilite, HPA, securite zero-trust |

## Projet final (resume)

Application microservices (**frontend nginx + 2 APIs Node/Express + PostgreSQL**)
deployee sur minikube + Calico, couvrant l'ensemble du sujet :

- **Deploiement** : StatefulSet + PVC (Postgres), Deployments, service headless,
  Ingress path-routing, ConfigMap/Secret, liveness/readiness.
- **Scalabilite & resilience** : HPA (CPU), self-healing, rolling update + rollback.
- **CI/CD** : GitHub Actions (lint/test -> build -> scan Trivy -> push GHCR).
- **Observabilite** : kube-prometheus-stack, ServiceMonitor, alertes, logs JSON.
- **Securite** : NetworkPolicy zero-trust, RBAC, Pod Security Standards, secrets hors Git.

Detail complet, schema d'architecture et instructions de deploiement :
[`projet-final/README.md`](projet-final/README.md). Compte-rendu avec les vraies
sorties capturees : [`projet-final/COMPTE-RENDU.md`](projet-final/COMPTE-RENDU.md).

## Prerequis generaux

- Docker
- minikube + kubectl
- Node.js (pour les TP applicatifs)
- helm et trivy (projet final uniquement)

## CI

Le workflow [`.github/workflows/projet-final-ci.yml`](.github/workflows/projet-final-ci.yml)
est filtre sur `projet-final/**` : il ne se declenche que pour le projet final
(lint/test des APIs, build + scan Trivy des 3 images, push GHCR sur `main`).
