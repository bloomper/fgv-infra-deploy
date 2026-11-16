#!/usr/bin/env bash
# Creates the sample users of sample-users.tsv in the realm, with their fixed ids, names and client roles, or resets
# them to it: an existing sample user is replaced (Keycloak's partial import, OVERWRITE), so the roles are exactly the
# table's afterwards. No other user is touched. The applications' sample data uses the same ids as constants, so it
# never asks Keycloak, and the applications can import it in any order.
#
#   bin/seed-users.sh           the stack in this directory (staging; refused when DEPLOY_ENV=production)
#   bin/seed-users.sh --local   the local stack in local/
#
# The password of every sample user is secrets/SAMPLE_USER_PASSWORD (made by bin/init-secrets.sh), or s3cr3t-s3cr3t
# locally. The admin notification listener is off meanwhile, so no one is emailed about the sample users.
set -euo pipefail

cd "$(dirname "$0")/.."
root=$PWD
users_file=$root/sample-users.tsv
listener=fgv-admin-notification

if [[ ${1:-} == --local ]]; then
  cd local
  admin_password=$(cat .docker/secrets/KEYCLOAK_ADMIN_PASSWORD)
  sample_password=s3cr3t-s3cr3t
else
  admin_password=$(cat secrets/KEYCLOAK_ADMIN_PASSWORD)
  sample_password=$(cat secrets/SAMPLE_USER_PASSWORD 2>/dev/null || true)
fi
set -a
. ./.env
set +a
realm=${KEYCLOAK_REALM:-fgv}

if [[ ${DEPLOY_ENV:-} == production ]]; then
  echo "refusing: production has no sample users" >&2
  exit 1
fi
if [[ -z $sample_password || $sample_password == CHANGE_ME ]]; then
  echo "missing secrets/SAMPLE_USER_PASSWORD: run bin/init-secrets.sh first" >&2
  exit 1
fi

kcadm() { docker compose exec -T keycloak-server /opt/keycloak/bin/kcadm.sh "$@"; }

json_string() {
  local value=${1//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}

# The users as a partial import: [{id, username, email, names, enabled, password, clientRoles}, ...]
users_json() {
  local first=true id email first_name last_name enabled roles grant client role_list
  printf '{"ifResourceExists":"OVERWRITE","users":['
  while IFS=$'\t' read -r id email first_name last_name enabled roles; do
    [[ -z $id || $id == \#* ]] && continue
    $first || printf ','
    first=false
    printf '{"id":%s,"username":%s,"email":%s,"emailVerified":true,"firstName":%s,"lastName":%s,"enabled":%s,' \
      "$(json_string "$id")" "$(json_string "$email")" "$(json_string "$email")" \
      "$(json_string "$first_name")" "$(json_string "$last_name")" "$enabled"
    printf '"credentials":[{"type":"password","value":%s,"temporary":false}],"clientRoles":{' "$(json_string "$sample_password")"
    local first_client=true
    if [[ $roles != - ]]; then
      for grant in $roles; do
        client=${grant%%:*}
        role_list=${grant#*:}
        $first_client || printf ','
        first_client=false
        printf '%s:["%s"]' "$(json_string "$client")" "${role_list//,/\",\"}"
      done
    fi
    printf '}}'
  done < "$users_file"
  printf ']}'
}

kcadm config credentials --server http://localhost:8080/auth --realm master --user "$KEYCLOAK_ADMIN" --password "$admin_password"

listeners=$(kcadm get events/config -r "$realm" --fields eventsListeners --format csv --noquotes | tr -d '\r')
if [[ ,$listeners, == *,$listener,* ]]; then
  without=$(printf '%s' "$listeners" | tr ',' '\n' | grep -vx "$listener" | sed 's/.*/"&"/' | paste -sd, -)
  kcadm update events/config -r "$realm" -b "{\"eventsListeners\":[${without}]}"
  restore() {
    kcadm update events/config -r "$realm" -b "{\"eventsListeners\":[$(printf '%s' "$listeners" | sed 's/[^,]*/"&"/g')]}" \
      && echo "turned $listener back on" \
      || echo "could not turn $listener back on: add it under Realm settings -> Events -> Event listeners" >&2
  }
  trap restore EXIT
  echo "turned $listener off"
fi

users_json | kcadm create partialImport -r "$realm" -f - -o
echo "seeded $(grep -cv '^#' "$users_file") sample users in realm $realm"
