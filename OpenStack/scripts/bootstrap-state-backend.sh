#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
RUNTIME_DIR="${ROOT_DIR}/runtime"
BACKEND_DIR="${RUNTIME_DIR}/terraform-backend"
STATE_ENV_FILE="${RUNTIME_DIR}/terraform-state.env"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_command openstack
require_command jq
require_command stat

[[ -n "${OS_AUTH_URL:-}" ]] || die "source an administrator OpenRC first (OS_AUTH_URL is unset)."
[[ -n "${OS_PROJECT_ID:-${OS_PROJECT_NAME:-}}" ]] || die "source an administrator OpenRC first (OS_PROJECT_ID or OS_PROJECT_NAME is unset)."
if [[ -z "${OS_USERNAME:-}" && -z "${OS_USER_ID:-}" && -z "${OS_APPLICATION_CREDENTIAL_ID:-}" && -z "${OS_TOKEN:-}" ]]; then
  die "source an administrator OpenRC first (no Keystone identity credential is present)."
fi

state_project_ref="${OS_PROJECT_ID:-${OS_PROJECT_NAME:-}}"
explicit_access_key="${TF_STATE_ACCESS_KEY_ID:-${TF_STATE_AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}}"
explicit_secret_key="${TF_STATE_SECRET_ACCESS_KEY:-${TF_STATE_AWS_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}}"
explicit_endpoint="${TF_STATE_S3_ENDPOINT:-}"
explicit_state_container="${TF_STATE_CONTAINER:-}"
explicit_openstack_region="${TF_STATE_OPENSTACK_REGION:-}"
explicit_os_region_name="${OS_REGION_NAME:-}"
explicit_s3_region="${TF_STATE_S3_REGION:-}"
explicit_allow_backend_change="${TF_STATE_ALLOW_BACKEND_CHANGE:-}"

mkdir -p "$BACKEND_DIR"

# The persisted file contains only this script's assignments and is sourced so
# reruns reuse the project credential and endpoint. Do not source a writable
# credentials file.
if [[ -f "$STATE_ENV_FILE" ]]; then
  [[ ! -L "$STATE_ENV_FILE" ]] || die "refusing to source symlinked state environment file ${STATE_ENV_FILE@Q}."
  [[ "$(stat -c '%a' -- "$STATE_ENV_FILE")" == 600 ]] || die "state environment file ${STATE_ENV_FILE@Q} must have mode 0600."
  # Ignore inherited backend settings; retain AWS credentials for reuse below.
  unset AWS_ENDPOINT_URL_S3 TF_VAR_state_s3_endpoint TF_VAR_state_bucket TF_VAR_state_region
  # shellcheck disable=SC1090
  source "$STATE_ENV_FILE"
  persisted_container="${TF_VAR_state_bucket:-}"
  persisted_s3_region="${TF_VAR_state_region:-}"
  persisted_endpoint="${AWS_ENDPOINT_URL_S3:-${TF_VAR_state_s3_endpoint:-}}"
else
  persisted_container=""
  persisted_s3_region=""
  persisted_endpoint=""
fi

if [[ -n "$explicit_state_container" && -n "$persisted_container" && "$explicit_state_container" != "$persisted_container" && "$explicit_allow_backend_change" != true ]]; then
  die "explicit TF_STATE_CONTAINER ${explicit_state_container@Q} differs from persisted backend container ${persisted_container@Q}; refusing to switch state backend. Set TF_STATE_ALLOW_BACKEND_CHANGE=true only for a deliberate migration."
fi

# Migrate the known legacy catalog-region value to the S3 signing default.
legacy_s3_region_migration=false
if [[ "$persisted_s3_region" == regionOne && ( -z "$explicit_s3_region" || "$explicit_s3_region" == us-east-1 ) ]]; then
  legacy_s3_region_migration=true
  printf 'Migrating persisted S3 signing region from regionOne to us-east-1.\n' >&2
fi

if [[ -n "$explicit_s3_region" && -n "$persisted_s3_region" && "$explicit_s3_region" != "$persisted_s3_region" && "$legacy_s3_region_migration" != true && "$explicit_allow_backend_change" != true ]]; then
  die "explicit TF_STATE_S3_REGION ${explicit_s3_region@Q} differs from persisted backend signing region ${persisted_s3_region@Q}; refusing to switch state backend. Set TF_STATE_ALLOW_BACKEND_CHANGE=true only for a deliberate migration."
fi
if [[ -n "$explicit_endpoint" && -n "$persisted_endpoint" && "$explicit_endpoint" != "$persisted_endpoint" && "$explicit_allow_backend_change" != true ]]; then
  die "explicit TF_STATE_S3_ENDPOINT ${explicit_endpoint@Q} differs from persisted backend endpoint ${persisted_endpoint@Q}; refusing to switch state backend. Set TF_STATE_ALLOW_BACKEND_CHANGE=true only for a deliberate migration."
