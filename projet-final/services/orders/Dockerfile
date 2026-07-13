# Image multi-stage : deps de prod uniquement, user non-root (compatible PSS restricted).
FROM node:22-alpine AS deps
WORKDIR /app
COPY package*.json ./
RUN npm install --omit=dev --no-audit --no-fund

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY --from=deps /app/node_modules ./node_modules
COPY server.js ./
# node:alpine fournit l'utilisateur "node" (UID 1000). On tourne non-root.
USER node
EXPOSE 3000
CMD ["node", "server.js"]
