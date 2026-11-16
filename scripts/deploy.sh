#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLKIT_DIR="$(dirname "$SCRIPT_DIR")"

APP_ROOT="${APP_ROOT:-/srv/app}"
DEPLOY_REPO="${DEPLOY_REPO:-}"
DEPLOY_REF="${DEPLOY_REF:-main}"
KEEP_RELEASES="${KEEP_RELEASES:-5}"
PYTHON_BIN="${PYTHON_BIN:-python3.12}"
ECOSYSTEM_FILE="${ECOSYSTEM_FILE:-$TOOLKIT_DIR/pm2/ecosystem.config.js}"
HEALTH_ATTEMPTS="${HEALTH_ATTEMPTS:-10}"
HEALTH_DELAY_SECONDS="${HEALTH_DELAY_SECONDS:-3}"

DEFAULT_HEALTH_URLS=("http://127.0.0.1:8000/api/health" "http://127.0.0.1:3000/")

mode="deploy"
run_migrations=true
health_urls=()

releases_dir=""
shared_dir=""
env_file=""
mirror_dir=""
current_link=""

resolved_sha=""
new_release_id=""
deploy_stage="init"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Builds a new release from a git ref, runs migrations, points 'current' at it,
reloads PM2 and checks health. If the health check fails it switches back to
the previous release. Run as the deploy user, not root.

Options (environment variable in brackets):
  --repo URL          Git URL of the app; required on the first deploy     [DEPLOY_REPO]
  --ref REF           Branch, tag or commit to deploy (default: main)      [DEPLOY_REF]
  --app-root PATH     Application root (default: /srv/app)                [APP_ROOT]
  --keep N            Number of releases to keep on disk (default: 5)      [KEEP_RELEASES]
  --health-url URL    URL that must answer 2xx after the switch; repeatable
                      (default: ${DEFAULT_HEALTH_URLS[*]})
  --skip-migrations   Do not run 'alembic upgrade head'
  --rollback          Switch back to the release before the current one and exit
  -h, --help          Show this help

Examples:
  $(basename "$0") --repo git@github.com:example/app.git --ref main
  $(basename "$0") --ref v1.4.2
  $(basename "$0") --rollback
EOF
}

log() {
  printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

warn() {
  printf '[%s] WARNING: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2
}

die() {
  printf '[%s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2
  exit 1
}

require_value() {
  [[ $# -ge 2 && -n "$2" ]] || die "$1 needs a value"
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --repo) require_value "$@"; DEPLOY_REPO="$2"; shift 2 ;;
      --ref) require_value "$@"; DEPLOY_REF="$2"; shift 2 ;;
      --app-root) require_value "$@"; APP_ROOT="$2"; shift 2 ;;
      --keep) require_value "$@"; KEEP_RELEASES="$2"; shift 2 ;;
      --health-url) require_value "$@"; health_urls+=("$2"); shift 2 ;;
      --skip-migrations) run_migrations=false; shift ;;
      --rollback) mode="rollback"; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage >&2; die "unknown option: $1" ;;
    esac
  done
}

require_commands() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
  done
}

load_env_file() {
  local line key value
  local assignment='^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$'
  local double_quoted='^"(.*)"$'
  local single_quoted="^'(.*)'\$"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ $assignment ]]; then
      key="${BASH_REMATCH[2]}"
      value="${BASH_REMATCH[3]}"
      if [[ "$value" =~ $double_quoted || "$value" =~ $single_quoted ]]; then
        value="${BASH_REMATCH[1]}"
      fi
      export "$key=$value"
    fi
  done <"$1"
}

current_release_id() {
  if [[ -L "$current_link" ]]; then
    basename "$(readlink -f "$current_link")"
  fi
}

record_history() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$DEPLOY_REF" "$2" "$3" \
    >>"$shared_dir/deploys.log"
}

acquire_lock() {
  exec 9>"$APP_ROOT/.deploy.lock"
  flock -n 9 || die "another deploy is already running"
}

