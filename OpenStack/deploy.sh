#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

usage() {
  printf '%s\n' \
    'Usage: ./deploy.sh [--init | --apply [CSV] | --destroy | --help]' \
    '       ./deploy.sh [CSV]' \
    'Defaults: --apply and the bare form use ../config/users.csv.'
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  usage >&2
  exit 2
}

case "${1:-}" in
  --help|-h)
    [[ "$#" -eq 1 ]] || die '--help does not accept additional arguments.'
    usage
    exit 0
    ;;
  --init)
    [[ "$#" -eq 1 ]] || die '--init does not accept additional arguments.'
    exec "${SCRIPT_DIR}/run.sh" init
    ;;
  --destroy)
    [[ "$#" -eq 1 ]] || die '--destroy does not accept additional arguments.'
    exec "${SCRIPT_DIR}/destroy.sh"
    ;;
  --apply)
    [[ "$#" -le 2 ]] || die '--apply accepts at most one CSV path.'
    if [[ "$#" -eq 1 ]]; then
      csv_path="${SCRIPT_DIR}/../config/users.csv"
    else
      csv_path=$2
    fi
    [[ -n "$csv_path" && "$csv_path" != --* ]] || die '--apply requires a CSV path.'
    exec "${SCRIPT_DIR}/run.sh" apply "$csv_path"
    ;;
  --*)
    die "unknown option: $1"
    ;;
  *)
    [[ "$#" -le 1 ]] || die 'a bare invocation accepts only one CSV path.'
    if [[ "$#" -eq 0 ]]; then
      csv_path="${SCRIPT_DIR}/../config/users.csv"
    else
      csv_path=$1
    fi
    [[ -n "$csv_path" && "$csv_path" != --* ]] || die 'CSV path must not be an option.'
    exec "${SCRIPT_DIR}/run.sh" apply "$csv_path"
    ;;
esac
