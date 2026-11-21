# syntax=docker/dockerfile:1
# Builds the front-end repository (passed in as the named build context "app")
# and serves the static files with Caddy on port 8080.

FROM node:22-alpine AS build
WORKDIR /app
COPY --from=app package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
# Copy only what the build needs, so a local .env.local or node_modules never ends up in the image.
COPY --from=app index.html vite.config.js postcss.config.js ./
COPY --from=app src ./src
COPY --from=app public ./public
# Empty means the app calls the API on its own origin (/api/v1/...), which is what Caddy routes.
ARG VITE_API_URL=
ENV VITE_API_URL=${VITE_API_URL}
RUN npm run build

FROM caddy:2.10-alpine
COPY Caddyfile /etc/caddy/Caddyfile
COPY --from=build /app/dist /srv
EXPOSE 8080
