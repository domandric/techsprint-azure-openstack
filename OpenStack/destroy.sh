#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}" && pwd -P)"
STATE_ENV_FILE="${ROOT_DIR}/runtime/terraform-state.env"
BACKEND_DIR="${ROOT_DIR}/runtime/terraform-backend"
INPUT_DIR="${ROOT_DIR}/runtime/terraform-inputs"
MAX_RECONCILIATION_ATTEMPTS=50

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" -eq 0 ]] || die 'destroy.sh does not accept arguments.'
command -v terraform >/dev/null 2>&1 || die 'required command not found: terraform'

[[ -n "${OS_AUTH_URL:-}" ]] || die "source an administrator OpenRC first (OS_AUTH_URL is unset)."
[[ -n "${OS_PROJECT_ID:-${OS_PROJECT_NAME:-}}" ]] || die "source an administrator OpenRC first (OS_PROJECT_ID or OS_PROJECT_NAME is unset)."
if [[ -z "${OS_USERNAME:-}" && -z "${OS_USER_ID:-}" && -z "${OS_APPLICATION_CREDENTIAL_ID:-}" && -z "${OS_TOKEN:-}" ]]; then
  die "source an administrator OpenRC first (no Keystone identity credential is present)."
fi

[[ -f "$STATE_ENV_FILE" ]] || die "Terraform state environment file is missing: $STATE_ENV_FILE"
# shellcheck disable=SC1090
source "$STATE_ENV_FILE"
export AWS_EC2_METADATA_DISABLED=true

init_root() {
  local root=$1
  local backend=$2
  terraform -chdir="${ROOT_DIR}/${root}" init -reconfigure \
    -backend-config="${BACKEND_DIR}/${backend}"
}

init_root bootstrap bootstrap.hcl
init_root roots/shared shared.hcl
init_root roots/developer developer.hcl
init_root roots/shared-reconcile shared-reconcile.hcl

terraform_state_nonempty() {
  local root=$1
  local state_output state_status

  STATE_EMPTY=false
  if state_output="$(terraform -chdir="$root" state list 2>&1)"; then
    if [[ -z "${state_output//[[:space:]]/}" ]]; then
      STATE_EMPTY=true
    fi
    return 0
  else
    state_status=$?
    if [[ "$state_output" == *'No state file was found'* ]]; then
      STATE_EMPTY=true
      return 0
    fi
    printf '%s\n' "$state_output" >&2
    return "$state_status"
  fi
}

run_terraform_captured() {
  local output_file=$1
  shift
  local -a pipeline_status

  if "$@" 2>&1 | tee "$output_file"; then
    CAPTURED_STATUS=0
  else
    pipeline_status=("${PIPESTATUS[@]}")
    CAPTURED_STATUS=${pipeline_status[0]}
    if (( CAPTURED_STATUS == 0 )); then
      CAPTURED_STATUS=${pipeline_status[1]}
    fi
  fi
}

failure_is_missing_resource() {
  local output_file=$1
  local output

  output="$(<"$output_file")"
  [[ "$output" == *404* || "$output" == *NotFound* || "$output" == *'could not be found'* ]]
}

extract_diagnostic_addresses() {
  local output_file=$1
  local line address

  DIAGNOSTIC_ADDRESSES=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[^[:alnum:]_]*with[[:space:]]+(.+[^[:space:]]),[[:space:]]*$ ]]; then
      address="${BASH_REMATCH[1]}"
      DIAGNOSTIC_ADDRESSES+=("$address")
    fi
  done <"$output_file"
}

remove_diagnostic_addresses() {
  local root=$1
  local address seen_address duplicate state_rm_status
  local removed=0
  local -a seen_addresses=()

  for address in "${DIAGNOSTIC_ADDRESSES[@]}"; do
    duplicate=false
    for seen_address in "${seen_addresses[@]}"; do
      if [[ "$seen_address" == "$address" ]]; then
        duplicate=true
        break
      fi
    done
    [[ "$duplicate" == true ]] && continue
    seen_addresses+=("$address")

    printf 'Removing stale missing-resource address: %s\n' "$address" >&2
    if terraform -chdir="$root" state rm "$address"; then
      removed=$((removed + 1))
    else
      state_rm_status=$?
      printf 'WARNING: could not remove stale address %s (terraform state rm exited %s).\n' \
        "$address" "$state_rm_status" >&2
    fi
  done

  (( removed > 0 ))
}

