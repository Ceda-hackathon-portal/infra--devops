# Demo deployment: one Hetzner server

The hackathon demo runs on one Ubuntu 24.04 server with Docker Compose behind one domain. This is separate from the AWS design in `terraform/`, which stays the production target in the proposal.

```text
Browser --HTTPS--> caddy (80/443, Let's Encrypt) --> frontend (static Vite build, :8080)
                               \--/api/*--> backend (later, once backend-api has code)
```

| File | Purpose |
| --- | --- |
| `compose.yaml` | Services. Only `caddy` publishes ports |
| `Caddyfile` | Edge: HTTPS, security headers, routing |
| `frontend/Dockerfile`, `frontend/Caddyfile` | Builds `front-end` and serves it with a fallback to `index.html` for client-side routes |
| `.env.example` | Settings. Copy to `.env` (never committed) |
| `deploy.sh` | Pull, rebuild, smoke check |
| `server/cloud-init.yaml` | First-boot hardening and Docker install |

## Rehearse on a laptop

Needs Docker and `front-end` cloned next to `infra--devops`.

```bash
cd infra--devops/deploy
printf 'SITE_ADDRESS=:80\nHTTP_PORT=8088\nHTTPS_PORT=8443\nFRONTEND_DIR=../../front-end\nVITE_API_URL=\n' > .env
docker compose up -d --build
curl -I http://localhost:8088/admin/reviews   # 200: deep links work
docker compose down
```

## Go live

Each step has a check. Don't move on until it passes.

1. **SSH key** on your laptop: `ls ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -C ceda-deploy`.
2. **Hetzner Cloud Firewall** `ceda-fw`, inbound: TCP 22, TCP 80, TCP 443, UDP 443 from any address. Outbound: leave open.
3. **Server**: Ubuntu 24.04, shared x86 (CX22 class), Nuremberg or Falkenstein, IPv4 on. Select your SSH key, attach `ceda-fw`, and paste `server/cloud-init.yaml` into Cloud config **after replacing the key line with your public key**.
   Check (wait 3–5 minutes after creation):
   ```bash
   ssh deploy@<IP> 'cloud-init status --wait; cat /var/lib/cloud/ceda-ready; docker version --format "{{.Server.Version}}"; free -h | grep Swap'
   ssh root@<IP> true   # must FAIL with "Permission denied"
   ```
   If `deploy` can't log in, use the Hetzner Console (web terminal) and reset the root password there.
4. **DNS at Porkbun**: delete the parking records (`*` CNAME/ALIAS and the root ALIAS). Add `A  ceda  <IP>  TTL 600`.
   Check: `nslookup ceda.<domain> 1.1.1.1` returns the IP. Don't start Caddy before this, or the certificate request fails and is retried.
5. **Code** on the server (both repositories are public, so the server needs no GitHub credentials):
   ```bash
   ssh deploy@<IP>
   cd /srv/ceda
   # Until this folder is merged into main, add: -b feature/hetzner-frontend-deploy
   git clone https://github.com/Ceda-hackathon-portal/infra--devops.git
   git clone https://github.com/Ceda-hackathon-portal/front-end.git
   cd infra--devops/deploy && cp .env.example .env && chmod 600 .env
   nano .env            # SITE_ADDRESS=ceda.<domain>
   ```
6. **Deploy**: `./deploy.sh`. Check: `/`, `/staff` and `/admin/reviews` all print `200`, then open `https://ceda.<domain>` on a phone.
7. **Snapshot** the server in the Hetzner Console once it works.

## Day to day

| Task | Command (in `/srv/ceda/infra--devops/deploy`) |
| --- | --- |
| Redeploy latest `main` | `./deploy.sh` |
| Freeze on a tag | `FRONTEND_REF=demo-v1 ./deploy.sh` |
| Logs | `docker compose logs -f caddy` |
| Status | `docker compose ps` |

Never run `docker compose down -v`: it deletes the certificate volume, and Let's Encrypt limits how often the same certificate can be reissued.
