#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ ${1:-} == local ]]; then
  cd local
fi
set -a
. ./.env
set +a

if [[ ${1:-} == local ]]; then
  password=umami
  domain=${SPEXREGISTER_URL#*://}
  domain=${domain%%[:/]*}
  target="Spexregister web's .env.local"
else
  password=$(cat secrets/UMAMI_ADMIN_PASSWORD)
  domain=$SPEXREGISTER_WEB_HOST
  target="spexregister-deploy's .env"
fi

# Runs inside umami-server against its own port, so Umami needs no published route yet. The password arrives on
# stdin, never on a command line.
read -r -d '' script <<'EOF' || true
const [name, domain, target] = process.argv.slice(1);
let password = "";
for await (const chunk of process.stdin) password += chunk;

const call = async (path, body, token) => {
  const response = await fetch(`http://127.0.0.1:3000/api${path}`, {
    method: body ? "POST" : "GET",
    headers: {"Content-Type": "application/json", ...(token && {Authorization: `Bearer ${token}`})},
    body: body && JSON.stringify(body),
  });
  return {ok: response.ok, json: await response.json().catch(() => ({}))};
};
const login = async (password) => {
  const {ok, json} = await call("/auth/login", {username: "admin", password});
  return ok ? json : null;
};

let session = await login(password);
if (session) {
  console.log("kept admin password");
} else {
  const initial = await login("umami");
  if (!initial?.token) {
    console.error("cannot log in as admin, neither with secrets/UMAMI_ADMIN_PASSWORD nor with the initial password");
    process.exit(1);
  }
  const changed = await call("/me/password", {currentPassword: "umami", newPassword: password}, initial.token);
  if (!changed.ok) {
    console.error(`cannot change the admin password: ${JSON.stringify(changed.json)}`);
    process.exit(1);
  }
  console.log("updated admin password");
  session = await login(password);
}

if (!session?.token) {
  console.log("skipped websites: admin uses two-factor authentication, so add them in the dashboard");
  process.exit(0);
}

const {data = []} = (await call("/websites", null, session.token)).json;
let website = data.find((w) => w.domain === domain);
if (website) {
  console.log(`kept website ${name}`);
} else {
  website = (await call("/websites", {name, domain}, session.token)).json;
  console.log(`created website ${name}`);
}
console.log(`UMAMI_WEBSITE_ID=${website.id}   (${target})`);
EOF

printf '%s' "$password" | docker compose exec -T umami-server node --input-type=module -e "$script" \
  "${SPEXREGISTER_NAME:-Spexregister}" "$domain" "$target"
