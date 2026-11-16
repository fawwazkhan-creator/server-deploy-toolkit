#!/usr/bin/env bash
set -euo pipefail

CHECK_URL="${HEALTHCHECK_URL:-}"
CHECK_NAME="${HEALTHCHECK_NAME:-app}"
TIMEOUT_SECONDS="${HEALTHCHECK_TIMEOUT:-5}"
RETRIES="${HEALTHCHECK_RETRIES:-3}"
RETRY_DELAY_SECONDS="${HEALTHCHECK_RETRY_DELAY:-5}"
STATE_DIR="${HEALTHCHECK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/healthcheck}"
WEBHOOK_FILE="${HEALTHCHECK_WEBHOOK_FILE:-}"

webhook_url=""
failure_detail=""

usage() {
  cat <<EOF
Usage: $(basename "$0") --url URL [options]

Checks a health URL with a timeout and retries. Sends a webhook message only
when the state changes: once when it goes down and once when it recovers.
Slack and Discord incoming webhooks both accept the payload.

The webhook URL is read from ALERT_WEBHOOK_URL or from --webhook-file, never
from the command line, so it does not show up in the process list.

Options (environment variable in brackets):
  --url URL             Health endpoint that must return 2xx            [HEALTHCHECK_URL]
  --name NAME           Name used in messages and the state file
                        (default: app)                                  [HEALTHCHECK_NAME]
  --timeout SECONDS     Per-request timeout (default: 5)                [HEALTHCHECK_TIMEOUT]
  --retries N           Attempts before declaring it down (default: 3)  [HEALTHCHECK_RETRIES]
  --retry-delay SECONDS Pause between attempts (default: 5)             [HEALTHCHECK_RETRY_DELAY]
  --state-dir DIR       Where the last known state is kept
                        (default: ~/.local/state/healthcheck)           [HEALTHCHECK_STATE_DIR]
  --webhook-file PATH   File containing only the webhook URL            [HEALTHCHECK_WEBHOOK_FILE]
  -h, --help            Show this help

Exit codes: 0 healthy, 1 unhealthy, 2 usage error, 3 alert could not be delivered.
EOF
}

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

require_value() {
  [[ $# -ge 2 && -n "$2" ]] || die "$1 needs a value"
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --url) require_value "$@"; CHECK_URL="$2"; shift 2 ;;
      --name) require_value "$@"; CHECK_NAME="$2"; shift 2 ;;
      --timeout) require_value "$@"; TIMEOUT_SECONDS="$2"; shift 2 ;;
      --retries) require_value "$@"; RETRIES="$2"; shift 2 ;;
      --retry-delay) require_value "$@"; RETRY_DELAY_SECONDS="$2"; shift 2 ;;
      --state-dir) require_value "$@"; STATE_DIR="$2"; shift 2 ;;
      --webhook-file) require_value "$@"; WEBHOOK_FILE="$2"; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) usage >&2; die "unknown option: $1" ;;
    esac
  done
}

validate_args() {
  [[ -n "$CHECK_URL" ]] || { usage >&2; die "--url is required"; }
  [[ "$CHECK_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "--name may only contain letters, digits, '.', '_' and '-'"
  [[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "--timeout must be a positive number"
  [[ "$RETRIES" =~ ^[1-9][0-9]*$ ]] || die "--retries must be a positive number"
  [[ "$RETRY_DELAY_SECONDS" =~ ^[0-9]+$ ]] || die "--retry-delay must be a number"
  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v flock >/dev/null 2>&1 || die "flock is required"
}

load_webhook_url() {
  if [[ -n "$WEBHOOK_FILE" ]]; then
    [[ -r "$WEBHOOK_FILE" ]] || die "cannot read webhook file: $WEBHOOK_FILE"
    webhook_url="$(tr -d '[:space:]' <"$WEBHOOK_FILE")"
  else
    webhook_url="${ALERT_WEBHOOK_URL:-}"
  fi
}

describe_curl_error() {
  case "$1" in
    6) printf 'DNS lookup failed' ;;
    7) printf 'connection refused' ;;
    28) printf 'timed out after %ss' "$TIMEOUT_SECONDS" ;;
    35 | 60) printf 'TLS error (curl exit %s)' "$1" ;;
    *) printf 'curl exit %s' "$1" ;;
  esac
}

