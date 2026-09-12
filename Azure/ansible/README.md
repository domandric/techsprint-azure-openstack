# Ansible configuration

The tracked Ansible layout is environment-oriented:

```text
ansible/
├── ansible.cfg
├── .vault-password                         # generated, mode 0600, gitignored
├── vault.example.yml                       # tracked shape only; outside auto-loaded group_vars
├── inventories/production/
│   ├── group_vars/
│   │   ├── all/
│   │   │   ├── main.yml                    # tracked, non-secret
│   │   │   └── vault.yml                   # generated, encrypted, mode 0600, gitignored
│   │   └── app/main.yml                    # tracked, non-secret
│   └── hosts.yml                           # generated, mode 0600, gitignored
├── playbooks/deploy_moodle.yml
└── roles/
```

Terraform roots first write independent, non-secret staging fragments under
`../runtime/ansible/inventory/`: `00-shared.yml` for Jump/Lead/Application
Gateway data and one `20-<tenant>.yml` per tenant. Separate state roots must not
write the same file because they can be applied independently. After shared
reconciliation, `scripts/Deploy-Azure.ps1` merges those fragments with
`ansible-inventory --export` into `inventories/production/hosts.yml`. Never
hand-edit or commit generated inventory, vault, password, or key files.

The normal CSV deployment now performs the whole sequence itself. From the
repository root, the preferred route remains:

```powershell
cd Azure && pwsh -File ./deploy.ps1 -UsersCsv ../config/users.csv
```

After Terraform reconciliation it exports `hosts.yml`, creates the encrypted
vault if one does not already exist, and runs the fixed Moodle playbook. The
lead private key is resolved from `keys/<lead-slug>`; there are no Ansible mode
or path flags. The one-shot command also manages its isolated SSH agent
automatically. SSH host-key verification is disabled for this lab convenience
(`StrictHostKeyChecking=no`, `UserKnownHostsFile=/dev/null`): there is no
`known_hosts` file to populate or manage, and no first-run trust step.

The exporter holds plaintext only in process memory and pipes it directly to
`ansible-vault`; it never writes or prints plaintext secrets. The
CSPRNG-generated `.vault-password` is reused. If `vault.yml` exists but the
password file is missing, deployment fails closed; restore the password from a
secure backup. To intentionally refresh an existing vault, use the standalone
advanced command:

```powershell
pwsh -File ./scripts/Export-AnsibleSecrets.ps1 -UsersCsv ./config/users.csv -Force
```

For a deliberate configuration-only rerun from Linux Bash, use this single
block from the repository root. It starts a new, isolated `ssh-agent` and never
touches a pre-existing user agent. `ansible.cfg` supplies the generated
inventory and vault paths:

```bash
(
  set -euo pipefail
  cd Azure/ansible
  KEY="../keys/<LEAD_SLUG>"
  test -f "$KEY"
  chmod 600 "$KEY"
  test -r "$KEY"

  eval "$(ssh-agent -s)"
  trap 'ssh-agent -k >/dev/null 2>&1' EXIT
  ssh-add "$KEY" >/dev/null

  # Optional path check; do not print inventory or vault contents.
  ansible lead -m ping --private-key "$KEY" \
    --ssh-common-args '-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'

  # First configuration run; inspect only its PLAY RECAP.
  ansible-playbook playbooks/deploy_moodle.yml \
    --private-key "$KEY" \
    --ssh-common-args '-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'

  # Second identical run, for the idempotence check.
  ansible-playbook playbooks/deploy_moodle.yml \
    --private-key "$KEY" \
    --ssh-common-args '-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'

  ssh-agent -k >/dev/null 2>&1
  trap - EXIT
)
```

`ansible.cfg` loads `.vault-password`, and inventory loading decrypts
`group_vars/all/vault.yml` automatically. No plaintext secrets file or
`--extra-vars` argument is used. The old plaintext `ansible/moodle-secrets.yml` workflow
is obsolete; delete any local remnant and do not use it.

