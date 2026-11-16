#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

TOTAL_STEPS=15
current_step=0

DEPLOY_USER="${DEPLOY_USER:-deploy}"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"
APP_ROOT="${APP_ROOT:-/srv/app}"
NODE_MAJOR="${NODE_MAJOR:-24}"
DB_NAME="${DB_NAME:-app}"
DB_USER="${DB_USER:-app}"
SWAP_SIZE="${SWAP_SIZE:-2G}"

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_HOME=""

usage() {
  cat <<EOF
Usage: sudo $(basename "$0") [options]

First-time setup for an Ubuntu 24.04 server that runs a Next.js + FastAPI app
under PM2 behind Nginx, with PostgreSQL and Redis on localhost.
Safe to run again: every step checks the current state before changing it.

Options (environment variable in brackets):
  --deploy-user NAME    Login and deploy user to create (default: deploy)      [DEPLOY_USER]
  --ssh-key-file PATH   Public key file to authorize for the deploy user        [SSH_KEY_FILE]
                        Without it, keys are copied from /root/.ssh/authorized_keys
  --app-root PATH       Application root (default: /srv/app)                    [APP_ROOT]
  --node-major N        Node.js major version from NodeSource (default: 24)     [NODE_MAJOR]
  --db-name NAME        PostgreSQL database to create (default: app)            [DB_NAME]
  --db-user NAME        PostgreSQL role that owns the database (default: app)   [DB_USER]
  --swap-size SIZE      Swap file size if the server has no swap, 0 to skip
                        (default: 2G)                                           [SWAP_SIZE]
  -h, --help            Show this help

Example:
  sudo ./scripts/bootstrap-server.sh --deploy-user deploy --ssh-key-file /root/deploy.pub
EOF
}

step() {
  current_step=$((current_step + 1))
  printf '\n==> [%d/%d] %s\n' "$current_step" "$TOTAL_STEPS" "$*"
}

info() {
  printf '    %s\n' "$*"
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_value() {
  [[ $# -ge 2 && -n "$2" ]] || die "$1 needs a value"
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --deploy-user) require_value "$@"; DEPLOY_USER="$2"; shift 2 ;;
      --ssh-key-file) require_value "$@"; SSH_KEY_FILE="$2"; shift 2 ;;
      --app-root) require_value "$@"; APP_ROOT="$2"; shift 2 ;;
      --node-major) require_value "$@"; NODE_MAJOR="$2"; shift 2 ;;
      --db-name) require_value "$@"; DB_NAME="$2"; shift 2 ;;
      --db-user) require_value "$@"; DB_USER="$2"; shift 2 ;;
      --swap-size) require_value "$@"; SWAP_SIZE="$2"; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) usage >&2; die "unknown option: $1" ;;
    esac
  done
}

os_release_value() {
  sed -n -E "s/^$1=\"?([^\"]*)\"?$/\1/p" /etc/os-release | head -n 1
}

apt_install() {
  apt-get install -y -q \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    "$@"
}

as_deploy_user() {
  (cd / && sudo -u "$DEPLOY_USER" -H -- "$@")
}

as_postgres() {
  (cd / && sudo -u postgres -- "$@")
}

write_config() {
  local target="$1" mode="$2" staged
  staged="$(mktemp)"
  cat >"$staged"
  if [[ -f "$target" ]] && cmp -s "$staged" "$target"; then
    rm -f "$staged"
    return 1
  fi
  install -D -m "$mode" -o root -g root "$staged" "$target" || {
    rm -f "$staged"
    die "could not write $target"
  }
  rm -f "$staged"
  info "wrote $target"
  return 0
}

set_config_line() {
  local file="$1" key="$2" value="$3"
  if grep -qE "^${key}[[:space:]]" "$file"; then
    sed -i -E "s|^${key}[[:space:]].*|${key} ${value}|" "$file"
  else
    printf '%s %s\n' "$key" "$value" >>"$file"
  fi
}

count_authorized_keys() {
  local keys_file="$DEPLOY_HOME/.ssh/authorized_keys"
  if [[ -f "$keys_file" ]]; then
    grep -cE '^(ssh-|ecdsa-|sk-)' "$keys_file" || true
  else
    echo 0
  fi
}

