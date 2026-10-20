# FGV Infra Deploy

Docker Compose setup for the infrastructure that FGV's applications share on a single host, published through a
Cloudflare Tunnel: Keycloak (realm `fgv`), which every FGV application logs in through, its MySQL, the shared Docker
network and, on staging, Mailpit. Each application has its own deploy repository:

| Repository               | Runs                                                           |
|--------------------------|----------------------------------------------------------------|
| `fgv-infra-deploy`       | Keycloak, its database, the shared network, Mailpit on staging |
| [spexregister-deploy][1] | Spexregister server, web and database                          |
| [fgv-revival-deploy][2]  | Nyuppsättning server, web and database                           |

```
Browser ──https──▶ Cloudflare ──tunnel──▶ cloudflared ─┬─▶ keycloak-server:8080  (KEYCLOAK_HOST)
                                                       └─▶ mailpit:8025          (MAIL_HOST, staging only)

                                   network fgv-<DEPLOY_ENV>
spexregister-deploy: spexregister-api ──┐
                                        ├──▶ keycloak-server:8080 ──▶ keycloak-mysql
fgv-revival-deploy:  revival-api ───────┘
                     revival-api ───────▶ spexregister-api:8080
```

This repository creates the Docker network `fgv-<DEPLOY_ENV>`. The applications' API containers join it to reach
Keycloak as `keycloak-server:8080` (signing keys, admin API) and, on staging, Mailpit as `mailpit:1025`. FGV
Revival also reaches Spexregister's API on it as `spexregister-api:8080`. Browsers and the web containers use
Keycloak's public address, `https://KEYCLOAK_HOST/auth`. Start this repository first. The applications refuse to start
while the network is missing.

Every service is named after what it runs and its role (`keycloak-server`, `spexregister-api`, `revival-api`), so
names on the shared network say where they come from. Mailpit catches every application's mail on staging and is
just `mailpit`. The Compose projects are `fgv-infra-<DEPLOY_ENV>`, `fgv-spexregister-<DEPLOY_ENV>` and
`fgv-revival-<DEPLOY_ENV>`, so that they stand apart from other projects on the host, and Compose prefixes volumes
and the project's own network with them, e.g. `fgv-infra-staging_keycloak_mysql_data`. Services don't repeat
`fgv-`.

## Files

| File                          | Purpose                                                                    |
|-------------------------------|----------------------------------------------------------------------------|
| `compose.yaml`                | Keycloak and MySQL, configured entirely from `.env`                        |
| `compose.tunnel.yaml`         | `cloudflared` connector, for hosts published through a Cloudflare Tunnel   |
| `compose.staging.yaml`        | Staging additions: Mailpit catches all outgoing mail                       |
| `staging.env.example`         | Template for `.env` on the staging host                                    |
| `production.env.example`      | Template for `.env` on the production host                                 |
| `bin/init-secrets.sh`         | Generates random secrets into `secrets/` (never overwrites existing ones)  |
| `bin/configure-keycloak.sh`   | Sets client secrets, theme and mail settings in the realm                  |
| `bin/backup-db.sh`            | Dumps the database into `backups/`, pruning dumps older than 14 days       |
| `local/`                      | The local development stack, see *Local development*                       |

`COMPOSE_FILE` in `.env` selects the overlays, so plain `docker compose ...` commands work on each host.

| `.env` variable  | Image                   | Source repo       |
|------------------|-------------------------|-------------------|
| `KEYCLOAK_IMAGE` | `bloomper/fgv-keycloak` | [fgv-keycloak][3] |

The image contains the SPI providers, the FGV theme and the realm import file `fgv.json`.

## 1. Host

Ubuntu Server 26.04 LTS (or Debian 13) on the server. Install without a desktop, enable OpenSSH, then:

```shell
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"            # log out and in again
sudo apt install -y unattended-upgrades git
```

In BIOS, set *Power → After Power Loss* to *Power On* so the box comes back after a power cut. All containers
use `restart: unless-stopped`.

## 2. Cloudflare

The domain's DNS must be hosted on Cloudflare. Use single-level subdomains such as
`register-staging-auth.example.org`. A name like `auth.register.example.org` is two levels deep, and the free
Universal SSL certificate doesn't cover it.

1. Networking → Tunnels → *Create a tunnel* → Cloudflared. Name it e.g. `fgv-infra-staging`. Each deploy
   repository has its own tunnel.