fi

if [[ -n "$explicit_state_container" ]]; then
  state_container="$explicit_state_container"
elif [[ -n "$persisted_container" ]]; then
  state_container="$persisted_container"
else
  state_container='iruo-terraform-state'
fi

# This is the catalog lookup region, not the S3 signing region.
openstack_region="${explicit_openstack_region:-${explicit_os_region_name:-regionOne}}"
if [[ "$legacy_s3_region_migration" == true ]]; then
  s3_region='us-east-1'
elif [[ -n "$explicit_s3_region" ]]; then
  s3_region="$explicit_s3_region"
elif [[ -n "$persisted_s3_region" ]]; then
  s3_region="$persisted_s3_region"
else
  s3_region='us-east-1'
fi

[[ "$state_container" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$ ]] || die "selected state container ${state_container@Q} is not a valid Swift container name."
[[ "$openstack_region" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die "selected TF_STATE_OPENSTACK_REGION ${openstack_region@Q} is not a valid region label."
[[ "$s3_region" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die "selected TF_STATE_S3_REGION ${s3_region@Q} is not a valid region label."

discover_swift_endpoint() {
  local endpoint_json unique_endpoints endpoint_count

  endpoint_json="$(openstack endpoint list --service object-store --interface public --region "$openstack_region" -f json -c URL)" \
    || die "could not list public object-store endpoints in region ${openstack_region@Q}."
  unique_endpoints="$(jq -c '
    if type != "array" then
      error("expected endpoint list JSON array")
    else
      map(
        select(type == "object")
        | .URL?
        | select(type == "string")
        | gsub("^[[:space:]]+"; "")
        | gsub("[[:space:]]+$"; "")
        | select(length > 0)
      )
      | unique
    end
  ' <<<"$endpoint_json")" || die "could not parse the public object-store endpoint list for region ${openstack_region@Q}."
  endpoint_count="$(jq -r 'length' <<<"$unique_endpoints")"

  case "$endpoint_count" in
    0)
      die "no nonempty public object-store endpoint was found in region ${openstack_region@Q}; set TF_STATE_S3_ENDPOINT for an explicit override."
      ;;
    1)
      jq -r '.[0]' <<<"$unique_endpoints"
      ;;
    *)
      die "ambiguous public object-store endpoints in region ${openstack_region@Q}: found ${endpoint_count} unique nonempty URLs; set TF_STATE_S3_ENDPOINT for an explicit override."
      ;;
  esac
}

derive_s3_endpoint() {
  local swift_endpoint="$1"
  local swift_endpoint_pattern="^https?://[^/[:space:]\"'?#]+(/[^[:space:]\"'?#]*)*/v1(/[^[:space:]\"'?#]*)?$"

  [[ "$swift_endpoint" =~ $swift_endpoint_pattern ]] || die "public object-store endpoint ${swift_endpoint@Q} must be an HTTP(S) URL ending in /v1 or /v1/...; it was not rewritten."
  # Remove /v1 and its suffix while retaining any valid path prefix.
  printf '%s\n' "${swift_endpoint%%/v1*}"
}

if [[ -n "$explicit_endpoint" ]]; then
  state_s3_endpoint="$explicit_endpoint"
elif [[ -n "$persisted_endpoint" ]]; then
  state_s3_endpoint="$persisted_endpoint"
else
  swift_endpoint="$(discover_swift_endpoint)"
  state_s3_endpoint="$(derive_s3_endpoint "$swift_endpoint")"
  printf 'Swift object-store endpoint: %s\n' "$swift_endpoint"
  printf 'Derived S3 endpoint: %s\n' "$state_s3_endpoint"
fi

[[ -n "$state_s3_endpoint" ]] || die "the selected S3 endpoint is empty; set TF_STATE_S3_ENDPOINT for an explicit override."
[[ "$state_s3_endpoint" =~ ^https?://[^[:space:]\"\']+$ ]] || die "the selected S3 endpoint must be an HTTP(S) URL without whitespace."

# Check the endpoint before the container: without S3 access, the container
# cannot be a usable Terraform backend.
if ! openstack container show "$state_container" -f json >/dev/null 2>&1; then
  openstack container create "$state_container" >/dev/null || die "could not create Swift state container ${state_container}."
fi
openstack container show "$state_container" -f json >/dev/null || die "Swift state container ${state_container} could not be shown after create/reuse."

access_key="$explicit_access_key"
secret_key="$explicit_secret_key"
if [[ -z "$access_key" ]]; then
  access_key="${AWS_ACCESS_KEY_ID:-}"
  secret_key="${AWS_SECRET_ACCESS_KEY:-}"
fi

if [[ -n "$access_key" && -z "$secret_key" ]]; then
  credential_json="$(openstack ec2 credentials show "$access_key" -f json)" || die "the explicitly supplied EC2 access key could not be shown; refusing to create a replacement credential."
  secret_key="$(jq -er '(.secret // .Secret // .["Secret Key"] // empty) | select(type == "string" and length > 0)' <<<"$credential_json")" || die "the explicitly supplied EC2 credential did not return a secret."
fi

if [[ -z "$access_key" || -z "$secret_key" ]]; then
  credential_json="$(openstack ec2 credentials create --project "$state_project_ref" -f json)" || die "could not create a project EC2 credential."
  access_key="$(jq -er '(.access // .Access // .["Access Key"] // .["Access Key ID"] // empty) | select(type == "string" and length > 0)' <<<"$credential_json")" || die "EC2 credential creation did not return an access key."
  secret_key="$(jq -er '(.secret // .Secret // .["Secret Key"] // empty) | select(type == "string" and length > 0)' <<<"$credential_json")" || die "EC2 credential creation did not return a secret."
fi

write_file() {
  local target="$1"
  shift
  local temporary
  temporary="$(mktemp "${target}.XXXXXX")"
  chmod 600 "$temporary"
  printf '%s\n' "$@" >"$temporary"
  mv -f -- "$temporary" "$target"
}

hcl_common=(
  "bucket = \"${state_container}\""
  "region = \"${s3_region}\""
  "endpoints = { s3 = \"${state_s3_endpoint}\" }"
  "use_path_style = true"
  "skip_credentials_validation = true"
  "skip_region_validation = true"
  "skip_requesting_account_id = true"
  "skip_metadata_api_check = true"
  "skip_s3_checksum = true"
)

write_file "$STATE_ENV_FILE" \
  "export AWS_ACCESS_KEY_ID=$(printf '%q' "$access_key")" \
  "export AWS_SECRET_ACCESS_KEY=$(printf '%q' "$secret_key")" \
  "export AWS_REGION=$(printf '%q' "$s3_region")" \
  "export AWS_DEFAULT_REGION=$(printf '%q' "$s3_region")" \
  'export AWS_EC2_METADATA_DISABLED=true' \
  "export AWS_ENDPOINT_URL_S3=$(printf '%q' "$state_s3_endpoint")" \
  "export TF_VAR_state_bucket=$(printf '%q' "$state_container")" \
  "export TF_VAR_state_s3_endpoint=$(printf '%q' "$state_s3_endpoint")" \
  "export TF_VAR_state_region=$(printf '%q' "$s3_region")"

write_file "$BACKEND_DIR/bootstrap.hcl" "${hcl_common[@]}" 'key = "bootstrap.tfstate"'
write_file "$BACKEND_DIR/shared.hcl" "${hcl_common[@]}" 'key = "shared.tfstate"'
write_file "$BACKEND_DIR/developer.hcl" "${hcl_common[@]}" 'key = "developer.tfstate"' 'workspace_key_prefix = "developer"'
write_file "$BACKEND_DIR/shared-reconcile.hcl" "${hcl_common[@]}" 'key = "shared-reconcile.tfstate"'

printf 'State container is ready: %s\n' "$state_container"
printf 'S3 endpoint is configured for the Terraform backend.\n'
printf 'Credentials and backend files were written with mode 0600 under %s.\n' "$RUNTIME_DIR"
printf '\nRun these exact backend initializations next (do not run them concurrently on the same state object):\n'
printf 'terraform -chdir=%q init -reconfigure -backend-config=%q\n' "$ROOT_DIR/bootstrap" "$BACKEND_DIR/bootstrap.hcl"
printf 'terraform -chdir=%q init -reconfigure -backend-config=%q\n' "$ROOT_DIR/roots/shared" "$BACKEND_DIR/shared.hcl"
printf 'terraform -chdir=%q init -reconfigure -backend-config=%q\n' "$ROOT_DIR/roots/developer" "$BACKEND_DIR/developer.hcl"
printf 'terraform -chdir=%q init -reconfigure -backend-config=%q\n' "$ROOT_DIR/roots/shared-reconcile" "$BACKEND_DIR/shared-reconcile.hcl"
printf '\nSource %q before Terraform commands.\n' "$STATE_ENV_FILE"
printf 'Use a developer workspace exactly equal to its slug; its state object is developer/<slug>/developer.tfstate.\n'
printf 'Swift S3 lockfile/conditional semantics are not claimed or assumed. Prohibit concurrent operations on the same state object; distinct developer workspaces may run in parallel.\n'
