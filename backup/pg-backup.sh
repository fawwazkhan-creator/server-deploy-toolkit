#!/usr/bin/env bash
set -euo pipefail

DATABASE="${PGDATABASE:-}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/postgres}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
RCLONE_REMOTE="${BACKUP_RCLONE_REMOTE:-}"

partial_file=""

usage() {
  cat <<EOF
Usage: $(basename "$0") --database NAME [options]

Dumps one PostgreSQL database (custom format, gzipped), verifies the archive,
optionally copies it off-site with rclone, then deletes local backups older
than the retention window. Exits non-zero if any step fails.

Connection settings come from the usual libpq variables (PGHOST, PGUSER, ...)
or ~/.pgpass. Run it as the postgres user to use peer authentication.

Options (environment variable in brackets):
  -d, --database NAME     Database to back up                          [PGDATABASE]
  --backup-dir DIR        Local backup directory
                          (default: /var/backups/postgres)              [BACKUP_DIR]
  --retention-days N      Days to keep, locally and off-site (default: 14)
                                                                        [BACKUP_RETENTION_DAYS]
  --rclone-remote REMOTE  rclone destination such as offsite:app-db; off-site
                          copy is skipped when empty                    [BACKUP_RCLONE_REMOTE]
  -h, --help              Show this help
EOF
}

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
  exit 1
}

require_value() {
  [[ $# -ge 2 && -n "$2" ]] || die "$1 needs a value"
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      -d | --database) require_value "$@"; DATABASE="$2"; shift 2 ;;
      --backup-dir) require_value "$@"; BACKUP_DIR="$2"; shift 2 ;;
      --retention-days) require_value "$@"; RETENTION_DAYS="$2"; shift 2 ;;
      --rclone-remote) require_value "$@"; RCLONE_REMOTE="$2"; shift 2 ;;
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

remove_partial_file() {
  if [[ -n "$partial_file" && -f "$partial_file" ]]; then
    rm -f -- "$partial_file"
  fi
}

create_backup() {
  local final_file="$1"
  partial_file="$final_file.partial"

  log "Dumping database $DATABASE"
  pg_dump --format=custom --compress=0 --no-password --dbname="$DATABASE" | gzip -6 >"$partial_file" ||
    die "pg_dump failed for $DATABASE"

  log "Verifying archive"
  gzip -t -- "$partial_file" || die "gzip integrity check failed"
  gunzip -c -- "$partial_file" | pg_restore --list >/dev/null || die "pg_restore cannot read the archive"

  mv -- "$partial_file" "$final_file"
  partial_file=""
  log "Wrote $final_file ($(du -h -- "$final_file" | cut -f1))"
}

copy_offsite() {
  local final_file="$1"
  log "Copying to $RCLONE_REMOTE"
  rclone copy --no-traverse -- "$final_file" "$RCLONE_REMOTE" ||
    die "off-site copy failed; the local backup is kept at $final_file"
  rclone delete --min-age "${RETENTION_DAYS}d" --include "${DATABASE}_*.dump.gz" -- "$RCLONE_REMOTE" ||
    die "off-site retention cleanup failed"
}

prune_local() {
  local max_age_minutes=$((RETENTION_DAYS * 24 * 60))
  find "$BACKUP_DIR" -maxdepth 1 -type f -name "${DATABASE}_*.dump.gz" -mmin +"$max_age_minutes" -print -delete |
    sed 's/^/  removed /'
  find "$BACKUP_DIR" -maxdepth 1 -type f -name "${DATABASE}_*.dump.gz.partial" -mmin +1440 -delete
}

main() {
  parse_args "$@"
  [[ -n "$DATABASE" ]] || { usage >&2; die "--database is required"; }
  [[ "$DATABASE" =~ ^[A-Za-z0-9_-]+$ ]] || die "database name may only contain letters, digits, _ and -"
  [[ "$RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]] || die "--retention-days must be a positive number"

  require_commands pg_dump pg_restore gzip gunzip find
  if [[ -n "$RCLONE_REMOTE" ]]; then
    require_commands rclone
  fi

  umask 077
  mkdir -p -- "$BACKUP_DIR"
  trap remove_partial_file EXIT

  local final_file
  final_file="$BACKUP_DIR/${DATABASE}_$(date -u +%Y%m%dT%H%M%SZ).dump.gz"

  create_backup "$final_file"
  if [[ -n "$RCLONE_REMOTE" ]]; then
    copy_offsite "$final_file"
  fi
  log "Removing local backups older than $RETENTION_DAYS days"
  prune_local
  log "Backup finished"
}

main "$@"