2. Copy the token from the install command (the long string after `--token`).
3. On the tunnel's **Routes** tab, select *Add route* → *Published application* once for each row below.
   Enter the hostname as subdomain plus domain, and the service in **Service URL**. Cloudflare creates the
   DNS records itself.

   | Hostname        | Service URL                          |
   |-----------------|--------------------------------------|
   | `KEYCLOAK_HOST` | `http://keycloak-server:8080`        |
   | `MAIL_HOST`     | `http://mailpit:8025` (staging only) |

4. Restrict who can reach the admin console and Mailpit with Cloudflare Access. See *Cloudflare Access* below.
5. Open *Turnstile* in the dashboard and select *Add widget*. Name it e.g. `keycloak-staging`, add `KEYCLOAK_HOST` as
   hostname and choose *Managed* as widget mode. Put the site key in `TURNSTILE_SITE_KEY` in `.env` and the
   secret key in `secrets/TURNSTILE_SECRET_KEY` (see section 3 below).

### Cloudflare Access

Access puts a Cloudflare login in front of a hostname or path before any request reaches the tunnel. The Free
plan covers up to 50 users. Visitors log in with a one-time PIN sent to their email, so they need no account.

**One-time setup:** open **Zero Trust** in the dashboard. On first use you're asked for a team name (becomes
`<team>.cloudflareaccess.com`) and a plan; choose Free. A payment method may be required even on Free. Check
that **One-time PIN** is listed as a login method under **Integrations → Identity providers**, and add it if
not.

**Application:** go to **Zero Trust → Access controls → Applications → Add an application → Self-hosted**.
An application with no policy denies everyone.

| Application   | Destinations                                    | Allow policy          |
|---------------|-------------------------------------------------|-----------------------|
| FGV admin     | `MAIL_HOST`, `KEYCLOAK_HOST` with path `auth/admin` | *Emails*: your own address |

Leave the rest of `KEYCLOAK_HOST` unprotected. The applications' web containers call Keycloak's token and userinfo
endpoints server-side through `https://KEYCLOAK_HOST`. They have no Access cookie, so login breaks if Access covers
those paths. The applications' API containers use the admin API through `keycloak-server:8080`, so Access on
`auth/admin` doesn't affect them.

## 3. Checkout and configuration

Check the deploy repositories out next to each other, e.g. in the host user's home directory. The applications'
`bin/init-secrets.sh` copy their client secrets from `../fgv-infra-deploy/secrets/clients/`.

```shell
git clone https://github.com/bloomper/fgv-infra-deploy.git
cd fgv-infra-deploy

cp staging.env.example .env               # set the hostnames, email addresses and TURNSTILE_SITE_KEY
bin/init-secrets.sh
nano secrets/cloudflared.env              # TUNNEL_TOKEN=<token from step 2>
printf '%s' '<secret key>' > secrets/TURNSTILE_SECRET_KEY
```

`.env` names every application that logs in through the realm, because Keycloak needs each one's address:

| Variable                | Purpose                                                       |
|-------------------------|---------------------------------------------------------------|
| `SPEXREGISTER_NAME`     | Name of the `spexregister` client, shown on login and in the approval email |
| `SPEXREGISTER_WEB_HOST` | Spexregister's `WEB_HOST`: the only redirect target after login and logout |
| `SPEXREGISTER_API_HOST` | Spexregister's `API_HOST`: audience in tokens for `spexregister-mcp` |
| `FGV_REVIVAL_NAME`      | Name of the `fgv-revival` client                              |
| `FGV_REVIVAL_WEB_HOST`  | Nyuppsättning's `WEB_HOST`                                      |
| `FGV_REVIVAL_API_HOST`  | Nyuppsättning's `API_HOST`: audience in tokens for `fgv-revival-mcp` |

## 4. First start

```shell
docker compose up -d                      # Keycloak, MySQL and, on staging, Mailpit
docker compose ps keycloak-server         # wait for "healthy"
bin/configure-keycloak.sh
```

Keycloak imports `fgv.json` only when the realm doesn't exist yet. Then `configure-keycloak.sh` makes these
changes:

- sets the secret of each client in `secrets/clients/` (`fgv-admin`, `spexregister`, `fgv-revival`,
  `fgv-revival-service`). The secrets in `fgv.json` are public
- selects `KEYCLOAK_THEME` as the realm's login, account and email theme
- sets the realm's mail settings from the `SMTP_*` variables, `MAIL_FROM` and `secrets/SMTP_PASSWORD`

You can run it again safely. Everything else comes from `fgv.json`, which reads the names and addresses of the
applications from the variables above.

Then start the applications with their deploy repositories.

