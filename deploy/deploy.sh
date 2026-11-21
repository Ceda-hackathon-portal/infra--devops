#!/usr/bin/env bash
# Pull the latest code and rebuild. Run on the server as the deploy user:
#   /srv/ceda/infra--devops/deploy/deploy.sh            # deploy what each repo's checked-out branch has
#   FRONTEND_REF=demo-v1 ./deploy.sh                    # deploy a tag or commit (code freeze)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
[ -f .env ] || { echo "deploy/.env is missing: copy .env.example and fill it in" >&2; exit 1; }
# shellcheck disable=SC1091
set -a; . ./.env; set +a
frontend="$(cd "$here/${FRONTEND_DIR:-../../front-end}" && pwd)"

update() { # repo-dir [ref]
  git -C "$1" fetch --tags --prune --quiet origin
  if [ -n "${2:-}" ]; then
    git -C "$1" checkout --quiet --detach "$2"
  else
    git -C "$1" pull --ff-only --quiet
  fi
  echo "$(basename "$1"): $(git -C "$1" log -1 --format='%h %s')"
}

update "$here/.."
update "$frontend" "${FRONTEND_REF:-}"

docker compose up -d --build --remove-orphans
docker image prune -f >/dev/null

# Smoke check through the public URL (or the local port during a rehearsal).
if [ "${SITE_ADDRESS}" = ":80" ]; then url="http://127.0.0.1:${HTTP_PORT:-80}"; else url="https://${SITE_ADDRESS}"; fi
for path in / /staff /admin/reviews; do
  printf '%-16s %s\n' "$path" "$(curl -s -o /dev/null -w '%{http_code}' --retry 10 --retry-delay 2 --retry-all-errors "$url$path")"
done
docker compose ps
