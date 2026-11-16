#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${APP_ROOT:-/srv/app}/shared/.env}"
EXAMPLE_FILE="${EXAMPLE_FILE:-$SCRIPT_DIR/../env/.env.example}"

PLACEHOLDER_MARKERS=(change-me changeme replace-me placeholder example.com example.org)

declare -A env_values=()
required_keys=()
parsed_key=""
parsed_value=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [--env-file PATH] [--example PATH]

Checks that every variable named in the example file is present in the env file,
is not empty and no longer holds a placeholder (change-me, example.com, <...>).
Prints variable names only, never values. Exits 1 if anything needs attention.

Options (environment variable in brackets):
  --env-file PATH   Env file to check (default: /srv/app/shared/.env)        [ENV_FILE]
  --example PATH    Template listing required variables
                    (default: env/.env.example in this toolkit)              [EXAMPLE_FILE]
  -h, --help        Show this help
EOF
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
      --env-file) require_value "$@"; ENV_FILE="$2"; shift 2 ;;
      --example) require_value "$@"; EXAMPLE_FILE="$2"; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) usage >&2; die "unknown option: $1" ;;
    esac
  done
}

parse_env_line() {
  local line="${1%$'\r'}"
  local assignment='^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$'
  local double_quoted='^"(.*)"$'
  local single_quoted="^'(.*)'\$"
  [[ "$line" =~ $assignment ]] || return 1
  parsed_key="${BASH_REMATCH[2]}"
  parsed_value="${BASH_REMATCH[3]}"
  if [[ "$parsed_value" =~ $double_quoted || "$parsed_value" =~ $single_quoted ]]; then
    parsed_value="${BASH_REMATCH[1]}"
  fi
}

read_env_file() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if parse_env_line "$line"; then
      env_values["$parsed_key"]="$parsed_value"
    fi
  done <"$ENV_FILE"
}

read_required_keys() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if parse_env_line "$line"; then
      required_keys+=("$parsed_key")
    fi
  done <"$EXAMPLE_FILE"
}

is_placeholder() {
  local value="${1,,}" marker
  local angle_brackets='^<.*>$'
  if [[ "$value" =~ $angle_brackets ]]; then
    return 0
  fi
  for marker in "${PLACEHOLDER_MARKERS[@]}"; do
    if [[ "$value" == *"$marker"* ]]; then
      return 0
    fi
  done
  return 1
}

is_required() {
  local candidate="$1" key
  for key in "${required_keys[@]}"; do
    if [[ "$key" == "$candidate" ]]; then
      return 0
    fi
  done
  return 1
}

report() {
  printf '  %-12s %s\n' "$1" "$2"
}

warn_if_readable_by_others() {
  local mode
  mode="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE")"
  if [[ "${mode: -2}" != "00" ]]; then
    printf 'WARNING: %s has mode %s; run: chmod 600 %s\n' "$ENV_FILE" "$mode" "$ENV_FILE" >&2
  fi
}

main() {
  parse_args "$@"
  [[ -r "$EXAMPLE_FILE" ]] || die "cannot read template: $EXAMPLE_FILE"
  [[ -r "$ENV_FILE" ]] || die "cannot read env file: $ENV_FILE"

  read_required_keys
  read_env_file
  ((${#required_keys[@]} > 0)) || die "no variables found in $EXAMPLE_FILE"

  printf 'Checking %s\n' "$ENV_FILE"
  local key value problems=0
  for key in "${required_keys[@]}"; do
    if [[ -z "${env_values[$key]+set}" ]]; then
      report missing "$key"
      problems=$((problems + 1))
      continue
    fi
    value="${env_values[$key]}"
    if [[ -z "${value//[[:space:]]/}" ]]; then
      report empty "$key"
      problems=$((problems + 1))
    elif is_placeholder "$value"; then
      report placeholder "$key"
      problems=$((problems + 1))
    else
      report ok "$key"
    fi
  done

  for key in "${!env_values[@]}"; do
    if ! is_required "$key"; then
      report extra "$key (not in template, not checked)"
    fi
  done

  warn_if_readable_by_others

  if ((problems > 0)); then
    printf '%d of %d required variables need attention.\n' "$problems" "${#required_keys[@]}" >&2
    exit 1
  fi
  printf 'All %d required variables are set.\n' "${#required_keys[@]}"
}

main "$@"
