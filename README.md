# server-deploy-toolkit

Scripts and config for running a Next.js + FastAPI app on a single Ubuntu 24.04
server: first-time server setup, release-based deploys with automatic rollback,
Nginx with TLS, PostgreSQL backups, and an uptime check that alerts on change.

It targets the setup a small product team usually starts with: one VPS, no
containers, a deploy that one person can read end to end and fix at 2am.

## Server layout

```
                         Internet
                            |
                 ufw: allow 22, 80, 443 only
                            |
   +------------------------+-----------------------------------+
   |  Ubuntu 24.04                                              |
   |                                                            |
   |   Nginx :80  -> 301 to https                               |
   |   Nginx :443 (Let's Encrypt cert)                          |
   |      |                                                     |
   |      +-- /api/*  rate limited --> api  127.0.0.1:8000      |
   |      |                            uvicorn, N workers       |
   |      |                                  |                  |
   |      +-- /*  ------------------> web  127.0.0.1:3000      |
   |                                   next start, PM2 cluster  |
   |                                         |                  |
   |      PM2 (systemd unit pm2-deploy, runs as 'deploy')       |
   |                                         |                  |
   |      PostgreSQL 127.0.0.1:5432  <-------+                  |
   |      Redis      127.0.0.1:6379  <-------+                  |
   |                                                            |
   |   fail2ban (sshd), unattended-upgrades, cron backups       |
   +------------------------------------------------------------+
```

On disk:

```
/srv/app/
|-- repo.git/                    bare clone, fetched on every deploy
|-- releases/
|   |-- 20261114T091500Z-3f2a9c1/
|   |   |-- api/                 FastAPI code + .venv
|   |   |-- web/                 Next.js code + node_modules + .next
|   |   `-- REVISION             git commit of this release
|   `-- 20261116T101200Z-8b41d07/
|-- current -> releases/20261116T101200Z-8b41d07
`-- shared/
    |-- .env                     chmod 600, the only place secrets live
    |-- deploys.log              one line per deploy or rollback
    `-- logs/                    PM2 logs, rotated by pm2-logrotate
```

## Repository contents

```
scripts/bootstrap-server.sh   first-time server setup (run as root)
scripts/deploy.sh             build a release, switch, health check, roll back
scripts/check-env.sh          check .env against the template without printing values
pm2/ecosystem.config.js       PM2 definitions for api and web
nginx/app.conf.template       Nginx site, rendered with envsubst
env/.env.example              list of required variables
backup/pg-backup.sh           nightly pg_dump with retention and optional rclone copy
backup/pg-backup.cron         cron entry for the backup
backup/RESTORE.md             restore drill and production restore steps
monitor/healthcheck.sh        uptime check with change-only webhook alerts
.github/workflows/lint.yml    ShellCheck, executable bits, JS syntax
```

## What the app repository must look like

```
api/requirements.txt    FastAPI app importable as app.main:app
api/alembic.ini         migrations (or deploy with --skip-migrations)
web/package-lock.json   Next.js app with an npm "build" script
```

The API serves its routes under `/api` (Nginx passes the path through
unchanged) and exposes `GET /api/health`, which should return 200 only when it
can reach PostgreSQL and Redis.

## Quick start

On a fresh Ubuntu 24.04 server, logged in as root with your SSH key:

```bash
git clone https://github.com/<you>/server-deploy-toolkit.git /opt/server-deploy-toolkit
cd /opt/server-deploy-toolkit
./scripts/bootstrap-server.sh --deploy-user deploy
```

Keep that session open, then from your laptop confirm `ssh deploy@<server>` and
`sudo -v` work. The script prints the remaining steps; in short:

```bash
sudo -u postgres psql -c '\password app'
sudo -u deploy nano /srv/app/shared/.env
/opt/server-deploy-toolkit/scripts/check-env.sh
```

### TLS and Nginx

Point the domain's A/AAAA records at the server first.

```bash
sudo certbot certonly --nginx -d app.example.com -m ops@example.com --agree-tos --no-eff-email \
  --deploy-hook "systemctl reload nginx"

sudo rm -f /etc/nginx/sites-enabled/default
sudo env APP_DOMAIN=app.example.com envsubst '${APP_DOMAIN}' \
  < /opt/server-deploy-toolkit/nginx/app.conf.template \
  | sudo tee /etc/nginx/sites-available/app.conf > /dev/null
sudo ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/app.conf
sudo nginx -t && sudo systemctl reload nginx
```