The generated private-host ProxyCommand starts a nested `ssh ... -W` to the
Jump host. `--private-key` applies to the destination SSH command but does not
reliably provide the key to that nested SSH process, so the dedicated agent is
required. Therefore, `Connection closed by UNKNOWN port 65535` in this path
means nested ProxyCommand/Jump authentication failed; it does not mean TCP
port 65535 or deletion of the Lead VM. Only `PLAY RECAP` should be recorded;
never print the inventory, vault, state, plan, public IP, or key contents.

[`vault.example.yml`](vault.example.yml)
documents the required `moodle_secrets` shape. Five keys come from each tenant
Terraform root's sensitive `runtime_secrets`; the exporter adds the Moodle admin
values. The role asserts all eight keys with `no_log: true` on every app host.

There is no Redis anywhere in this deployment: `$CFG->dataroot` is the Azure
Files NFS share mounted on both `app01` and `app02` (see
`ansible/roles/azure_storage`), so Moodle's own default file-based session and
cache stores are already correctly shared between both instances without an
extra paid service -- see `docs/architecture/README.md` for the full
rationale. The primary automated-backup destination is the Azure Files mount,
matching the brief's file-storage wording. A timer on `app01` replicates those
Moodle-generated backup files to the BlobFuse2 mount, so object storage is also
genuinely used without treating it as a safe shared POSIX dataroot.

### Moodle database bootstrap

`config.php` is rendered from `moodle_secrets` *before* any installer runs, so
the role uses `admin/cli/install_database.php`, Moodle's "config.php already
exists" installer, instead of `admin/cli/install.php` (which expects to
generate `config.php` itself and refuses to run once it is already present).
`install_database.php` creates the schema and the site-admin account inside
the database named in that existing `config.php`, and runs only on `app01` so
`app02` never races the same schema creation.

`config.php.j2` follows Moodle's own `config-dist.php` boilerplate exactly:
`unset($CFG); global $CFG; $CFG = new stdClass();` before the first
`$CFG->...` assignment, and a trailing `require_once(__DIR__ .
'/lib/setup.php');` after the last one. Skipping the `stdClass` initialization
is a runtime-only bug that neither Jinja2 rendering nor
`ansible-playbook --syntax-check` can catch: PHP 8 turned "write to a
property of a non-object" into an uncaught `Error` (it was only a Warning
in PHP 7), so the very first `$CFG->wwwroot = ...` line becomes fatal without
it.

Idempotence has two layers, both gated on `app01`:

1. A `.moodle-installed` marker file under the shared `moodledata` mount
   (checked with `ansible.builtin.stat`, and also used as the command
   module's own `creates:`). If it already exists, nothing below runs again.
2. If the marker is missing, a read-only `SHOW TABLES LIKE 'mdl_config'`
   probe against the tenant database decides whether `install_database.php`
   actually needs to run. This makes losing the marker (for example an
   interrupted run between a successful install and the marker being
   written) a safe, idempotent no-op recovery instead of a hard failure:
   `install_database.php` errors out if pointed at a database that already
   has Moodle's tables, so the role must never call it again once they
   exist. The marker is written only after the install task actually
   succeeds, or -- on that recovery path -- only after the probe confirms
   the schema is already there; a failed install never reaches the
   marker-write task because Ansible halts the play on the first failed
   task.

Azure Files is mounted as native private-endpoint NFSv4.1 (`AUTH_SYS`) over
TCP/2049. It has no SMB, CIFS, Kerberos, storage-key, SAS, or identity-token
fallback.

For a syntax-only check against the generated directory:

```bash
mkdir -p /tmp/azure-ansible/local
ANSIBLE_LOCAL_TEMP=/tmp/azure-ansible/local ansible-playbook playbooks/deploy_moodle.yml --syntax-check
```