preflight() {
  step "Preflight checks"
  [[ "$EUID" -eq 0 ]] || die "run as root, for example: sudo $0"
  [[ -r /etc/os-release ]] || die "cannot read /etc/os-release"

  local os_id os_version
  os_id="$(os_release_value ID)"
  os_version="$(os_release_value VERSION_ID)"
  [[ "$os_id" == "ubuntu" ]] || die "this script supports Ubuntu only (found: ${os_id:-unknown})"
  if [[ "$os_version" != "24.04" ]]; then
    warn "written for Ubuntu 24.04, found $os_version; continuing"
  fi

  [[ "$DEPLOY_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid user name: $DEPLOY_USER"
  [[ "$DB_NAME" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die "invalid database name: $DB_NAME"
  [[ "$DB_USER" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die "invalid database role: $DB_USER"
  [[ "$NODE_MAJOR" =~ ^[0-9]+$ ]] || die "invalid Node.js major version: $NODE_MAJOR"
  [[ "$SWAP_SIZE" =~ ^(0|[0-9]+[MG])$ ]] || die "invalid swap size: $SWAP_SIZE (use 0, 512M, 2G, ...)"
  [[ "$APP_ROOT" == /* ]] || die "app root must be an absolute path: $APP_ROOT"
  if [[ -n "$SSH_KEY_FILE" && ! -r "$SSH_KEY_FILE" ]]; then
    die "cannot read SSH key file: $SSH_KEY_FILE"
  fi

  info "Ubuntu $os_version, deploy user '$DEPLOY_USER', app root $APP_ROOT"
}

install_base_packages() {
  step "System update and base packages"
  apt-get update -q
  apt-get upgrade -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
  apt_install ca-certificates curl gnupg git build-essential ufw fail2ban python3-systemd unattended-upgrades
}

configure_swap() {
  step "Swap"
  if [[ "$SWAP_SIZE" == "0" ]]; then
    info "skipped (--swap-size 0)"
    return
  fi
  if [[ -n "$(swapon --show --noheadings)" ]]; then
    info "swap already active, leaving it as is"
    return
  fi
  if [[ ! -f /swapfile ]]; then
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  swapon /swapfile
  if ! grep -qE '^/swapfile[[:space:]]' /etc/fstab; then
    printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
  fi
  if write_config /etc/sysctl.d/90-swappiness.conf 644 <<<'vm.swappiness = 10'; then
    sysctl -q -p /etc/sysctl.d/90-swappiness.conf
  fi
  info "created and enabled a $SWAP_SIZE swap file"
}

create_deploy_user() {
  step "Deploy user and SSH keys"
  if id "$DEPLOY_USER" >/dev/null 2>&1; then
    info "user $DEPLOY_USER already exists"
  else
    adduser --disabled-password --gecos "" "$DEPLOY_USER" >/dev/null
    info "created user $DEPLOY_USER"
  fi
  usermod -aG sudo "$DEPLOY_USER"
  DEPLOY_HOME="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"

  local ssh_dir="$DEPLOY_HOME/.ssh"
  local keys_file="$ssh_dir/authorized_keys"
  install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$ssh_dir"
  if [[ ! -f "$keys_file" ]]; then
    install -m 600 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /dev/null "$keys_file"
  fi

  local key_source="$SSH_KEY_FILE"
  if [[ -z "$key_source" && -r /root/.ssh/authorized_keys ]]; then
    key_source=/root/.ssh/authorized_keys
  fi
  if [[ -n "$key_source" ]]; then
    local line added=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^(ssh-|ecdsa-|sk-) ]] && ! grep -qxF -- "$line" "$keys_file"; then
        printf '%s\n' "$line" >>"$keys_file"
        added=$((added + 1))
      fi
    done <"$key_source"
    info "authorized $added new key(s) from $key_source"
  fi
  chown "$DEPLOY_USER:$DEPLOY_USER" "$keys_file"
  chmod 600 "$keys_file"
  info "$DEPLOY_USER has $(count_authorized_keys) authorized key(s)"

  local password_state
  password_state="$(passwd -S "$DEPLOY_USER" | awk '{print $2}')"
  if [[ "$password_state" != "P" ]]; then
    if [[ -t 0 ]]; then
      info "set a password for $DEPLOY_USER; it is used for sudo only, SSH stays key-only"
      passwd "$DEPLOY_USER"
    else
      die "$DEPLOY_USER has no password, so sudo would not work. Run 'passwd $DEPLOY_USER' and re-run this script."
    fi
  fi

  if [[ ! -f "$ssh_dir/id_ed25519" ]]; then
    as_deploy_user ssh-keygen -q -t ed25519 -N "" -C "${DEPLOY_USER}@$(hostname -s)" -f "$ssh_dir/id_ed25519"
    info "generated $ssh_dir/id_ed25519 for pulling the app repository"
  fi
}

harden_ssh() {
  step "SSH hardening"
  local key_count
  key_count="$(count_authorized_keys)"
  if ((key_count == 0)); then
    die "$DEPLOY_USER has no authorized SSH keys. Refusing to disable root and password login, it would lock you out. Re-run with --ssh-key-file."
  fi

  local dropin=/etc/ssh/sshd_config.d/00-hardening.conf
  local previous=""
  if [[ -f "$dropin" ]]; then
    previous="$(mktemp)"
    cp -p "$dropin" "$previous"
  fi

  if write_config "$dropin" 644 <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
EOF
  then
    install -d -m 755 /run/sshd
    if ! sshd -t; then
      if [[ -n "$previous" ]]; then
        mv -f "$previous" "$dropin"
      else
        rm -f "$dropin"
      fi
      die "sshd -t rejected the new configuration; it was reverted and sshd was not reloaded"
    fi
    if systemctl is-active --quiet ssh.service; then
      systemctl reload ssh.service
    fi
    info "root login and password authentication disabled"
    info "keep this session open until you have logged in as $DEPLOY_USER from a new terminal"
  else
    info "already hardened"
  fi

  if [[ -n "$previous" && -f "$previous" ]]; then
    rm -f "$previous"
  fi
}

configure_firewall() {
  step "Firewall (ufw: 22, 80, 443)"
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow 22/tcp >/dev/null
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw --force enable >/dev/null
  ufw status verbose | sed 's/^/    /'
}

configure_fail2ban() {
  step "fail2ban for SSH"
  if write_config /etc/fail2ban/jail.d/sshd.local 644 <<'EOF'
[sshd]
enabled = true
backend = systemd
port = ssh
maxretry = 5
findtime = 10m
bantime = 1h
EOF
  then
    systemctl restart fail2ban
  fi
  systemctl enable --quiet --now fail2ban
  info "sshd jail active: 5 failures in 10 minutes bans an address for 1 hour"
}

configure_unattended_upgrades() {
  step "Unattended security upgrades"
  write_config /etc/apt/apt.conf.d/20auto-upgrades 644 <<'EOF' || true
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  systemctl enable --quiet --now unattended-upgrades
  info "security updates install daily; reboots stay manual"
}

install_node() {
  step "Node.js ${NODE_MAJOR}.x from NodeSource"
  local installed_major=""
  if command -v node >/dev/null 2>&1; then
    installed_major="$(node --version | sed -E 's/^v([0-9]+).*/\1/')"
  fi
  if [[ "$installed_major" != "$NODE_MAJOR" ]]; then
    install -d -m 755 /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key |
      gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
    printf 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_%s.x nodistro main\n' \
      "$NODE_MAJOR" >/etc/apt/sources.list.d/nodesource.list
    apt-get update -q
    apt_install nodejs
  fi
  info "node $(node --version), npm $(npm --version)"
}

install_pm2() {
  step "PM2, boot service and log rotation"
  if ! command -v pm2 >/dev/null 2>&1; then
    npm install --global --no-audit --no-fund pm2
  fi

  local unit="pm2-${DEPLOY_USER}.service"
  if ! systemctl is-enabled --quiet "$unit" 2>/dev/null; then
    pm2 startup systemd -u "$DEPLOY_USER" --hp "$DEPLOY_HOME" >/dev/null
  fi

  if [[ ! -d "$DEPLOY_HOME/.pm2/modules/pm2-logrotate" ]]; then
    as_deploy_user pm2 install pm2-logrotate >/dev/null
  fi
  as_deploy_user pm2 set pm2-logrotate:max_size 20M >/dev/null
  as_deploy_user pm2 set pm2-logrotate:retain 14 >/dev/null
  as_deploy_user pm2 set pm2-logrotate:compress true >/dev/null
  as_deploy_user pm2 set pm2-logrotate:rotateInterval '0 0 * * *' >/dev/null

  systemctl start "$unit"
  info "PM2 $(pm2 --version) runs as $DEPLOY_USER via $unit; logs rotate daily or at 20M, 14 kept"
}

install_python() {
  step "Python 3.12 and venv"
  apt_install python3 python3-venv python3-pip python3-dev libpq-dev
  local version
  version="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
  if [[ "$version" != "3.12" ]]; then
    warn "python3 is $version, deploy.sh expects python3.12 (set PYTHON_BIN to override)"
  fi
  info "python $version"
}

install_nginx_certbot() {
  step "Nginx and certbot"
  apt_install nginx certbot python3-certbot-nginx
  systemctl enable --quiet --now nginx
  info "nginx $(nginx -v 2>&1 | sed 's|.*/||'), certbot renew timer: $(systemctl is-enabled certbot.timer 2>/dev/null || echo unknown)"
}

install_postgres() {
  step "PostgreSQL (localhost only)"
  apt_install postgresql

  local version
  version="$(find /etc/postgresql -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V | tail -n 1)"
  [[ -n "$version" ]] || die "could not find a PostgreSQL cluster under /etc/postgresql"

  if write_config "/etc/postgresql/${version}/main/conf.d/90-listen.conf" 644 <<<"listen_addresses = 'localhost'"; then
    systemctl restart postgresql
  fi
  systemctl enable --quiet --now postgresql

  if [[ "$(as_postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = '${DB_USER}'")" != "1" ]]; then
    as_postgres createuser --login "$DB_USER"
    info "created role $DB_USER"
  fi
  if [[ "$(as_postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'")" != "1" ]]; then
    as_postgres createdb --owner "$DB_USER" "$DB_NAME"
    info "created database $DB_NAME owned by $DB_USER"
  fi

  install -d -m 700 -o postgres -g postgres /var/backups/postgres
  info "PostgreSQL $version listening on localhost; backups go to /var/backups/postgres"
}

install_redis() {
  step "Redis (localhost only)"
  apt_install redis-server

  local config=/etc/redis/redis.conf before after
  before="$(sha256sum "$config")"
  set_config_line "$config" bind "127.0.0.1 -::1"
  set_config_line "$config" protected-mode yes
  after="$(sha256sum "$config")"

  if [[ "$before" != "$after" ]]; then
    systemctl restart redis-server
    info "updated $config"
  fi
  systemctl enable --quiet --now redis-server
  info "Redis listening on 127.0.0.1 and ::1"
}

create_app_directories() {
  step "Application directories"
  install -d -m 750 -o "$DEPLOY_USER" -g "$DEPLOY_USER" \
    "$APP_ROOT" "$APP_ROOT/releases" "$APP_ROOT/shared" "$APP_ROOT/shared/logs"

  local env_file="$APP_ROOT/shared/.env"
  if [[ ! -f "$env_file" ]]; then
    install -m 600 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$TOOLKIT_DIR/env/.env.example" "$env_file"
    info "created $env_file from the template; fill it in before the first deploy"
  else
    info "$env_file already exists, not touched"
  fi
}

print_summary() {
  cat <<EOF

Server setup finished. Next steps:

  1. Keep this root session open. From a new terminal, confirm you can log in
     and use sudo:  ssh ${DEPLOY_USER}@<server>  then  sudo -v
  2. Add this public key to the app repository as a read-only deploy key:
       $(cat "$DEPLOY_HOME/.ssh/id_ed25519.pub")
  3. Set the database password (typed interactively, never stored in history):
       sudo -u postgres psql -c '\\password ${DB_USER}'
  4. Fill in ${APP_ROOT}/shared/.env and check it:
       ${TOOLKIT_DIR}/scripts/check-env.sh --env-file ${APP_ROOT}/shared/.env
  5. Issue the TLS certificate and install the Nginx site (README: "TLS and Nginx").
  6. First deploy, as ${DEPLOY_USER}:
       ${TOOLKIT_DIR}/scripts/deploy.sh --repo <git-url> --ref main
EOF
}

main() {
  parse_args "$@"
  preflight
  install_base_packages
  configure_swap
  create_deploy_user
  harden_ssh
  configure_firewall
  configure_fail2ban
  configure_unattended_upgrades
  install_node
  install_pm2
  install_python
  install_nginx_certbot
  install_postgres
  install_redis
  create_app_directories
  print_summary
}

main "$@"