Keycloak admin console: `https://KEYCLOAK_HOST/auth/admin`, user `KEYCLOAK_ADMIN`, password in
`secrets/KEYCLOAK_ADMIN_PASSWORD`.

### Passkeys

Users add a passkey under *Signing in* in the account console (`https://KEYCLOAK_HOST/auth/realms/fgv/account`) and
can then sign in with it instead of a password. Passkeys are bound to `KEYCLOAK_HOST`, so changing that hostname
makes every registered passkey unusable.

### Registration CAPTCHA

New users solve a Cloudflare Turnstile challenge on the registration page. Without `TURNSTILE_SITE_KEY` or
`secrets/TURNSTILE_SECRET_KEY`, Keycloak logs a warning at start and registration has no CAPTCHA. Cloudflare's
test keys `1x00000000000000000000AA` (site key) and `1x0000000000000000000000000000000AA` (secret key) always pass
and work on any hostname.

## Updating

```shell
git pull
docker compose pull
docker compose up -d
```

Containers whose image changed are recreated. A new `fgv.json` in the Keycloak image doesn't change an existing
realm, because Keycloak imports it only when the realm doesn't exist yet. Until the applications go live, apply a
realm change by resetting the realm (see *Resetting staging data*), so that it is imported again.

When an update adds a secret or a variable, compare `.env` with the example file, then run `bin/init-secrets.sh`
and `bin/configure-keycloak.sh` again. Neither overwrites an existing secret.

## Mail

Keycloak sends email verification, password reset and the approval notifications. Staging sends all mail, also the
applications', to Mailpit. For a real relay, set these in `.env` and run `bin/configure-keycloak.sh`:

| Variable        | Purpose                                                                  |
|-----------------|--------------------------------------------------------------------------|
| `SMTP_HOST`     | SMTP server                                                              |
| `SMTP_PORT`     | Usually `587` with STARTTLS, `465` with implicit TLS, `25` without       |
| `SMTP_AUTH`     | `true` to log in with `SMTP_USER` and the password in `secrets/SMTP_PASSWORD` |
| `SMTP_USER`     | SMTP user                                                                |
| `SMTP_STARTTLS` | `true` to upgrade the connection with STARTTLS                           |
| `SMTP_SSL`      | `true` to connect with implicit TLS                                      |
| `MAIL_FROM`     | Sender address                                                           |

`bin/init-secrets.sh` creates `secrets/SMTP_PASSWORD` empty. Write the password into it without a trailing
newline, e.g. `printf '%s' '<password>' > secrets/SMTP_PASSWORD`. Check the result with *Test connection* under
*Realm settings → Email* in the admin console.

## Data and backups

| Location                     | Contents                         | Backup                 |
|------------------------------|----------------------------------|------------------------|
| volume `keycloak_mysql_data` | Keycloak database (realm, users) | `bin/backup-db.sh`     |
| volume `mailpit_data`        | Caught mail (staging only)       | not needed             |
| `secrets/`                   | Passwords and client secrets     | copy off the host once |

`bin/backup-db.sh` uses `mysqldump --single-transaction`, which is consistent without stopping anything. Run it
nightly from the host user's crontab (`crontab -e`):

```
20 2 * * * /home/<user>/fgv-infra-deploy/bin/backup-db.sh >> /home/<user>/fgv-infra-deploy/backups/backup.log 2>&1
```

`BACKUP_KEEP_DAYS` sets how many days of dumps to keep (default 14). Copy `backups/` off the host as well, e.g.
with `rclone` or `rsync`; a backup on the same disk doesn't survive losing the disk.

To restore a dump:

```shell
gunzip -c backups/<timestamp>/keycloak-mysql.sql.gz | docker compose exec -T keycloak-mysql \
  sh -c 'MYSQL_PWD=$(cat /run/secrets/KEYCLOAK_MYSQL_ROOT_PASSWORD) mysql -uroot "$MYSQL_DATABASE"'
```

Every service logs to the console only; read it with `docker compose logs -f <service>`. Each service keeps at
most 5 × 10 MB of console output (`x-logging` in the compose files), so logs can't fill the disk.

## Resetting staging data

```shell
docker compose down -v                    # removes the volumes: Keycloak realm and users, mail
```

Stop the applications first, since their containers are attached to the shared network. Then repeat *First start*.
With `API_IMPORT_SAMPLE_DATA=true`, Spexregister creates its sample users again on its next start. The secrets in
`secrets/` and the dumps in `backups/` are kept.

## Production

