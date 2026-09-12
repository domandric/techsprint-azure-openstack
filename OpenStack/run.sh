#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}" && pwd)"
STATE_ENV_FILE="${ROOT_DIR}/runtime/terraform-state.env"
BACKEND_DIR="${ROOT_DIR}/runtime/terraform-backend"
INPUT_DIR="${ROOT_DIR}/runtime/terraform-inputs"
PLAN_DIR="${ROOT_DIR}/runtime/plans"
KEY_DIR="${ROOT_DIR}/keys"
current_stage="startup"

die() {
  printf 'ERROR: stage %s failed: %s\n' "$current_stage" "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

ensure_ssh_keypair() {
  bash "${ROOT_DIR}/scripts/ensure-ssh-keypair.sh" "$1"
}

report_stage_failure() {
  local status=$1
  printf 'ERROR: stage %s failed (exit %s).\n' "$current_stage" "$status" >&2
  exit "$status"
}

run_stage() {
  local status
  current_stage=$1
  shift
  if "$@"; then
    return 0
  else
    status=$?
    report_stage_failure "$status"
  fi
}

mode=init
csv_path=""
case "${1:-}" in
  "")
    ;;
  init)
    [[ "$#" -eq 1 ]] || die 'init does not accept additional arguments.'
    ;;
  apply)
    [[ "$#" -eq 2 ]] || die 'usage: bash run.sh apply CSV'
    csv_path=$2
    [[ -n "$csv_path" && "$csv_path" != --* ]] || die 'apply requires the CSV path before any option.'
    mode=apply
    ;;
  *)
    die "unknown subcommand: $1 (expected init or apply)"
    ;;
esac

current_stage='preflight'
for command in terraform openstack jq; do
  require_command "$command"
done
if [[ "$mode" == apply ]]; then
  require_command python3
  require_command ssh-keygen
  [[ -f "$csv_path" ]] || die "CSV input is not a regular file: $csv_path"
fi

[[ -n "${OS_AUTH_URL:-}" ]] || die "source an administrator OpenRC first (OS_AUTH_URL is unset)."
[[ -n "${OS_PROJECT_ID:-${OS_PROJECT_NAME:-}}" ]] || die "source an administrator OpenRC first (OS_PROJECT_ID or OS_PROJECT_NAME is unset)."
if [[ -z "${OS_USERNAME:-}" && -z "${OS_USER_ID:-}" && -z "${OS_APPLICATION_CREDENTIAL_ID:-}" && -z "${OS_TOKEN:-}" ]]; then
  die "source an administrator OpenRC first (no Keystone identity credential is present)."
fi

run_stage 'state backend preparation' bash "${ROOT_DIR}/scripts/bootstrap-state-backend.sh"

current_stage='load generated Terraform state environment'
if source "${STATE_ENV_FILE}"; then
  :
else
  status=$?
  report_stage_failure "$status"
fi
if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" || -z "${AWS_ENDPOINT_URL_S3:-}" ]]; then
  report_stage_failure 1
fi
export AWS_EC2_METADATA_DISABLED=true

init_root() {
  local label=$1
  local root=$2
  local backend=$3

  run_stage "Terraform init ${label}" terraform \
    -chdir="${ROOT_DIR}/${root}" init -reconfigure \
    -backend-config="${BACKEND_DIR}/${backend}"
}

init_root bootstrap bootstrap bootstrap.hcl
init_root shared roots/shared shared.hcl
init_root developer roots/developer developer.hcl
init_root shared-reconcile roots/shared-reconcile shared-reconcile.hcl

if [[ "$mode" == init ]]; then
  printf '\nPrerequisites are ready and all four Terraform roots were initialized. No plan or apply was run.\n'
  printf 'Next plan/apply order: bootstrap, roots/shared, one roots/developer workspace per developer slug, then roots/shared-reconcile.\n'
  exit 0
fi