on_exit() {
  local status=$?
  if ((status != 0)) && [[ "$deploy_stage" == "building" && -n "$new_release_id" ]]; then
    warn "build failed; removing incomplete release $new_release_id (live release untouched)"
    rm -rf -- "${releases_dir:?}/$new_release_id"
  fi
}

fetch_ref() {
  if [[ ! -d "$mirror_dir" ]]; then
    [[ -n "$DEPLOY_REPO" ]] || die "no local copy of the repository yet; pass --repo on the first deploy"
    log "Cloning $DEPLOY_REPO"
    git clone --quiet --bare "$DEPLOY_REPO" "$mirror_dir"
    git --git-dir="$mirror_dir" config remote.origin.fetch '+refs/heads/*:refs/heads/*'
  elif [[ -n "$DEPLOY_REPO" ]]; then
    git --git-dir="$mirror_dir" remote set-url origin "$DEPLOY_REPO"
  fi
  log "Fetching branches and tags"
  git --git-dir="$mirror_dir" fetch --quiet --prune --tags origin
  resolved_sha="$(git --git-dir="$mirror_dir" rev-parse --verify --quiet "${DEPLOY_REF}^{commit}")" ||
    die "ref not found: $DEPLOY_REF"
}

create_release() {
  local release_dir="$releases_dir/$new_release_id"
  log "Creating release $new_release_id from $DEPLOY_REF ($resolved_sha)"
  mkdir -p "$release_dir"
  git --git-dir="$mirror_dir" archive --format=tar "$resolved_sha" | tar -x -C "$release_dir"
  printf '%s\n' "$resolved_sha" >"$release_dir/REVISION"

  [[ -f "$release_dir/web/package-lock.json" ]] || die "web/package-lock.json not found in $DEPLOY_REF"
  [[ -f "$release_dir/api/requirements.txt" ]] || die "api/requirements.txt not found in $DEPLOY_REF"
  if [[ "$run_migrations" == true ]]; then
    [[ -f "$release_dir/api/alembic.ini" ]] || die "api/alembic.ini not found; use --skip-migrations if the app has none"
  fi
}

build_api() {
  local api_dir="$1/api"
  log "API: creating virtualenv and installing requirements"
  "$PYTHON_BIN" -m venv "$api_dir/.venv"
  "$api_dir/.venv/bin/pip" install --quiet --disable-pip-version-check --requirement "$api_dir/requirements.txt"
}

build_web() {
  local web_dir="$1/web"
  log "Web: installing dependencies (npm ci)"
  (
    cd "$web_dir"
    npm ci --include=dev --no-audit --no-fund --loglevel=error
  )
  log "Web: building"
  (
    load_env_file "$env_file"
    cd "$web_dir"
    NODE_ENV=production npm run build
  )
}

migrate_database() {
  local api_dir="$1/api"
  log "Database: alembic upgrade head"
  (
    load_env_file "$env_file"
    cd "$api_dir"
    .venv/bin/alembic upgrade head
  )
}

switch_current() {
  ln -sfn "releases/$1" "$APP_ROOT/current.next"
  mv -Tf "$APP_ROOT/current.next" "$current_link"
  log "current -> releases/$1"
}

reload_processes() {
  log "Reloading PM2 processes"
  env -i HOME="$HOME" PATH="$PATH" APP_ROOT="$APP_ROOT" \
    pm2 startOrReload "$ECOSYSTEM_FILE" --update-env
}

wait_for_health() {
  local url attempt
  for url in "${health_urls[@]}"; do
    attempt=1
    until curl --silent --fail --max-time 5 --output /dev/null "$url"; do
      if ((attempt >= HEALTH_ATTEMPTS)); then
        warn "health check failed after $attempt attempts: $url"
        return 1
      fi
      attempt=$((attempt + 1))
      sleep "$HEALTH_DELAY_SECONDS"
    done
    log "Healthy: $url"
  done
}

