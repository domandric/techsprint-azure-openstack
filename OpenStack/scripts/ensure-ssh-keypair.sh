#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" -eq 1 ]] || die 'usage: ensure-ssh-keypair.sh PRIVATE_KEY_PATH'

private_key=$1
public_key="${private_key}.pub"
key_dir=$(dirname -- "$private_key")

[[ -L "$key_dir" ]] && die "SSH key directory must not be a symbolic link: $key_dir"
if [[ -e "$key_dir" && ! -d "$key_dir" ]]; then
  die "SSH key directory must be a directory: $key_dir"
fi
mkdir -p -- "$key_dir"
[[ -d "$key_dir" && ! -L "$key_dir" ]] || die "SSH key directory is not a non-symbolic-link directory: $key_dir"
chmod 700 -- "$key_dir"

for path in "$private_key" "$public_key"; do
  [[ ! -L "$path" ]] || die "SSH key path must not be a symbolic link: $path"
done

private_exists=false
public_exists=false
[[ -e "$private_key" ]] && private_exists=true
[[ -e "$public_key" ]] && public_exists=true

if [[ "$private_exists" == false && "$public_exists" == false ]]; then
  ssh-keygen -q -t rsa -b 3072 -N '' -f "$private_key" >/dev/null
elif [[ "$private_exists" != "$public_exists" ]]; then
  die "SSH key pair is incomplete; both keys must be present or both absent: $private_key"
fi

[[ -f "$private_key" ]] || die "SSH private key must be a regular file: $private_key"
[[ -f "$public_key" ]] || die "SSH public key must be a regular file: $public_key"
chmod 600 -- "$private_key"
chmod 644 -- "$public_key"

derived_public=$(ssh-keygen -y -f "$private_key" 2>/dev/null) || die "could not read the SSH private key: $private_key"
stored_public=$(<"$public_key")
[[ "$stored_public" != *$'\r'* ]] || die "SSH public key contains a carriage return: $public_key"
if [[ "$stored_public" == *$'\n' ]]; then
  stored_public=${stored_public%$'\n'}
fi
[[ "$stored_public" != *$'\n'* && -n "$stored_public" ]] || die "SSH public key must be one nonempty line: $public_key"

stored_core=$(awk 'NF >= 2 { print $1 " " $2 }' <<<"$stored_public")
derived_core=$(awk 'NF >= 2 { print $1 " " $2 }' <<<"$derived_public")
[[ -n "$stored_core" && "$stored_core" == "$derived_core" ]] || die "SSH public and private keys do not match: $private_key"

printf '%s\n' "$stored_public"
