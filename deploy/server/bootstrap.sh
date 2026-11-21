#!/usr/bin/env bash
# Same setup as cloud-init.yaml, for a server that was created without the cloud config.
# Run as root, in two phases so you can never lock yourself out:
#
#   ssh root@<IP> 'bash -s' < bootstrap.sh setup    # user, Docker, swap, ufw, updates. Root stays usable.
#   ssh deploy@<IP> true                            # prove the deploy user can log in with your key
#   ssh root@<IP> 'bash -s' < bootstrap.sh harden   # then turn off root and password logins
#
# Both phases are safe to re-run.
set -euo pipefail
phase="${1:-}"
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive

setup() {
  echo "== packages"
  apt-get update -q
  apt-get -y -q -o Dpkg::Options::=--force-confold upgrade
  apt-get install -y -q ca-certificates curl git ufw fail2ban unattended-upgrades

  echo "== deploy user (same SSH key as root)"
  id deploy >/dev/null 2>&1 || useradd --create-home --shell /bin/bash --groups sudo deploy
  passwd -l deploy >/dev/null
  install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
  install -m 600 -o deploy -g deploy /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys
  # No password exists, so sudo cannot ask for one. The SSH key is what protects the account.
  echo 'deploy ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-deploy
  chmod 440 /etc/sudoers.d/90-deploy
  visudo -cf /etc/sudoers.d/90-deploy

  echo "== swap"
  if ! swapon --show | grep -q /swapfile; then
    [ -f /swapfile ] || { fallocate -l 2G /swapfile; chmod 600 /swapfile; mkswap /swapfile; }
    swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi

  echo "== docker"
  install -d -m 755 /etc/docker
  echo '{ "log-driver": "local", "log-opts": { "max-size": "10m", "max-file": "3" } }' > /etc/docker/daemon.json
  if ! command -v docker >/dev/null; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -q
    apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  usermod -aG docker deploy
  systemctl enable --now docker
  systemctl restart docker

  echo "== ufw (second layer; the Hetzner Cloud Firewall is the real one)"
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 443/udp
  ufw --force enable

  echo "== app folder"
  install -d -o deploy -g deploy /srv/ceda

  echo "SETUP DONE. Now check: ssh deploy@<IP> true   then run the harden phase."
}

harden() {
  echo "== ssh hardening"
  [ -s /home/deploy/.ssh/authorized_keys ] || { echo "deploy has no key: refusing to harden" >&2; exit 1; }
  cat > /etc/ssh/sshd_config.d/10-ceda-hardening.conf <<'EOF'
# First value wins in sshd_config.d, so this file (10-) overrides 50-cloud-init.conf.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers deploy
MaxAuthTries 3
EOF
  sshd -t
  systemctl restart ssh
  date -Is > /var/lib/cloud/ceda-ready
  echo "HARDEN DONE. root and password logins are now refused."
}

case "$phase" in
  setup) setup ;;
  harden) harden ;;
  *) echo "usage: bootstrap.sh setup|harden" >&2; exit 2 ;;
esac