The certificate is requested while the stock default site is still enabled, so
certbot's nginx plugin can answer the challenge. `certonly` means certbot never
edits the config. Renewals run from the `certbot.timer` unit, and the deploy
hook (saved with the certificate) reloads Nginx so it serves the new one.
The single-quoted `'${APP_DOMAIN}'` tells envsubst to replace only that
variable and leave Nginx's own `$host`, `$request_uri` and so on alone.

### First deploy

As the deploy user, after adding the key printed by the bootstrap as a
read-only deploy key on the app repository:

```bash
ssh -T git@github.com
/opt/server-deploy-toolkit/scripts/deploy.sh --repo git@github.com:example/app.git --ref main
```

The first `ssh` is there to check and accept GitHub's host key by hand.

### Backups and monitoring

```bash
sudo cp /opt/server-deploy-toolkit/backup/pg-backup.cron /etc/cron.d/pg-backup
sudo -u postgres /opt/server-deploy-toolkit/backup/pg-backup.sh --database app
```

For the health check, put the webhook URL in a file only the deploy user can
read, and add a cron entry:

```bash
sudo -u deploy install -D -m 600 /dev/null /home/deploy/.config/healthcheck/webhook-url
sudo -u deploy nano /home/deploy/.config/healthcheck/webhook-url
echo '* * * * * deploy /opt/server-deploy-toolkit/monitor/healthcheck.sh --url https://app.example.com/api/health --webhook-file /home/deploy/.config/healthcheck/webhook-url 2>&1 | logger -t healthcheck' \
  | sudo tee /etc/cron.d/app-healthcheck > /dev/null
```

Logs from both jobs end up in the journal: `journalctl -t pg-backup -t healthcheck`.

## Scripts

Every script has `--help`, takes options as flags or environment variables,
uses `set -euo pipefail`, and is self-contained (a few small helpers such as
`die` are repeated) so any one of them can be copied to another server alone.

### bootstrap-server.sh

Run once as root on a new server; running it again is safe. It refuses to run
unless it is root on Ubuntu, then:

1. Updates packages and installs base tools.
2. Adds a swap file if there is none (`--swap-size`, default 2G). `next build`
   on a 1-2 GB VPS gets killed by the OOM killer without it.
3. Creates the deploy user in the `sudo` group and authorizes SSH keys from
   `--ssh-key-file`, or copies them from root. Only plain key lines are copied;
   cloud images often prefix root's keys with `command="echo Please login as..."`.
   If the user has no password it asks for one (for sudo), and it generates an
   SSH key the server uses to pull the app repository.
4. Hardens sshd with a drop-in at `/etc/ssh/sshd_config.d/00-hardening.conf`:
   no root login, no passwords, `MaxAuthTries 3`. The `00-` prefix matters
   because sshd keeps the first value it reads and cloud-init writes
   `50-cloud-init.conf`. Before touching anything it checks the deploy user has
   at least one key and a sudo password. It runs `sshd -t` and reverts the file
   if validation fails, and only then reloads.
5. ufw: deny incoming except 22, 80, 443.
6. fail2ban `sshd` jail on the systemd backend.
7. unattended-upgrades for security updates, with automatic reboots left off.
8. Node.js LTS from the NodeSource apt repository, with its signing key in
   `/etc/apt/keyrings` (no `curl | bash`). Then PM2, its systemd unit for the
   deploy user, and pm2-logrotate.
9. Python 3.12 with venv and headers for building psycopg.
10. Nginx and certbot with the nginx plugin.
11. PostgreSQL with `listen_addresses = 'localhost'`, plus an `app` role and
    database. No password is set by the script; you set it interactively so it
    never appears in shell history or process lists.
12. Redis bound to `127.0.0.1 -::1` with protected mode on.
13. `/srv/app/{releases,shared,shared/logs}` owned by the deploy user, and
    `shared/.env` copied from the template with mode 600.

### deploy.sh

Run as the deploy user. It never needs sudo.

1. Takes a lock so two deploys cannot overlap.
2. Runs `check-env.sh` against `shared/.env`.
3. Fetches into `repo.git` and resolves `--ref` (branch, tag or commit) to a SHA.
4. Exports that commit with `git archive` into `releases/<UTC time>-<sha>/`, so
   releases contain no `.git` and cannot drift.
