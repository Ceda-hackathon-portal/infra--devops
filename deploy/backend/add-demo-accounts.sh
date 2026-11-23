#!/usr/bin/env bash
# Adds fictional demo accounts to the live demo backend and aligns evaluator names with the proposal.
# Run on the server as deploy:  bash add-demo-accounts.sh
# Safe to re-run: existing emails are skipped. New passwords are written to ops/staging/private/new-logins.txt.
set -euo pipefail
cd /srv/ceda/Back-end/backend
P=ops/staging/private
TAG=$(grep '^API_IMAGE=' "$P/compose.env" | cut -d: -f2)
dc() { docker compose --env-file "$P/compose.env" -f ops/staging/compose.yml -f /srv/ceda/infra--devops/deploy/backend/compose.demo.yml "$@"; }
psqlq() { dc exec -T --user postgres postgres psql -v ON_ERROR_STOP=1 -tA -d ceda_staging "$@"; }

# email | display name | programme grants (empty = applicant)
NEW_ACCOUNTS=(
  'evaluator3@example.test|Evaluator Three|evaluation.write,evaluation.submit,eligibility.read-submission'
  'applicant2@example.test|Naledi Trading (applicant)|'
  'applicant3@example.test|Kgosi Agritech (applicant)|'
)

cp -p "$P/accounts.json" "$P/accounts.json.bak-$(date +%H%M%S)"
PROG=$(psqlq -c "select id from programmes where code='ICH-2026'" </dev/null)
ISSUER=$(psqlq -c "select id from users where email like 'provisioning-%@example.test' limit 1" </dev/null)
[ -n "$PROG" ] && [ -n "$ISSUER" ] || { echo "programme or provisioning user missing" >&2; exit 1; }

pwfile=$(mktemp); trap 'rm -f "$pwfile" /tmp/add-accounts.sql' EXIT
for _ in "${NEW_ACCOUNTS[@]}"; do openssl rand -base64 24 | tr -d '/+=' | cut -c1-24 >> "$pwfile"; done
hashfile=$(mktemp)
docker run --rm -i "ceda-migration:$TAG" node --input-type=module -e "
const m = await import('/app/dist/src/modules/auth/crypto.js'); let s = ''; for await (const c of process.stdin) s += c;
for (const pw of s.trim().split('\n')) console.log(m.localPasswordHash(pw));" < "$pwfile" > "$hashfile"

python3 - "$P" "$pwfile" "$hashfile" "${NEW_ACCOUNTS[@]}" > /tmp/add-accounts.sql <<'PY'
import sys, json, uuid
p, pwfile, hashfile, *new = sys.argv[1:]
pws = open(pwfile).read().split(); hashes = open(hashfile).read().split()
acc = json.load(open(f"{p}/accounts.json"))
renames = {"reviewer1@example.test": "Evaluator One", "reviewer2@example.test": "Evaluator Two"}
for a in acc:
    if a["email"] in renames: a["name"] = renames[a["email"]]
logins = []
for line, pw, h in zip(new, pws, hashes):
    email, name, grants = line.split("|")
    if any(a["email"] == email for a in acc): continue
    acc.append({"email": email, "name": name, "passwordHash": h})
    logins.append(f"{name}\n  Email:    {email}\n  Password: {pw}\n")
    if grants:
        uid = str(uuid.uuid4())
        print(f"INSERT INTO users (id,email,name,status) VALUES ('{uid}','{email}','{name}','ACTIVE');")
        print(f"INSERT INTO identities (id,issuer,subject,user_id) VALUES ('{uuid.uuid4()}','urn:ceda:local-development','{email}','{uid}');")
        for g in grants.split(","):
            print(f"INSERT INTO programme_grants (id,user_id,programme_id,permission,granted_by_id,granted_at) VALUES ('{uuid.uuid4()}','{uid}',:'prog','{g}',:'issuer',now());")
for old, new_name in renames.items():
    print(f"UPDATE users SET name='{new_name}' WHERE email='{old}';")
json.dump(acc, open(f"{p}/accounts.json", "w"), indent=2)
open(f"{p}/new-logins.txt", "w").write("\n".join(logins))
PY

{ echo "BEGIN;"; cat /tmp/add-accounts.sql; echo "COMMIT;"; } | psqlq -q -v prog="$PROG" -v issuer="$ISSUER"
echo "accounts in file: $(python3 -c "import json; print(len(json.load(open('$P/accounts.json'))))")"
psqlq -c "select rpad(u.name,28)||' '||rpad(u.email,28)||' '||coalesce(string_agg(g.permission, ',' order by g.permission),'(applicant)') from users u left join programme_grants g on g.user_id=u.id where u.email not like 'provisioning-%' group by u.name,u.email order by u.name" </dev/null
dc up -d --wait --force-recreate api </dev/null 2>&1 | tail -1