prune_releases() {
  local keep_id release_id count=0
  local releases=()
  keep_id="$(current_release_id)"
  mapfile -t releases < <(find "$releases_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r)
  for release_id in "${releases[@]}"; do
    count=$((count + 1))
    if ((count > KEEP_RELEASES)) && [[ "$release_id" != "$keep_id" ]]; then
      log "Removing old release $release_id"
      rm -rf -- "${releases_dir:?}/$release_id"
    fi
  done
}

deploy() {
  local previous_release_id
  previous_release_id="$(current_release_id)"

  log "Checking $env_file"
  "$SCRIPT_DIR/check-env.sh" --env-file "$env_file" --example "$TOOLKIT_DIR/env/.env.example"

  fetch_ref
  new_release_id="$(date -u +%Y%m%dT%H%M%SZ)-${resolved_sha:0:7}"
  local release_dir="$releases_dir/$new_release_id"

  deploy_stage="building"
  create_release
  build_api "$release_dir"
  build_web "$release_dir"
  if [[ "$run_migrations" == true ]]; then
    migrate_database "$release_dir"
  fi

  deploy_stage="switching"
  switch_current "$new_release_id"
  if reload_processes && wait_for_health; then
    deploy_stage="done"
    pm2 save --force >/dev/null
    record_history "$new_release_id" "$resolved_sha" success
    prune_releases
    log "Deployed $new_release_id"
    return
  fi

  record_history "$new_release_id" "$resolved_sha" failed
  if [[ -z "$previous_release_id" ]]; then
    die "first deploy failed its health check and there is nothing to roll back to; see $shared_dir/logs"
  fi

  warn "rolling back to $previous_release_id"
  switch_current "$previous_release_id"
  if reload_processes && wait_for_health; then
    rm -rf -- "${releases_dir:?}/$new_release_id"
    record_history "$previous_release_id" "$(cat "$releases_dir/$previous_release_id/REVISION")" rolled-back
    die "deploy of $DEPLOY_REF failed; rolled back to $previous_release_id. Logs: $shared_dir/logs"
  fi
  die "rollback to $previous_release_id also failed its health check; manual attention needed"
}

rollback() {
  local current_id target_id="" release_id
  local releases=()
  current_id="$(current_release_id)"
  [[ -n "$current_id" ]] || die "no current release to roll back from"

  mapfile -t releases < <(find "$releases_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
  for release_id in "${releases[@]}"; do
    if [[ "$release_id" < "$current_id" ]]; then
      target_id="$release_id"
    fi
  done
  [[ -n "$target_id" ]] || die "no release older than $current_id on disk"

  log "Rolling back from $current_id to $target_id"
  switch_current "$target_id"
  if reload_processes && wait_for_health; then
    pm2 save --force >/dev/null
    record_history "$target_id" "$(cat "$releases_dir/$target_id/REVISION")" manual-rollback
    log "Now running $target_id. Database migrations were not reverted."
    return
  fi
  die "release $target_id failed its health check after rollback; manual attention needed"
}

main() {
  parse_args "$@"
  [[ "$EUID" -ne 0 ]] || die "run as the deploy user, not root; PM2 runs under that user"
  [[ "$KEEP_RELEASES" =~ ^[1-9][0-9]*$ ]] || die "--keep must be a positive number"

  releases_dir="$APP_ROOT/releases"
  shared_dir="$APP_ROOT/shared"
  env_file="$shared_dir/.env"
  mirror_dir="$APP_ROOT/repo.git"
  current_link="$APP_ROOT/current"

  [[ -d "$releases_dir" && -d "$shared_dir" ]] || die "$APP_ROOT is not set up; run bootstrap-server.sh first"
  [[ ! -e "$current_link" || -L "$current_link" ]] || die "$current_link exists but is not a symlink"
  if ((${#health_urls[@]} == 0)); then
    health_urls=("${DEFAULT_HEALTH_URLS[@]}")
  fi

  require_commands git tar curl flock pm2
  acquire_lock
  trap on_exit EXIT

  if [[ "$mode" == "rollback" ]]; then
    rollback
  else
    require_commands npm "$PYTHON_BIN"
    deploy
  fi
}

main "$@"