5. Creates the API virtualenv and installs requirements; runs `npm ci` and
   `npm run build` with `.env` loaded.
6. Runs `alembic upgrade head`.
7. Points `current` at the new release with an atomic rename
   (`ln -sfn` to a temp link, then `mv -T`).
8. `pm2 startOrReload` with a clean environment (`env -i`), so only the values
   from `.env` reach the apps.
9. Polls `http://127.0.0.1:8000/api/health` and `http://127.0.0.1:3000/`
   (override with `--health-url`).
10. On success: `pm2 save`, a line in `shared/deploys.log`, and old releases
    pruned (`--keep`, default 5). On failure: `current` goes back to the
    previous release, PM2 reloads, health is checked again, and the failed
    release is deleted. If the build fails before the switch, the half-built
    release is removed and the live site is never touched.

`deploy.sh --rollback` switches to the release before the current one by hand.

Things to know:

- **Migrations are not rolled back.** They run before the switch, while the old
  code is still serving, and a rollback only changes code. Migrations therefore
  need to be backward compatible (add a column now, drop the old one in a later
  release). This is the standard expand/contract approach.
- **Zero downtime applies to the web app only.** `web` runs in PM2 cluster mode,
  so `pm2 reload` replaces instances one at a time. `api` is one uvicorn process
  that manages its own workers, so a reload is a restart with a gap of a second
  or two where Nginx returns 502 for API calls. Removing that gap means running
  two API processes on 8000 and 8001 behind the Nginx upstream; it is not done
  here to keep the setup simple.
- Dev dependencies stay installed because `next build` needs them and some
  `next.config` setups need them at runtime too.

### check-env.sh

Reads the variable names from `env/.env.example` and checks each one in
`shared/.env` is present, not empty, and not a placeholder (`change-me`,
`example.com`, `<...>` and similar). It prints names and a status only, never a
value, and warns if the file is readable by group or others. Extra variables are
listed but not treated as errors. Exit code 1 if anything needs attention.

```
Checking /srv/app/shared/.env
  ok           APP_ENV
  placeholder  APP_DOMAIN
  ok           DATABASE_URL
  missing      SECRET_KEY
  ...
2 of 9 required variables need attention.
```

The template's variables:

| Variable | Used by |
| --- | --- |
| `APP_ENV` | both apps |
| `APP_DOMAIN` | reference for the Nginx domain |
| `NEXT_PUBLIC_API_BASE_URL` | baked into the web build |
| `CORS_ALLOWED_ORIGINS` | API |
| `DATABASE_URL` | API and Alembic |
| `REDIS_URL` | API |
| `SECRET_KEY` | API (generate with `openssl rand -hex 32`) |
| `API_WORKERS` | uvicorn worker count in the PM2 config |
| `WEB_INSTANCES` | Next.js instance count in the PM2 config |

### pm2/ecosystem.config.js

- `api`: `current/api/.venv/bin/uvicorn app.main:app`, bound to 127.0.0.1,
  `--workers` from `API_WORKERS`, proxy headers trusted only from Nginx on
  127.0.0.1, 8 s graceful shutdown inside a 10 s PM2 kill timeout.
- `web`: `next start` in cluster mode, `WEB_INSTANCES` instances, bound to
  127.0.0.1.
- Both read `shared/.env` themselves (small parser, no dotenv dependency) and
  log to `shared/logs/`.
- Restart policy: exponential backoff starting at 200 ms; a process that
  crashes 10 times in a row within 30 s of starting is left stopped instead of
  looping. Memory limits: 512M per web instance, 1G for the API.

The paths go through the `current` symlink, so a reload picks up the new
release without editing the file.

### nginx/app.conf.template

- Port 80 redirects to HTTPS for the app domain. Requests for any other Host
  get no response on 80 (`444`) and a refused TLS handshake on 443
  (`ssl_reject_handshake`), so scanners hitting the IP see nothing.
- TLS 1.2/1.3 with the Let's Encrypt paths, session tickets off.
- `/api/` goes to uvicorn, everything else to Next.js, both through upstreams
  with keepalive.
- `/api/` is rate limited per client IP: 10 requests/s with bursts of 20,
  answering 429 above that.
- Security headers: HSTS (one year, without `includeSubDomains` so other
  subdomains are not forced onto HTTPS by accident), `nosniff`,
  `X-Frame-Options`, `Referrer-Policy`, `Permissions-Policy`. A
  Content-Security-Policy depends on the app and belongs in Next.js config.