refresh_root() {
  local root=$1
  local input=$2
  local attempt=1 status output_file

  while (( attempt <= MAX_RECONCILIATION_ATTEMPTS )); do
    output_file="$(mktemp)"
    run_terraform_captured "$output_file" terraform -chdir="$root" apply \
      -refresh-only -auto-approve -input=false -no-color -var-file="$input"
    status=$CAPTURED_STATUS

    if (( status == 0 )); then
      rm -f -- "$output_file"
      return 0
    fi
    if ! failure_is_missing_resource "$output_file"; then
      rm -f -- "$output_file"
      return "$status"
    fi
    if (( attempt == MAX_RECONCILIATION_ATTEMPTS )); then
      printf 'ERROR: refresh reconciliation limit (%s) reached.\n' \
        "$MAX_RECONCILIATION_ATTEMPTS" >&2
      rm -f -- "$output_file"
      return "$status"
    fi

    extract_diagnostic_addresses "$output_file"
    if ! remove_diagnostic_addresses "$root"; then
      rm -f -- "$output_file"
      return "$status"
    fi
    rm -f -- "$output_file"
    attempt=$((attempt + 1))
  done

  return 1
}

destroy_root() {
  local root=$1
  local input=$2
  local attempt=1 status refresh_status output_file

  terraform_state_nonempty "$root"
  [[ "$STATE_EMPTY" == true ]] && return 0

  refresh_root "$root" "$input"
  terraform_state_nonempty "$root"
  [[ "$STATE_EMPTY" == true ]] && return 0

  while (( attempt <= MAX_RECONCILIATION_ATTEMPTS )); do
    output_file="$(mktemp)"
    run_terraform_captured "$output_file" terraform -chdir="$root" destroy \
      -auto-approve -input=false -no-color -var-file="$input"
    status=$CAPTURED_STATUS

    if (( status == 0 )); then
      rm -f -- "$output_file"
      terraform_state_nonempty "$root"
      if [[ "$STATE_EMPTY" == true ]]; then
        return 0
      fi
      printf 'ERROR: Terraform destroy succeeded but state is not empty for %s.\n' "$root" >&2
      return 1
    fi
    if ! failure_is_missing_resource "$output_file"; then
      rm -f -- "$output_file"
      return "$status"
    fi
    if (( attempt == MAX_RECONCILIATION_ATTEMPTS )); then
      printf 'ERROR: destroy reconciliation limit (%s) reached.\n' \
        "$MAX_RECONCILIATION_ATTEMPTS" >&2
      rm -f -- "$output_file"
      return "$status"
    fi

    extract_diagnostic_addresses "$output_file"
    if ! remove_diagnostic_addresses "$root"; then
      rm -f -- "$output_file"
      return "$status"
    fi
    rm -f -- "$output_file"

    if refresh_root "$root" "$input"; then
      :
    else
      refresh_status=$?
      return "$refresh_status"
    fi
    terraform_state_nonempty "$root"
    [[ "$STATE_EMPTY" == true ]] && return 0
    attempt=$((attempt + 1))
  done

  return 1
}

DEVELOPER_ROOT="${ROOT_DIR}/roots/developer"
developer_workspaces=()
workspace_list="$(terraform -chdir="$DEVELOPER_ROOT" workspace list)"
while IFS= read -r workspace_line; do
  workspace="${workspace_line//[*]/}"
  workspace="${workspace//[[:space:]]/}"
  [[ -n "$workspace" && "$workspace" != default ]] || continue
  workspace_input="${INPUT_DIR}/${workspace}.json"
  [[ -f "$workspace_input" ]] || die "missing Terraform input for developer workspace ${workspace@Q}: $workspace_input"
  developer_workspaces+=("$workspace")
done <<<"$workspace_list"

terraform -chdir="${ROOT_DIR}/roots/shared-reconcile" workspace select default
destroy_root "${ROOT_DIR}/roots/shared-reconcile" "${INPUT_DIR}/shared-reconcile.json"

for workspace in "${developer_workspaces[@]}"; do
  workspace_input="${INPUT_DIR}/${workspace}.json"
  terraform -chdir="$DEVELOPER_ROOT" workspace select "$workspace"
  destroy_root "$DEVELOPER_ROOT" "$workspace_input"
  terraform -chdir="$DEVELOPER_ROOT" workspace select default
  terraform -chdir="$DEVELOPER_ROOT" workspace delete "$workspace"
done

terraform -chdir="${ROOT_DIR}/roots/shared" workspace select default
destroy_root "${ROOT_DIR}/roots/shared" "${INPUT_DIR}/shared.json"

terraform -chdir="${ROOT_DIR}/bootstrap" workspace select default
destroy_root "${ROOT_DIR}/bootstrap" "${INPUT_DIR}/bootstrap.json"

printf 'Note: the state backend container, EC2 credentials, and Rocky image were left intact.\n'
