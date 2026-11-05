#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
set -a
. ./.env
set +a

kcadm() { docker compose exec -T keycloak-server /opt/keycloak/bin/kcadm.sh "$@"; }
client_uuid() { kcadm get clients -r "$KEYCLOAK_REALM" -q clientId="$1" --fields id --format csv --noquotes | tr -d '\r'; }

kcadm config credentials \
  --server http://localhost:8080/auth \
  --realm master \
  --user "$KEYCLOAK_ADMIN" \
  --password "$(cat secrets/KEYCLOAK_ADMIN_PASSWORD)"

for secret in secrets/clients/*; do
  client=$(basename "$secret")
  uuid=$(client_uuid "$client")
  if [[ -z "$uuid" ]]; then
    echo "skipped $client secret: the realm has no such client, so KEYCLOAK_IMAGE is older than the realm needs"
    continue
  fi
  kcadm update "clients/$uuid" -r "$KEYCLOAK_REALM" -s "secret=$(cat "$secret")"
  echo "updated $client secret"
done

admin_uuid=$(client_uuid fgv-admin)
realm_management_uuid=$(client_uuid realm-management)
for role in query-users manage-users view-users view-clients manage-events; do
  kcadm add-roles -r "$KEYCLOAK_REALM" --uusername service-account-fgv-admin --cclientid realm-management --rolename "$role"
  kcadm get "clients/$realm_management_uuid/roles/$role" -r "$KEYCLOAK_REALM" \
    | sed '1s/^/[/; $s/$/]/' \
    | kcadm create "clients/$admin_uuid/scope-mappings/clients/$realm_management_uuid" -r "$KEYCLOAK_REALM" -f -
done
echo "updated fgv-admin realm-management roles"

web_clients=(spexregister fgv-revival fgv-spexify fgv-spexflix fgv-spexgram fgv-archive)
for client in "${web_clients[@]}"; do
  client_id=$(client_uuid "$client")
  for other in "${web_clients[@]}"; do
    [[ "$other" == "$client" ]] && continue
    other_id=$(client_uuid "$other")
    if [[ -z "$client_id" || -z "$other_id" ]]; then
      echo "skipped $client scope mapping to $other: the realm has no such client"
      continue
    fi
    kcadm get "clients/$other_id/roles/USER" -r "$KEYCLOAK_REALM" \
      | sed '1s/^/[/; $s/$/]/' \
      | kcadm create "clients/$client_id/scope-mappings/clients/$other_id" -r "$KEYCLOAK_REALM" -f -
  done
done
echo "updated the web clients' scope mappings to each other's USER role"

if [[ -n "${KEYCLOAK_THEME:-}" ]]; then
  kcadm update "realms/$KEYCLOAK_REALM" -s "loginTheme=$KEYCLOAK_THEME" -s "accountTheme=$KEYCLOAK_THEME" -s "emailTheme=$KEYCLOAK_THEME"
  echo "updated login, account and email theme to $KEYCLOAK_THEME"
fi

smtp=(
  -s "smtpServer.host=$SMTP_HOST"
  -s "smtpServer.port=$SMTP_PORT"
  -s "smtpServer.from=$MAIL_FROM"
  -s "smtpServer.auth=${SMTP_AUTH:-false}"
  -s "smtpServer.user=${SMTP_USER:-}"
  -s "smtpServer.starttls=${SMTP_STARTTLS:-false}"
  -s "smtpServer.ssl=${SMTP_SSL:-false}"
)
if [[ -s secrets/SMTP_PASSWORD ]]; then
  smtp+=(-s "smtpServer.password=$(cat secrets/SMTP_PASSWORD)")
fi
kcadm update "realms/$KEYCLOAK_REALM" "${smtp[@]}"
echo "updated mail settings ($SMTP_HOST:$SMTP_PORT)"
