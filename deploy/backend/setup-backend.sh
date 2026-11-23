#!/usr/bin/env bash
# One-time setup of backend-api on the demo server, following Back-end/backend/docs/AWS_STAGING.md.
# Run as the deploy user:  bash setup-backend.sh <frontend-https-origin> <api-host> <image-tag>
# Every secret is generated here and stays in ops/staging/private (mode 700). Nothing secret is printed,
# except demo-logins.txt (fictional demo accounts) which is written for the operator to hand to judges.
set -euo pipefail

FRONTEND="${1:?frontend origin, e.g. https://ceda-innovation-portal-phi.vercel.app}"
API_HOST="${2:?api host, e.g. 157-180-38-228.sslip.io}"
TAG="${3:?image tag}"
BACKEND=/srv/ceda/Back-end/backend
OVERRIDE=/srv/ceda/infra--devops/deploy/backend/compose.demo.yml
P="$BACKEND/ops/staging/private"
cd "$BACKEND"
dc() { docker compose --env-file ops/staging/private/compose.env -f ops/staging/compose.yml -f "$OVERRIDE" "$@"; }
hex() { openssl rand -hex 32; }

[ -e "$P/api.env" ] && { echo "Already set up ($P exists). Refusing to overwrite secrets." >&2; exit 1; }
umask 077
mkdir -p "$P"

echo "== secrets and TLS"
hex > "$P/postgres_password"
sh ops/staging/create-db-tls.sh "$P/tls" >/dev/null
PG_UID=$(docker run --rm --entrypoint id postgres:17-bookworm -u postgres)
PG_GID=$(docker run --rm --entrypoint id postgres:17-bookworm -g postgres)
sudo chown "$PG_UID:$PG_GID" "$P/tls/server.key" && sudo chmod 600 "$P/tls/server.key"
MIG_PW=$(hex); APP_PW=$(hex); ASG_PW=$(hex)
APPLICANT_PW=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-28)
APPLICANT_HASH=$(docker run --rm -e PW="$APPLICANT_PW" "ceda-migration:$TAG" node --input-type=module -e \
  "const m = await import('/app/dist/src/modules/auth/crypto.js'); console.log(m.localPasswordHash(process.env.PW));")

cat > "$P/compose.env" <<EOF
API_IMAGE=ceda-backend:$TAG
MIGRATION_IMAGE=ceda-migration:$TAG
POSTGRES_IMAGE=postgres:17-bookworm
CADDY_IMAGE=caddy:2.10-alpine
API_HOST=$API_HOST
# Required by the base compose file; our Caddyfile does not send a contact email.
ACME_EMAIL=unused@invalid.test
EOF

cat > "$P/migration.env" <<EOF
DATABASE_URL=postgresql://ceda_migrator:$MIG_PW@postgres:5432/ceda_staging?sslmode=require&sslaccept=strict&sslcert=/run/db/ca.crt
EOF

cat > "$P/api.env" <<EOF
DATABASE_URL=postgresql://ceda_app:$APP_PW@postgres:5432/ceda_staging
ASSIGNMENT_DATABASE_URL=postgresql://ceda_assigner:$ASG_PW@postgres:5432/ceda_staging
DATABASE_POOL_MAX=5
ALLOWED_ORIGINS=$FRONTEND
AUTH_MODE=local
AUTH_LOCAL_PUBLIC_DEMO=true
AUTH_API_ORIGIN=$FRONTEND
AUTH_FRONTEND_ORIGIN=$FRONTEND
AUTH_ENCRYPTION_KEY=$(hex)
AUTH_LOCAL_EMAIL=applicant@example.test
AUTH_LOCAL_NAME=Demo Applicant
AUTH_LOCAL_PASSWORD_HASH=$APPLICANT_HASH
OFFICER_READ_API_ENABLED=true
SESSION_IDLE_SECONDS=3600
SESSION_ABSOLUTE_SECONDS=28800
LOG_LEVEL=info
EOF
echo '[]' > "$P/accounts.json"   # replaced by provisioning below
dc config --quiet

echo "== postgres"
dc up -d --wait postgres
dc exec -T --user postgres postgres psql -v ON_ERROR_STOP=1 -q -d ceda_staging <<EOF
CREATE ROLE ceda_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD '$MIG_PW';
CREATE ROLE ceda_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD '$APP_PW';
CREATE ROLE ceda_assigner LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD '$ASG_PW';
ALTER SCHEMA public OWNER TO ceda_migrator;
EOF

echo "== migrations"
dc --profile tools run --rm -T migration node node_modules/prisma/build/index.js migrate deploy | tail -2

echo "== runtime and assignment roles"
dc exec -T --user postgres postgres psql -v ON_ERROR_STOP=1 -q -d ceda_staging < ops/runtime-role.sql
dc exec -T --user postgres postgres psql -v ON_ERROR_STOP=1 -q -d ceda_staging < ops/assignment-provisioner-role.sql
dc exec -T --user postgres postgres psql -v ON_ERROR_STOP=1 -q -d ceda_staging \
  -c "GRANT ceda_runtime TO ceda_app; GRANT ceda_assignment_manager TO ceda_assigner;"

echo "== programme and staff accounts"
PG_CONTAINER=$(dc ps -q postgres)
docker run --rm --network "container:$PG_CONTAINER" -v "$P:/out" --user "$(id -u):$(id -g)" \
  -e "DATABASE_URL=postgresql://ceda_migrator:$MIG_PW@127.0.0.1:5432/ceda_staging?sslmode=no-verify" \
  "ceda-migration:$TAG" node scripts/provision-local.mjs /out/accounts.json /out/staff-logins.txt
{ echo "Demo applicant: applicant@example.test  password: $APPLICANT_PW"; tr -d '\r' < "$P/staff-logins.txt"; } > "$P/demo-logins.txt"

echo "== uploads volume, api and proxy"
docker volume create ceda-staging_application_files >/dev/null
docker run --rm -v ceda-staging_application_files:/data alpine:3.21 sh -c 'mkdir -p /data/application-files && chown -R 1000:1000 /data'
dc up -d --wait api proxy
dc ps --format 'table {{.Service}}\t{{.Status}}'
echo "SETUP DONE"