current_stage='inspect bootstrap name seed'
read_bootstrap_name_seed() {
  local bootstrap_name_seed bootstrap_state_output

  if bootstrap_name_seed="$(terraform -chdir="${ROOT_DIR}/bootstrap" output -raw name_seed 2>/dev/null)" \
    && [[ -n "$bootstrap_name_seed" ]]; then
    if [[ -n ${TECHSPRINT_NAME_SEED:-} ]]; then
      [[ "$TECHSPRINT_NAME_SEED" == "$bootstrap_name_seed" ]] || die 'TECHSPRINT_NAME_SEED must exactly match the persisted bootstrap name_seed.'
    fi
    NAME_SEED="$bootstrap_name_seed"
    return 0
  fi

  # Distinguish empty state from unreadable nonempty state before defaulting;
  # state diagnostics remain private.
  if bootstrap_state_output="$(terraform -chdir="${ROOT_DIR}/bootstrap" state list 2>&1)"; then
    if [[ -n "${bootstrap_state_output//[[:space:]]/}" ]]; then
      die 'bootstrap state is nonempty but its name_seed output could not be read.'
    fi
  else
    [[ "$bootstrap_state_output" == *'No state file was found'* ]] || die 'could not safely determine bootstrap state or read its name_seed output.'
  fi

  if [[ -n ${TECHSPRINT_NAME_SEED:-} ]]; then
    NAME_SEED="$TECHSPRINT_NAME_SEED"
  else
    NAME_SEED='iruo-lab'
  fi
}
read_bootstrap_name_seed
name_seed_is_valid() {
  local LC_ALL=C

  (( ${#NAME_SEED} >= 4 && ${#NAME_SEED} <= 32 )) &&
    [[ "${NAME_SEED:0:1}" =~ ^[a-z]$ ]] &&
    [[ "$NAME_SEED" =~ ^[a-z0-9-]+$ ]]
}

if ! name_seed_is_valid; then
  printf -v quoted_name_seed '%q' "$NAME_SEED"
  die "invalid TECHSPRINT_NAME_SEED (selected value: ${quoted_name_seed}); must be 4-32 characters, start with a lowercase ASCII letter, and contain only lowercase ASCII letters, digits, or hyphens."
fi
SHARED_PROJECT_NAME="${NAME_SEED}-shared"

current_stage='render Terraform inputs'
mkdir -p "$INPUT_DIR" "$PLAN_DIR"
chmod 700 "$INPUT_DIR" "$PLAN_DIR"
USERS_JSON="${INPUT_DIR}/users.json"
python3 "${ROOT_DIR}/scripts/render-terraform-inputs.py" "$csv_path" "$USERS_JSON" || report_stage_failure $?
chmod 600 "$USERS_JSON"

developer_slugs_text="$(jq -er '.developer_slugs | if type == "array" then .[] else error("developer_slugs must be an array") end' "$USERS_JSON")" || die 'rendered inputs did not contain an ordered developer slug list.'
DEVELOPER_SLUGS=()
while IFS= read -r slug; do
  [[ -n "$slug" ]] && DEVELOPER_SLUGS+=("$slug")
done <<<"$developer_slugs_text"
[[ "${#DEVELOPER_SLUGS[@]}" -gt 0 ]] || die 'rendered inputs contained no developer slugs.'

declare -A DEVELOPER_PUBLIC_KEYS=()
DEVELOPER_SSH_PUBLIC_KEYS_JSON='{}'
current_stage='ensure developer SSH keys'
for slug in "${DEVELOPER_SLUGS[@]}"; do
  developer_key_path="${KEY_DIR}/${slug}_ssh"
  if developer_public_key="$(ensure_ssh_keypair "$developer_key_path")"; then
    DEVELOPER_PUBLIC_KEYS["$slug"]="$developer_public_key"
    DEVELOPER_SSH_PUBLIC_KEYS_JSON="$(jq -cn \
      --argjson existing "$DEVELOPER_SSH_PUBLIC_KEYS_JSON" \
      --arg slug "$slug" \
      --arg public_key "$developer_public_key" \
      '$existing + {($slug): $public_key}')"
  else
    status=$?
    report_stage_failure "$status"
  fi
done

current_stage='discover Keystone token identity'
token_json="$(openstack token issue -f json)" || report_stage_failure $?
PROVISIONER_USER_ID="$(jq -er '(.user_id // .["User ID"] // empty) | select(type == "string" and length > 0)' <<<"$token_json")" || die 'token issue did not return exactly one usable current user ID.'
TOKEN_PROJECT_ID="$(jq -er '
  (.project_id // .["Project ID"] // empty)
  | select(type == "string" and length > 0)
' <<<"$token_json")" \
  || die 'token issue returned no usable project ID.'

project_json="$(openstack project show "$TOKEN_PROJECT_ID" -f json)" \
  || die 'could not inspect the authenticated project.'

DOMAIN_ID="$(jq -er '
  (.domain_id // .["Domain ID"] // empty)
  | select(type == "string" and length > 0)
' <<<"$project_json")" \
  || die 'authenticated project returned no usable domain ID.'

AUTH_URL="${OS_AUTH_URL}"
ROCKY_IMAGE_NAME='Rocky-8-GenericCloud-Base-8.10-20240528.0.x86_64'
if [[ -n "${TECHSPRINT_IMAGE_ID:-}" ]]; then
  IMAGE_ID="${TECHSPRINT_IMAGE_ID}"
else
  current_stage='discover Rocky image'
  image_json="$(openstack image show "$ROCKY_IMAGE_NAME" -f json)" || report_stage_failure $?
  IMAGE_ID="$(jq -er 'if type == "object" then (.id // empty) else empty end | select(type == "string" and length > 0)' <<<"$image_json")" || die 'Rocky image lookup did not return exactly one usable ID.'
fi
[[ "$IMAGE_ID" != *[[:space:][:cntrl:]]* && -n "$IMAGE_ID" ]] || die 'Rocky image ID is empty or contains whitespace/control characters.'

PRIVATE_KEY="${KEY_DIR}/lead_ssh"
current_stage='ensure lead SSH key'
if PUBLIC_KEY_TEXT="$(ensure_ssh_keypair "$PRIVATE_KEY")"; then
  :
else
  status=$?
  report_stage_failure "$status"
fi
PRIVATE_KEY_TEXT="$(<"$PRIVATE_KEY")"

render_json_file() {
  local target=$1
  shift
  local temporary
  temporary="$(mktemp "${target}.XXXXXX")"
  chmod 600 "$temporary"
  if "$@" >"$temporary"; then
    chmod 600 "$temporary"
    mv -f -- "$temporary" "$target"
  else
    status=$?
    rm -f -- "$temporary"
    report_stage_failure "$status"
  fi
}

current_stage='write protected Terraform inputs'
render_json_file "${INPUT_DIR}/bootstrap.json" jq -n \
  --slurpfile inputs "$USERS_JSON" \
  --arg name_seed "$NAME_SEED" \
  --arg domain_id "$DOMAIN_ID" \
  --arg provisioner_user_id "$PROVISIONER_USER_ID" \
  '{name_seed: $name_seed, users: $inputs[0].users, domain_id: $domain_id, provisioner_user_id: $provisioner_user_id}'

render_json_file "${INPUT_DIR}/shared.json" jq -n \
  --arg auth_url "$AUTH_URL" \
  --arg domain_id "$DOMAIN_ID" \
  --arg image_id "$IMAGE_ID" \
  --arg public_key "$PUBLIC_KEY_TEXT" \
  --arg private_key "$PRIVATE_KEY_TEXT" \
  --argjson developer_ssh_public_keys "$DEVELOPER_SSH_PUBLIC_KEYS_JSON" \
  '{auth_url: $auth_url, domain_id: $domain_id, image_id: $image_id, lead_ssh_public_key: ($public_key | sub("[\\r\\n]+$"; "")), lead_ssh_private_key: $private_key, developer_ssh_public_keys: $developer_ssh_public_keys}'

for slug in "${DEVELOPER_SLUGS[@]}"; do
  render_json_file "${INPUT_DIR}/${slug}.json" jq -n \
    --arg slug "$slug" \
    --arg image_id "$IMAGE_ID" \
    --arg public_key "${DEVELOPER_PUBLIC_KEYS[$slug]}" \
    '{developer: {slug: $slug}, image_id: $image_id, public_ssh_key: ($public_key | sub("[\\r\\n]+$"; ""))}'
done

render_json_file "${INPUT_DIR}/shared-reconcile.json" jq -n \
  --slurpfile inputs "$USERS_JSON" \
  '{developer_slugs: $inputs[0].developer_slugs}'

check_empty_bootstrap_state() {
  local state_file state_status state_output project_json project_count
  state_file="$(mktemp "${ROOT_DIR}/runtime/.bootstrap-state.XXXXXX")"
  chmod 600 "$state_file"
  if terraform -chdir="${ROOT_DIR}/bootstrap" state list >"$state_file" 2>&1; then
    state_output="$(<"$state_file")"
  else
    state_status=$?
    state_output="$(<"$state_file")"
    rm -f -- "$state_file"
    if [[ "$state_output" == *'No state file was found'* ]]; then
      state_output=""
    else
      printf '%s\n' "$state_output" >&2
      return "$state_status"
    fi
  fi
  rm -f -- "$state_file"
  [[ -z "${state_output//[[:space:]]/}" ]] || return 0

  project_json="$(openstack project list -f json)" || return $?
  project_count="$(jq -er --arg wanted "$SHARED_PROJECT_NAME" 'if type == "array" then [.[] | (.Name // .name // "") | select(. == $wanted)] | length else error("project list was not an array") end' <<<"$project_json")" || return $?
  if [[ "$project_count" != 0 ]]; then
    die "bootstrap state is empty but ${SHARED_PROJECT_NAME@Q} already exists; Terraform will not adopt it by name. Follow MIGRATION.md."
  fi
}
run_stage 'bootstrap existing-resource safety check' check_empty_bootstrap_state

recover_existing_flavor() {
  local flavor_key=$1
  local flavor_name=$2
  local address="openstack_compute_flavor_v2.flavor[\"${flavor_key}\"]"
  local state_output state_status state_line flavor_list_output flavor_id candidate_id candidate_name
  local match_count=0

  if state_output="$(terraform -chdir="${ROOT_DIR}/bootstrap" state list 2>&1)"; then
    while IFS= read -r state_line; do
      [[ "$state_line" == "$address" ]] && return 0
    done <<<"$state_output"
  else
    state_status=$?
    if [[ "$state_output" == *'No state file was found'* ]]; then
      state_output=""
    else
      printf '%s\n' "$state_output" >&2
      return "$state_status"
    fi
  fi

  flavor_list_output="$(openstack flavor list -f value -c ID -c Name)" || return $?
  while read -r candidate_id candidate_name _; do
    if [[ "$candidate_name" == "$flavor_name" ]]; then
      (( ++match_count ))
      if (( match_count > 1 )); then
        die "OpenStack flavor ${flavor_name@Q} matched multiple rows; refusing to guess."
      fi
      flavor_id=$candidate_id
    fi
  done <<<"$flavor_list_output"

  (( match_count == 1 )) || return 0
  [[ -n "$flavor_id" && "$flavor_id" != *[[:space:][:cntrl:]]* ]] || die "OpenStack flavor ${flavor_name@Q} returned an empty or invalid ID."

  terraform -chdir="${ROOT_DIR}/bootstrap" import -input=false -var-file="${INPUT_DIR}/bootstrap.json" "$address" "$flavor_id"
}

recover_existing_user() {
  local slug=$1
  local address="openstack_identity_user_v3.user[\"${slug}\"]"
  local password_address="random_password.human[\"${slug}\"]"
  local username="usr-${NAME_SEED}-${slug}"
  local state_output state_status state_line user_list_output user_id candidate_id candidate_name password_state_found=false
  local match_count=0

  if state_output="$(terraform -chdir="${ROOT_DIR}/bootstrap" state list 2>&1)"; then
    while IFS= read -r state_line; do
      [[ "$state_line" == "$address" ]] && return 0
    done <<<"$state_output"
  else
    state_status=$?
    if [[ "$state_output" == *'No state file was found'* ]]; then
      state_output=""
    else
      printf '%s\n' "$state_output" >&2
      return "$state_status"
    fi
  fi

  user_list_output="$(openstack user list --domain "$DOMAIN_ID" -f value -c ID -c Name)" || return $?
  while read -r candidate_id candidate_name _; do
    if [[ "$candidate_name" == "$username" ]]; then
      (( ++match_count ))
      if (( match_count > 1 )); then
        die "OpenStack user ${username@Q} matched multiple rows; refusing to guess."
      fi
      user_id=$candidate_id
    fi
  done <<<"$user_list_output"

  (( match_count == 1 )) || return 0
  [[ -n "$user_id" && "$user_id" != *[[:space:][:cntrl:]]* ]] || die "OpenStack user ${username@Q} returned an empty or invalid ID."

  # Import only users whose password state survives; the next apply manages the
  # existing Keystone credential authoritatively.
  while IFS= read -r state_line; do
    if [[ "$state_line" == "$password_address" ]]; then
      password_state_found=true
      break
    fi
  done <<<"$state_output"
  [[ "$password_state_found" == true ]] || die "OpenStack user ${username@Q} exists, but ${password_address@Q} is absent from bootstrap state; refusing automatic recovery. Perform explicit state migration or cleanup before rerunning."

  terraform -chdir="${ROOT_DIR}/bootstrap" import -input=false -var-file="${INPUT_DIR}/bootstrap.json" "$address" "$user_id"
}

run_stage 'bootstrap shared flavor recovery' recover_existing_flavor shared flv-techsprint-lab-small
run_stage 'bootstrap app flavor recovery' recover_existing_flavor app flv-techsprint-app
run_stage 'bootstrap database flavor recovery' recover_existing_flavor database flv-techsprint-db

user_slugs_text="$(jq -er '.users | keys[]' "$USERS_JSON")" || die 'rendered inputs did not contain user slugs.'
[[ -n "${user_slugs_text//[[:space:]]/}" ]] || die 'rendered inputs contained no user slugs.'
while IFS= read -r slug; do
  [[ -n "$slug" ]] || die 'rendered inputs contained an empty user slug.'
  run_stage "bootstrap user ${slug} recovery" recover_existing_user "$slug"
done <<<"$user_slugs_text"

run_plan_apply() {
  local label=$1
  local root=$2
  local inputs=$3
  local plan_file="${PLAN_DIR}/${label}.plan"
  rm -f -- "$plan_file"
  run_stage "${label} plan" terraform -chdir="${ROOT_DIR}/${root}" plan -input=false -out="$plan_file" -var-file="$inputs"
  chmod 600 "$plan_file"
  run_stage "${label} apply" terraform -chdir="${ROOT_DIR}/${root}" apply -input=false "$plan_file"
}

run_plan_apply bootstrap bootstrap "${INPUT_DIR}/bootstrap.json"
run_plan_apply shared roots/shared "${INPUT_DIR}/shared.json"
for slug in "${DEVELOPER_SLUGS[@]}"; do
  run_stage "developer workspace ${slug}" terraform -chdir="${ROOT_DIR}/roots/developer" workspace select -or-create "$slug"
  run_plan_apply "developer-${slug}" roots/developer "${INPUT_DIR}/${slug}.json"
done
run_plan_apply shared-reconcile roots/shared-reconcile "${INPUT_DIR}/shared-reconcile.json"

current_stage='report nonsecret outputs'
if jump_fip="$(terraform -chdir="${ROOT_DIR}/roots/shared" output -raw jump_fip)"; then
  :
else
  status=$?
  report_stage_failure "$status"
fi
printf '\nApply completed successfully.\n'
printf 'jump_fip=%s\n' "$jump_fip"
for output_name in shared_project_id; do
  if output_value="$(terraform -chdir="${ROOT_DIR}/roots/shared" output -json "$output_name")"; then
    printf '%s=%s\n' "$output_name" "$output_value"
  else
    status=$?
    report_stage_failure "$status"
  fi
done
for slug in "${DEVELOPER_SLUGS[@]}"; do
  if terraform -chdir="${ROOT_DIR}/roots/developer" workspace select "$slug" >/dev/null; then
    :
  else
    status=$?
    report_stage_failure "$status"
  fi
  if developer_lb_output="$(terraform -chdir="${ROOT_DIR}/roots/developer" output -json load_balancer)"; then
    printf 'developer_%s_load_balancer=%s\n' "$slug" "$developer_lb_output"
  else
    status=$?
    report_stage_failure "$status"
  fi
  printf 'developer_%s_ssh_private_key=%s\n' "$slug" "${KEY_DIR}/${slug}_ssh"
  printf 'developer_%s_ssh_proxyjump=ssh -o IdentitiesOnly=yes -i %s -J %s@%s %s@<private-app-or-db-ip>\n' \
    "$slug" "${KEY_DIR}/${slug}_ssh" "$slug" "$jump_fip" "$slug"
done
