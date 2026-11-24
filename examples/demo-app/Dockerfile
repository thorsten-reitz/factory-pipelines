FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY server.js migrate.js health.js ./
COPY migrations ./migrations
# Konvention: Commit und Version ins Image, /health meldet sie (der Deploy prüft den Commit)
ARG GIT_COMMIT=unknown
ARG APP_VERSION=0.0.0
# Nur für den Rollback-Test: ein absichtlich kaputtes Image bauen
ARG BROKEN=0
ENV NODE_ENV=production APP_COMMIT=$GIT_COMMIT APP_VERSION=$APP_VERSION APP_BROKEN=$BROKEN
RUN mkdir -p /data/uploads && chown node:node /data/uploads
USER node
EXPOSE 3000
CMD ["node", "server.js"]