A production host differs in these ways:

- `.env` copied from `production.env.example`, with a real SMTP relay instead of Mailpit (see *Mail*; the values in
  the example are placeholders)
- no sample users: the realm in the Keycloak image contains none
- `bin/backup-db.sh` scheduled in cron, with `backups/` copied to off-host storage
- `KEYCLOAK_IMAGE` pinned to a release, e.g. `bloomper/fgv-keycloak:1.1.0`, instead of `develop`, and
  `CLOUDFLARED_VERSION` pinned instead of `latest`, so that an update happens only when `.env` changes

Add `compose.tunnel.yaml` to `COMPOSE_FILE` if production also goes through a Cloudflare Tunnel, using its own
tunnel and token. Leave it out if production sits behind its own reverse proxy instead.

## Local development

`local/` runs the same infrastructure on a developer's machine, so that each application's repository only runs its
own database and API locally:

| Service           | Local address                                                              |
|-------------------|----------------------------------------------------------------------------|
| `keycloak-server` | `https://auth.fgv.local.nu:8443/auth`, `keycloak-server:8080` on `fgv-local` |
| `mailpit`         | `https://mail.fgv.local.nu:8443` or `http://localhost:8025`, SMTP on `mailpit:1025` and `localhost:1025` |
| `caddy`           | Port 8443 with a local certificate, also for `api.register.fgv.local.nu`   |

The project is `fgv-infra-local` and the shared network is `fgv-local`, which `spexregister-server`'s
`docker-compose.yaml` joins. FGV Revival's server and web run on the host with `./gradlew bootRun` and `npm run dev`
and reach Keycloak through Caddy, so they need no network. Running only one application is fine: start this stack
and that application. FGV Revival shows spexes as unavailable until Spexregister runs as well.

Add to `/etc/hosts` (or the Windows equivalent):

```
127.0.0.1 auth.fgv.local.nu mail.fgv.local.nu api.register.fgv.local.nu register.fgv.local.nu
```

The secrets are files in `local/.docker/secrets/`, in git with the placeholder `CHANGE_ME`. Replace each one without
a trailing newline and tell git to leave your values alone:

```shell
cd local
printf '%s' 'verysecret' > .docker/secrets/KEYCLOAK_MYSQL_ROOT_PASSWORD
printf '%s' 'secret' > .docker/secrets/KEYCLOAK_MYSQL_USER_PASSWORD
printf '%s' 'password' > .docker/secrets/KEYCLOAK_ADMIN_PASSWORD   # user KEYCLOAK_ADMIN in local/.env
git update-index --skip-worktree .docker/secrets/*
docker compose up -d && docker compose ps
```

- Keycloak imports the realm from `fgv.json` with the client secrets in it, which the applications' local
  configuration already uses, so `bin/configure-keycloak.sh` isn't needed locally. To get a changed `fgv.json`, run
  `docker compose down`, empty `local/.docker/keycloak-mysql/data` and start again.
- `local/.env` sets the applications' local addresses, which the realm's redirect URIs and MCP audiences are made
  from: Spexregister's web on `http://localhost:3000`, FGV Revival's on `http://localhost:3001` and its MCP endpoint
  on `http://localhost:8081/api/mcp`.
- Registration uses Cloudflare's Turnstile test keys, which always pass. To see a failed challenge, add
  `TURNSTILE_SECRET_KEY=2x0000000000000000000000000000000AA` to `local/.env` and run
  `docker compose up -d keycloak-server`.
- Caddy's root certificate is `local/.docker/caddy/data/caddy/pki/authorities/local/root.crt`. Import it into the
  operating system's trust store, and give it to tools that don't use that store, such as Node's
  `NODE_EXTRA_CA_CERTS`.
- Caddy forwards `api.register.fgv.local.nu` to the `spexregister-api` container, or, when that isn't running, to
  port 8080 on the host.

## Image tags

CI in `fgv-keycloak` publishes the image with these tags:

| Trigger              | Tags                                   |
|----------------------|----------------------------------------|
| push to `develop`    | `develop`, `sha-<commit>`              |
| push of tag `vX.Y.Z` | `X.Y.Z`, `latest`, `sha-<commit>`      |

`fgv-keycloak` has no version file: its tag is the version. The build fails if `X.Y.Z` is already on Docker Hub, so
release tags are never overwritten.

[1]: https://github.com/bloomper/spexregister-deploy
[2]: https://github.com/bloomper/fgv-revival-deploy
[3]: https://github.com/bloomper/fgv-keycloak