probe() {
  local http_code curl_status=0
  http_code="$(curl --silent --output /dev/null --max-time "$TIMEOUT_SECONDS" \
    --write-out '%{http_code}' "$CHECK_URL")" || curl_status=$?

  if ((curl_status != 0)); then
    failure_detail="$(describe_curl_error "$curl_status")"
    return 1
  fi
  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    failure_detail="HTTP $http_code"
    return 1
  fi
}

check_with_retries() {
  local attempt
  for ((attempt = 1; attempt <= RETRIES; attempt++)); do
    if probe; then
      return 0
    fi
    if ((attempt < RETRIES)); then
      sleep "$RETRY_DELAY_SECONDS"
    fi
  done
  failure_detail="$failure_detail, $RETRIES attempts"
  return 1
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

send_alert() {
  local message="$1" escaped payload
  if [[ -z "$webhook_url" ]]; then
    log "no webhook configured, alert not sent"
    return 0
  fi
  escaped="$(json_escape "$message")"
  payload="$(printf '{"text":"%s","content":"%s"}' "$escaped" "$escaped")"
  printf 'url = "%s"\n' "$webhook_url" |
    curl --silent --show-error --fail --max-time 10 --config - \
      --header 'Content-Type: application/json' --data "$payload" --output /dev/null
}

format_duration() {
  local total="$1"
  local hours=$((total / 3600)) minutes=$((total % 3600 / 60)) seconds=$((total % 60))
  if ((hours > 0)); then
    printf '%dh %dm' "$hours" "$minutes"
  elif ((minutes > 0)); then
    printf '%dm %ds' "$minutes" "$seconds"
  else
    printf '%ds' "$seconds"
  fi
}

main() {
  parse_args "$@"
  validate_args
  load_webhook_url

  mkdir -p -- "$STATE_DIR"
  local state_file="$STATE_DIR/$CHECK_NAME.state"
  exec 9>"$state_file.lock"
  if ! flock -n 9; then
    log "previous check for $CHECK_NAME is still running, skipping"
    exit 0
  fi

  local now previous_status="up" previous_since="" current_status message
  now="$(date +%s)"
  if [[ -f "$state_file" ]]; then
    read -r previous_status previous_since <"$state_file" || true
  fi
  if [[ "$previous_status" != "up" && "$previous_status" != "down" ]]; then
    previous_status="up"
  fi
  if [[ ! "$previous_since" =~ ^[0-9]+$ ]]; then
    previous_since="$now"
  fi

  if check_with_retries; then
    current_status="up"
  else
    current_status="down"
  fi

  if [[ "$current_status" == "$previous_status" ]]; then
    if [[ "$current_status" == "up" ]]; then
      log "$CHECK_NAME is up"
    else
      log "$CHECK_NAME is still down ($failure_detail), alert already sent"
    fi
  else
    if [[ "$current_status" == "down" ]]; then
      message="[$CHECK_NAME] DOWN: $CHECK_URL ($failure_detail). Checked from $(hostname -s) at $(date -u '+%Y-%m-%d %H:%M UTC')."
    else
      message="[$CHECK_NAME] RECOVERED: $CHECK_URL is healthy again after $(format_duration $((now - previous_since))) down."
    fi
    log "$message"
    if ! send_alert "$message"; then
      printf 'ERROR: could not deliver the alert; state not saved so the next run tries again\n' >&2
      exit 3
    fi
    printf '%s %s\n' "$current_status" "$now" >"$state_file"
  fi

  [[ "$current_status" == "up" ]] || exit 1
}

main "$@"
