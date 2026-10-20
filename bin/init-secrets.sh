#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
umask 077
mkdir -p secrets/clients

generate() {
  local name=$1 value=$2
  if [[ -s secrets/$name ]]; then
    echo "keep secrets/$name"
  else
    printf '%s' "$value" > "secrets/$name"
    echo "created secrets/$name"
  fi
}

random() { openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | head -c "$1"; }

generate KEYCLOAK_MYSQL_ROOT_PASSWORD "$(random 32)"
generate KEYCLOAK_MYSQL_USER_PASSWORD "$(random 32)"
generate KEYCLOAK_ADMIN_PASSWORD "$(random 24)"
generate UMAMI_POSTGRES_PASSWORD "$(random 32)"
generate UMAMI_ADMIN_PASSWORD "$(random 24)"
generate UMAMI_APP_SECRET "$(random 48)"
generate UMAMI_TWO_FACTOR_ENCRYPTION_KEY "$(openssl rand -hex 32)"

# Client secrets, set in the realm by bin/configure-keycloak.sh and copied by the applications' bin/init-secrets.sh
for client in fgv-admin spexregister fgv-revival fgv-revival-service; do
  generate "clients/$client" "$(random 32)"
done

if [[ ! -e secrets/SMTP_PASSWORD ]]; then
  : > secrets/SMTP_PASSWORD
  echo "created secrets/SMTP_PASSWORD (empty, write the SMTP password into it if the relay needs one)"
fi

if [[ ! -e secrets/TURNSTILE_SECRET_KEY ]]; then
  : > secrets/TURNSTILE_SECRET_KEY
  echo "created secrets/TURNSTILE_SECRET_KEY (empty, write the Turnstile secret key into it)"
fi

if [[ ! -s secrets/cloudflared.env ]]; then
  printf 'TUNNEL_TOKEN=\n' > secrets/cloudflared.env
  echo "created secrets/cloudflared.env (paste the tunnel token into it)"
fi

chmod 700 secrets secrets/clients
find secrets -maxdepth 1 -type f ! -name '*.env' -exec chmod 644 {} +
chmod 600 secrets/*.env secrets/clients/*
