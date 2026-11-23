#!/usr/bin/env bash
# Upgrades the demo backend to a new image tag: backup, build, migrate, re-apply grants, restart.
# Run on the server as deploy after /srv/ceda/Back-end is at the wanted commit:
#   bash upgrade-backend.sh <image-tag>
set -euo pipefail
TAG="${1:?image tag (short commit)}"
cd /srv/ceda/Back-end/backend
P=ops/staging/private
dc() { docker compose --env-file "$P/compose.env" -f ops/staging/compose.yml -f /srv/ceda/infra--devops/deploy/backend/compose.demo.yml "$@"; }

echo "== backup"
mkdir -p "$P/backups"
dc exec -T --user postgres postgres pg_dump -Fc -d ceda_staging </dev/null > "$P/backups/ceda_staging-$(date +%Y%m%d-%H%M%S).dump"
ls -1t "$P/backups" | head -1

echo "== images"
docker build -q --target runtime -t "ceda-backend:$TAG" . </dev/null >/dev/null
docker build -q --target migration -t "ceda-migration:$TAG" . </dev/null >/dev/null
sed -i "s/^API_IMAGE=.*/API_IMAGE=ceda-backend:$TAG/; s/^MIGRATION_IMAGE=.*/MIGRATION_IMAGE=ceda-migration:$TAG/" "$P/compose.env"

echo "== migrations"
dc --profile tools run --rm -T migration node node_modules/prisma/build/index.js migrate deploy </dev/null 2>&1 | tail -2

echo "== grants for new tables"
# runtime-role.sql cannot be re-run whole (it starts with CREATE ROLE), so apply the grants added after the first setup.
dc exec -T --user postgres postgres psql -v ON_ERROR_STOP=1 -q -d ceda_staging \
  -c "GRANT SELECT, INSERT ON applicant_credentials, registration_codes TO ceda_runtime;" \
  -c "GRANT UPDATE(attempts, consumed_at) ON registration_codes TO ceda_runtime;" </dev/null
dc exec -T --user postgres postgres psql -tA -d ceda_staging </dev/null \
  -c "select table_name||': '||string_agg(privilege_type, ',' order by privilege_type) from information_schema.role_table_grants where grantee='ceda_runtime' and table_name in ('applicant_credentials','registration_codes') group by table_name"

echo "== restart api"
dc up -d --wait --force-recreate api </dev/null 2>&1 | tail -1
docker logs ceda-staging-api-1 2>&1 | grep -oE '"enabled":(true|false),[^}]*"msg":"[a-z_]+"' | tail -3
