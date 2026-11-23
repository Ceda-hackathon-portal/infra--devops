#!/usr/bin/env bash
# Turns on applicant email for the demo backend. Run on the server as deploy:
#   bash enable-email.sh <image-tag> <frontend-origin>
# Expects ops/staging/private/smtp.env (SMTP_USER, SMTP_PASS, MAIL_REDIRECT_TO), copied by the operator.
# No value from smtp.env is ever printed. The file is deleted once merged into api.env.
set -euo pipefail
TAG="${1:?image tag}"; ORIGIN="${2:?frontend origin}"
cd /srv/ceda/Back-end/backend
P=ops/staging/private
dc() { docker compose --env-file "$P/compose.env" -f ops/staging/compose.yml -f /srv/ceda/infra--devops/deploy/backend/compose.demo.yml "$@"; }
[ -f "$P/smtp.env" ] || { echo "smtp.env not found in $P" >&2; exit 1; }
chmod 600 "$P/smtp.env"

python3 - "$P" "$ORIGIN" <<'PY'
import sys, re
p, origin = sys.argv[1:]
vals = {}
for line in open(f"{p}/smtp.env", encoding="utf-8-sig"):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1); vals[k.strip()] = v.strip().strip('"').strip("'")
missing = [k for k in ("SMTP_USER", "SMTP_PASS", "MAIL_REDIRECT_TO") if not vals.get(k)]
if missing: sys.exit("smtp.env is missing: " + ", ".join(missing))
email = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
for k in ("SMTP_USER", "MAIL_REDIRECT_TO"):
    if not email.match(vals[k]): sys.exit(f"{k} is not an email address")
pw = re.sub(r"\s+", "", vals["SMTP_PASS"])
if len(pw) != 16: print("warning: SMTP_PASS is not 16 characters; Gmail App Passwords are 16 letters")
new = {
    "SMTP_HOST": "smtp.gmail.com", "SMTP_PORT": "465", "SMTP_USER": vals["SMTP_USER"], "SMTP_PASS": pw,
    "MAIL_FROM": f"CEDA Innovation Portal <{vals['SMTP_USER']}>", "MAIL_REDIRECT_TO": vals["MAIL_REDIRECT_TO"],
    "MAIL_LINK_ORIGIN": origin,
}
lines = [l for l in open(f"{p}/api.env").read().splitlines() if l.split("=", 1)[0] not in new]
lines += [f"{k}={v.replace('$', '$$')}" for k, v in new.items()]   # compose env_file treats $ as a variable
open(f"{p}/api.env", "w").write("\n".join(lines) + "\n")
print("api.env updated with SMTP settings (values not shown)")
PY
rm -f "$P/smtp.env"

sed -i "s/^API_IMAGE=.*/API_IMAGE=ceda-backend:$TAG/; s/^MIGRATION_IMAGE=.*/MIGRATION_IMAGE=ceda-migration:$TAG/" "$P/compose.env"
echo "compose warnings: $(dc config 2>&1 >/dev/null </dev/null | grep -c 'not set' || true)"

echo "== test email (sent once, to MAIL_REDIRECT_TO)"
docker run --rm --env-file <(grep -E '^(SMTP_|MAIL_)' "$P/api.env" | sed 's/\$\$/$/g') "ceda-backend:$TAG" node --input-type=module -e "
import nodemailer from 'nodemailer';
const t = nodemailer.createTransport({ host: process.env.SMTP_HOST, port: Number(process.env.SMTP_PORT), secure: true,
  auth: { user: process.env.SMTP_USER, pass: process.env.SMTP_PASS } });
try { await t.verify(); await t.sendMail({ from: process.env.MAIL_FROM, to: process.env.MAIL_REDIRECT_TO,
  subject: 'CEDA portal: email is working', text: 'This test confirms the CEDA Innovation Portal can send applicant emails.' });
  console.log('test email sent'); }
catch (e) { console.log('SMTP failed:', e.code || 'error', e.responseCode || ''); process.exit(1); }" </dev/null

dc up -d --wait --force-recreate api </dev/null 2>&1 | tail -1
docker logs ceda-staging-api-1 2>&1 | grep -o '"enabled":[a-z]*' | tail -1