- gzip for text types, 10 MB body limit, 5 s upstream connect timeout, 60 s
  read/send timeouts, 15 s client header/body timeouts.
- `listen 443 ssl http2` is the syntax for Nginx 1.24, which Ubuntu 24.04
  ships. From 1.25.1 it is `http2 on;`.

### backup/pg-backup.sh

```bash
sudo -u postgres ./backup/pg-backup.sh --database app --retention-days 14 --rclone-remote offsite:app-db
```

- `pg_dump --format=custom --compress=0 | gzip`, so the data is compressed
  once rather than twice, into `<db>_<UTC time>.dump.gz`.
- Written to a `.partial` file, checked with `gzip -t` and
  `pg_restore --list`, then renamed. A failed run never leaves a file that
  looks like a good backup.
- Local files older than `--retention-days` are deleted only after a
  successful backup.
- With `--rclone-remote`, the file is copied off-site and remote copies older
  than the same window are removed. rclone's config lives in the postgres
  user's home (`sudo -u postgres rclone config`).
- Any failure exits non-zero with a message saying which step failed.

Restore steps, including a monthly restore drill: [backup/RESTORE.md](backup/RESTORE.md).

### monitor/healthcheck.sh

```bash
ALERT_WEBHOOK_URL=... ./monitor/healthcheck.sh --url https://app.example.com/api/health --retries 3 --timeout 5
```

- A check fails after `--retries` attempts with `--timeout` each, which avoids
  alerts for a single slow request.
- The last state is kept in `~/.local/state/healthcheck/<name>.state`. An alert
  is sent only on a change: one `DOWN` message with the reason (HTTP status,
  timeout, connection refused, TLS error) and one `RECOVERED` message with the
  downtime.
- The payload carries both `text` (Slack) and `content` (Discord).
- The webhook URL is passed to curl on stdin, so it is not visible in `ps`.
- If the alert cannot be delivered, the state is not saved and the next run
  tries again.
- `flock` stops overlapping runs when a check takes longer than the cron
  interval.

Running it on the same server catches crashed or stuck processes but not the
server itself going down. For that, run it from a second machine as well, or
use an external uptime service.

## Security notes

- SSH: keys only, no root login, fail2ban on sshd. If your SSH agent holds more
  than three keys, set `IdentitiesOnly yes` for this host, or `MaxAuthTries 3`
  will reject you before the right key is tried.
- Only 22, 80 and 443 are open. Node, uvicorn, PostgreSQL and Redis listen on
  localhost only, so they are not exposed even if the firewall is turned off.
- Secrets live in one file, `shared/.env`, mode 600, owned by the deploy user.
  It is never committed, never copied into releases, and no script prints its
  values.
- The deploy user has sudo with a password, but deploys never use it. The
  repository key on the server should be a read-only deploy key.
- Security updates install automatically; kernel updates still need a planned
  reboot (`/var/run/reboot-required` tells you when).
- The rate limit uses the client IP. Behind Cloudflare or another proxy, set up
  `real_ip_header` first, or every visitor will share the proxy's limit.

## Validation

The scripts are checked with `bash -n` and the PM2 config with `node --check`.
CI runs ShellCheck on every script, checks they are committed as executable and
checks the PM2 config parses. Try changes on a throwaway VPS before a server
that matters; `bootstrap-server.sh` changes SSH and firewall settings.

## What I would add next

- **Docker:** build the API and web images in CI and deploy by image tag, so
  the server no longer compiles anything. ufw does not filter ports Docker
  publishes, so bind containers to 127.0.0.1.
- **Terraform:** create the VPS, firewall, DNS records and backup bucket from
  code, so a second environment is one `terraform apply`.
- **Metrics:** node_exporter, postgres_exporter and the app's own metrics into
  Prometheus and Grafana, with alerts on disk space, memory and error rate
  instead of only up/down.
- **A second API process** on port 8001 behind the Nginx upstream, so API
  reloads have no gap.
- **Backup alerts:** a dead man's switch ping at the end of `pg-backup.sh`, so
  a backup that silently stops running gets noticed.
- **CI deploys:** a GitHub Actions job that runs `deploy.sh` over SSH after
  tests pass on `main`.

## License

MIT, see [LICENSE](LICENSE).
