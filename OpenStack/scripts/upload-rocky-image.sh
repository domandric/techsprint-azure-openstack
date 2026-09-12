#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

readonly IMAGE_URL='https://mirror.netcologne.de/rocky/8/images/x86_64/Rocky-8-GenericCloud-Base-8.10-20240528.0.x86_64.qcow2'
readonly IMAGE_FILE='Rocky-8-GenericCloud-Base-8.10-20240528.0.x86_64.qcow2'
readonly IMAGE_NAME='Rocky-8-GenericCloud-Base-8.10-20240528.0.x86_64'
readonly IMAGE_SHA256='e56066c58606191e96184de9a9183a3af33c59bcbd8740d8b10ca054a7a89c14'
readonly IMAGE_SIZE=2065760256
readonly ROCKY_IMAGE_ID='8b7e4d2a-6c91-4f38-a5e2-1d9c7b4a0e63'
readonly LOCK_FILE_NAME="upload-rocky-image-${IMAGE_NAME}.lock"
readonly CHECK_ABSENT_STATUS=3
readonly POLL_MAX_ATTEMPTS=120
readonly POLL_INTERVAL_SECONDS=5

cloud=''
region='regionOne'
mode=''
cloud_set=false
region_set=false
download_dir=''
artifact_path=''
artifact_sha512=''
created_id=''
lock_fd=''
lock_root=''
lock_path=''

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/upload-rocky-image.sh --check [--cloud ALIAS] [--region regionOne]
  ./scripts/upload-rocky-image.sh --upload [--cloud ALIAS] [--region regionOne]

--check is read-only.  It exits 3 when the exact image is absent; an existing
image must match every pinned attribute.  --upload reuses an exact match and
otherwise downloads, verifies, and uploads the pinned artifact.
USAGE
}

fail() {
  local message=$1 status=${2:-1}
  printf 'upload-rocky-image.sh: %s\n' "$message" >&2
  exit "$status"
}

cleanup() {
  if [[ -n $download_dir && -d $download_dir ]]; then
    rm -rf -- "$download_dir"
  fi
}
trap cleanup EXIT

