# Compte-rendu TP Docker - Optimisation d'image

## Poids des images

tp-docker:classic = 1.61 GB
tp-docker:multistage = 296 MB
Reduction d'environ 80%.

## Quel est le poids de tp-docker:classic ?

1.61 GB.

## Qu'est-ce qui gonfle l'image ?

L'image de base node:20 est une Debian complete avec gcc, make, python, git, etc. On embarque aussi les devDependencies (eslint) qui ne servent pas au runtime.

## Pourquoi node_modules dans le .dockerignore ?

Ca evite de copier les node_modules de la machine hote dans le contexte Docker. Les modules doivent etre installes dans le container via npm ci pour garantir la compatibilite avec Linux. Ca accelere aussi le build.

## Ecart de poids classic vs multistage ?

~1.3 GB de difference (1.61 GB vers 296 MB).

## Qu'est-ce qui a ete supprime dans le stage runtime ?

Les devDependencies ne sont pas installees (npm ci --omit=dev), l'image de base node:20-slim ne contient pas les outils de compilation, et les fichiers intermediaires de build ne sont pas copies dans l'image finale.

## Surface d'attaque reduite ?

Oui. Moins de binaires installes = moins de CVE potentielles. node:20-slim ne contient pas gcc, make, curl, wget, ce qui limite ce qu'un attaquant pourrait faire avec un shell dans le container.

## Quelles etapes creent les plus gros layers ?

Dans le classic, c'est l'image de base Debian (~619 MB pour apt, ~194 MB pour les libs, ~175 MB pour Node). Cote app, c'est npm ci (~25.7 MB).

## Comment copier package*.json avant le reste aide le cache ?

Docker invalide le cache d'un layer des qu'un fichier copie change. En copiant package*.json separement et en faisant npm ci juste apres, ce layer est en cache tant que les dependances ne changent pas. Les modifs du code source ne declenchent pas un reinstall des deps.

## Amelioration possible en production

Utiliser node:20-alpine au lieu de node:20-slim pour reduire encore la taille (~50 MB de base au lieu de ~220 MB). Attention aux incompatibilites potentielles avec les modules natifs (musl vs glibc).