parse_args() {
  local arg
  while (($#)); do
    arg=$1
    case $arg in
      --help)
        [[ $# == 1 && -z $mode ]] || fail '--help cannot be combined with other arguments' 2
        usage
        exit 0
        ;;
      --check|--upload)
        [[ -z $mode ]] || fail 'exactly one of --check or --upload is required' 2
        mode=${arg#--}
        ;;
      --cloud)
        [[ $cloud_set == false ]] || fail 'duplicate --cloud' 2
        (($# >= 2)) || fail '--cloud requires a non-empty ALIAS' 2
        shift
        [[ -n $1 && $1 != --* ]] || fail '--cloud requires a non-empty ALIAS' 2
        cloud=$1
        cloud_set=true
        ;;
      --region)
        [[ $region_set == false ]] || fail 'duplicate --region' 2
        (($# >= 2)) || fail '--region requires a non-empty region' 2
        shift
        [[ -n $1 && $1 != --* ]] || fail '--region requires a non-empty region' 2
        region=$1
        region_set=true
        ;;
      *)
        fail "unknown argument: $arg" 2
        ;;
    esac
    shift
  done
  [[ $region == regionOne ]] || fail '--region must be exactly regionOne' 2
  [[ -n $mode ]] || fail 'one of --check or --upload is required' 2
}

require_tools() {
  local tool
  for tool in jq openstack; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
  done
  if [[ $mode == upload ]]; then
    for tool in curl sha256sum sha512sum flock stat; do
      command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
    done
  fi
}

lock_directory_is_safe() {
  local path=$1 require_exact_mode=${2:-false} metadata owner mode type mode_value
  [[ -n $path && ! -L $path && -d $path ]] || return 1
  if ! metadata=$(stat -Lc '%u %a %F' -- "$path" 2>/dev/null); then
    return 1
  fi
  read -r owner mode type <<<"$metadata"
  [[ $owner == "$EUID" && $type == directory && $mode =~ ^[0-7]+$ ]] || return 1
  mode_value=$((8#$mode))
  (( (mode_value & 18) == 0 )) || return 1
  if [[ $require_exact_mode == true ]]; then
    [[ $mode == 700 ]] || return 1
  fi
}

lock_file_is_safe() {
  local path=$1 metadata owner mode file_type
  [[ ! -L $path && -f $path ]] || return 1
  if ! metadata=$(stat -Lc '%u %a %F' -- "$path" 2>/dev/null); then
    return 1
  fi
  read -r owner mode file_type <<<"$metadata"
  [[ $owner == "$EUID" && $mode == 600 &&
    ($file_type == 'regular file' || $file_type == 'regular empty file') ]]
}

select_lock_root() {
  local runtime_dir=${XDG_RUNTIME_DIR:-}
  local fallback_dir="/tmp/upload-rocky-image-${EUID}"

  if [[ -n $runtime_dir ]] && lock_directory_is_safe "$runtime_dir" false; then
    lock_root=$runtime_dir
  else
    if [[ -L $fallback_dir ]]; then
      fail "refusing unsafe local lock directory: $fallback_dir"
    fi
    if [[ ! -e $fallback_dir ]]; then
      if ! (umask 077; mkdir -- "$fallback_dir") 2>/dev/null; then
        [[ -e $fallback_dir ]] || fail 'could not create the local lock directory'
      fi
    fi
    lock_directory_is_safe "$fallback_dir" true ||
      fail "refusing unsafe local lock directory: $fallback_dir"
    lock_root=$fallback_dir
  fi
  lock_path=$lock_root/$LOCK_FILE_NAME
}

acquire_upload_lock() {
  local before after before_identity after_identity
  select_lock_root
  if [[ -L $lock_path ]]; then
    fail "refusing symlink local upload lock: $lock_path"
  fi
  if [[ ! -e $lock_path ]]; then
    if ! (set -o noclobber; : >"$lock_path") 2>/dev/null; then
      [[ -e $lock_path ]] || fail 'could not create the local upload lock'
    fi
  fi
  lock_file_is_safe "$lock_path" ||
    fail "refusing unsafe local upload lock: $lock_path"
  before=$(stat -Lc '%d:%i' -- "$lock_path") || fail 'could not inspect the local upload lock'
  before_identity=$before
  if ! exec {lock_fd}<>"$lock_path"; then
    fail 'could not open the local upload lock'
  fi
  after=$(stat -Lc '%d:%i' -- "/proc/$$/fd/$lock_fd") ||
    fail 'could not inspect the opened local upload lock'
  after_identity=$after
  [[ $before_identity == "$after_identity" ]] ||
    fail 'local upload lock changed while it was being opened'
  lock_file_is_safe "$lock_path" ||
    fail "refusing unsafe local upload lock: $lock_path"
  flock "$lock_fd" || fail 'could not acquire the local upload lock'
}

openstack_args() {
  OPENSTACK=(openstack)
  if [[ -n $cloud ]]; then
    OPENSTACK+=(--os-cloud "$cloud")
  fi
  OPENSTACK+=(--os-region-name "$region")
}

list_matching_image() {
  local listing count post_create=${1:-false}
  if ! listing=$("${OPENSTACK[@]}" image list --name "$IMAGE_NAME" -f json); then
    if [[ $post_create == true ]]; then
      post_create_failure 'final exact-name lookup failed'
    fi
    fail 'could not list Glance images'
  fi
  if ! count=$(jq -er --arg name "$IMAGE_NAME" '
    if type != "array" then error("image list is not an array")
    else [.[] | select((.Name // .name // null) == $name)] | length
    end
  ' <<<"$listing"); then
    if [[ $post_create == true ]]; then
      post_create_failure 'final exact-name lookup returned malformed JSON'
    fi
    fail 'OpenStack returned malformed image-list JSON'
  fi
  case $count in
    0)
      if [[ $post_create == true ]]; then
        post_create_failure 'final exact-name lookup found no matching image'
      fi
      return "$CHECK_ABSENT_STATUS"
      ;;
    1)
      if ! MATCH_ID=$(jq -er --arg name "$IMAGE_NAME" '
        [.[] | select((.Name // .name // null) == $name) |
          (.ID // .id // null)] |
        if length != 1 or .[0] == null or (.[0] | type) != "string" or .[0] == ""
         then error("matching image has no valid ID") else .[0] end
       ' <<<"$listing"); then
        if [[ $post_create == true ]]; then
          post_create_failure 'final exact-name lookup had no valid image ID'
        fi
        fail 'matching image-list entry has no valid ID'
      fi
      ;;
    *)
      if [[ $post_create == true ]]; then
        post_create_failure "final exact-name lookup found $count matching images"
      fi
      fail "refusing duplicate exact image name ($count matches)"
      ;;
  esac
}

image_matches_contract() {
  local image_json=$1 expected_id=$2 expected_sha512=${3:-}
  jq -e --arg id "$expected_id" --arg name "$IMAGE_NAME" --arg sha512 "$expected_sha512" --argjson size "$IMAGE_SIZE" '
    type == "object" and
    (.id | type) == "string" and .id == $id and
    (.name | type) == "string" and .name == $name and
    .status == "active" and
    .disk_format == "qcow2" and
    .container_format == "bare" and
    .visibility == "public" and
    (.size | type) == "number" and .size == $size and
    (.size | floor) == .size and
    (.properties | type) == "object" and
    .properties.architecture == "x86_64" and
    .properties.os_distro == "rocky" and
    .properties.os_version == "8" and
    .properties.os_hash_algo == "sha512" and
    (.properties.os_hash_value | type) == "string" and
    (.properties.os_hash_value | test("^[0-9a-f]{128}$")) and
    ($sha512 == "" or .properties.os_hash_value == $sha512)
  ' <<<"$image_json" >/dev/null
}

show_and_validate_image() {
  local id=$1 image_json
  if ! image_json=$("${OPENSTACK[@]}" image show "$id" -f json); then
    fail "could not inspect image ID $id"
  fi
  image_matches_contract "$image_json" "$id" ||
    fail "image ID $id does not exactly match the pinned Rocky contract"
  printf 'Image ID: %s\nImage name: %s\n' "$id" "$IMAGE_NAME"
}

find_and_validate_existing() {
  if list_matching_image; then
    show_and_validate_image "$MATCH_ID"
  else
    local result=$?
    case $result in
      "$CHECK_ABSENT_STATUS") return "$CHECK_ABSENT_STATUS" ;;
      *) return 1 ;;
    esac
  fi
}

download_and_verify() {
  local checksum actual
  download_dir=$(mktemp -d /tmp/upload-rocky-image.XXXXXX) || fail 'could not create secure temporary directory'
  artifact_path=$download_dir/$IMAGE_FILE
  if ! curl --fail --location --retry 5 --retry-delay 2 \
    --output "$artifact_path" "$IMAGE_URL"; then
    fail 'Rocky artifact download failed'
  fi
  [[ -f $artifact_path ]] || fail 'download did not produce a regular artifact file'
  if ! checksum=$(sha256sum -- "$artifact_path"); then
    fail 'could not calculate artifact SHA256'
  fi
  actual=${checksum%%[[:space:]]*}
  [[ $actual == "$IMAGE_SHA256" ]] || fail 'artifact SHA256 does not match the pinned checksum'
  if ! checksum=$(sha512sum -- "$artifact_path"); then
    fail 'could not calculate artifact SHA512'
  fi
  artifact_sha512=${checksum%%[[:space:]]*}
  [[ $artifact_sha512 =~ ^[0-9a-f]{128}$ ]] || fail 'artifact SHA512 is not a lowercase 128-hex digest'
}

create_image() {
  local create_json
  if ! create_json=$("${OPENSTACK[@]}" image create "$IMAGE_NAME" \
    --id "$ROCKY_IMAGE_ID" \
    --file "$artifact_path" \
    --disk-format qcow2 \
    --container-format bare \
    --public \
    --property os_distro=rocky \
    --property os_version=8 \
    --property architecture=x86_64 \
    --property os_hash_algo=sha512 \
    --property os_hash_value="$artifact_sha512" \
    -f json); then
    return 1
  fi
  if ! created_id=$(jq -er --arg expected "$ROCKY_IMAGE_ID" '
    if type == "object" and (.id | type) == "string" and .id == $expected
    then .id else error("image create returned an unexpected ID") end
  ' <<<"$create_json"); then
    fail 'Glance image create returned malformed JSON without a usable ID'
  fi
}

post_create_failure() {
  fail "created image ID $created_id; post-create verification failed: $1"
}

poll_until_active() {
  local attempt image_json status
  for ((attempt = 1; attempt <= POLL_MAX_ATTEMPTS; attempt++)); do
    if ! image_json=$("${OPENSTACK[@]}" image show "$created_id" -f json); then
      post_create_failure 'image could not be inspected'
    fi
    if ! status=$(jq -er --arg id "$created_id" '
      if type != "object" or (.id | type) != "string" or .id != $id or
         (.status | type) != "string"
      then error("malformed image response") else .status end
    ' <<<"$image_json"); then
      post_create_failure 'malformed image response'
    fi
    case $status in
      active) return 0 ;;
      killed|deactivated|deleted|error)
        post_create_failure "terminal image status: $status"
        ;;
      queued|saving|pending|uploading|building|processing)
        ;;
      *) post_create_failure "malformed or unexpected image status: $status" ;;
    esac
    if ((attempt == POLL_MAX_ATTEMPTS)); then
      post_create_failure "timed out waiting for active status after $POLL_MAX_ATTEMPTS attempts"
    fi
    sleep "$POLL_INTERVAL_SECONDS"
  done
}

upload_image() {
  download_and_verify
  if find_and_validate_existing; then
    return 0
  else
    local result=$?
    case $result in
      "$CHECK_ABSENT_STATUS") ;;
      *) return 1 ;;
    esac
  fi
  if ! create_image; then
    if find_and_validate_existing; then
      return 0
    fi
    fail 'Glance image create failed; no single exact matching image was found after the conflict'
  fi
  poll_until_active
  if ! image_json=$("${OPENSTACK[@]}" image show "$created_id" -f json); then
    post_create_failure 'final image inspection failed'
  fi
  image_matches_contract "$image_json" "$created_id" "$artifact_sha512" ||
    post_create_failure 'final image attributes, size, checksum, or properties do not match'
  list_matching_image true
  [[ $MATCH_ID == "$created_id" ]] ||
    post_create_failure "final exact-name lookup returned ID $MATCH_ID instead of the created ID"
  printf 'Image ID: %s\nImage name: %s\n' "$created_id" "$IMAGE_NAME"
}

main() {
  local result
  parse_args "$@"
  require_tools
  openstack_args
  if [[ $mode == upload ]]; then
    acquire_upload_lock
  fi
  if find_and_validate_existing; then
    return 0
  else
    result=$?
    case $result in
      "$CHECK_ABSENT_STATUS")
        if [[ $mode == check ]]; then
          fail 'exact Rocky image is absent (read-only check)' "$CHECK_ABSENT_STATUS"
        fi
        ;;
      *) return 1 ;;
    esac
  fi
  [[ $mode == upload ]] || return 1
  upload_image
}

main "$@"
