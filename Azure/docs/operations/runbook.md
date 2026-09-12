# Azure operations runbook

PowerShell creates Terraform state, Terraform plans/applies the shared
foundation and each developer environment, Ansible configures the Rocky
Linux hosts from Terraform-generated inventory. No Python layer.

## Before you start

- Install PowerShell 7.4+, `ssh-keygen`, Terraform 1.8+, Ansible, and the
  `Az.Accounts`/`Az.Resources`/`Az.Storage`/`Az.Compute`/`Az.Network`
  modules.
- Sign in with `Connect-AzAccount` and, if your account can see more than
  one subscription, `Select-AzSubscription -SubscriptionId <id>` to pick the
  intended one -- outside this repository. Nothing here signs in, selects a
  subscription on your behalf, or registers providers/features.
- The signed-in principal needs enough Microsoft Entra permission to read
  its own object ID, read the tenant's domains, look up/create the CSV's
  users (typically the **User Administrator** directory role), and enough
  Azure RBAC to create the state resource group/storage account and the
  shared/tenant resources (typically **Owner** or **Contributor +
  User Access Administrator** on the subscription).

## One command from Bash: `cd Azure && pwsh -File ./deploy.ps1 -UsersCsv ../config/users.csv`

From a Bash shell at the repository root, use the following exact entry point:

```bash
cd Azure && pwsh -File ./deploy.ps1 -UsersCsv ../config/users.csv
```

When already inside an interactive PowerShell session in `Azure/`, the
PowerShell-in-PowerShell equivalent is `& ./deploy.ps1 -UsersCsv
../config/users.csv`. The `.ps1` file is not a Bash executable; do not invoke
it directly from Bash.

This is the normal command. Every Azure-identifying value is derived
read-only from your already-signed-in session by
`scripts/Resolve-AzureContext.ps1` -- you do not supply `-SubscriptionId`,
`-TenantId`, `-UpnDomain`, `-StateAdministratorObjectId`, `-NameSeed`, or
`-RockyImageVersion`:

| Value | Derived from |
| --- | --- |
| Subscription/tenant | The active `Get-AzContext` (fails with one clear `Connect-AzAccount` instruction if there is no active session; never guesses among subscriptions or switches context for you) |
| State administrator object ID | `Get-AzADUser -SignedIn` (you) |
| UPN domain | `Get-AzTenant`, preferring the tenant's initial `*.onmicrosoft.com` domain |
| `NameSeed` | Deterministic, non-secret hash of the resolved subscription+tenant, persisted (not secret) as a context-bound JSON record at the ignored `runtime/state/name-seed.json` (`{subscription_id, tenant_id, name_seed}`) so reruns in the *same* subscription+tenant reuse the exact same value. A rerun in a *different* subscription/tenant fails closed instead of silently reusing the wrong context's seed; a pre-existing bare `runtime/state/name-seed.txt` from an older version of this command is migrated automatically only if its value already matches this context's own deterministic derivation, and fails clearly otherwise |
| Region / naming suffix / VM SKU | Auto-resolved by `scripts/Resolve-AzureDeploymentProfile.ps1` from a conservative ordered candidate region set (`westeurope`, then `swedencentral`), using the active subscription's own real SKU restrictions/capabilities and best-effort policy-assignment checks -- see `docs/architecture/README.md`'s "Regional adaptation". Persisted the same way as `NameSeed`, at `runtime/state/deployment-profile.json`, so reruns (including `-DestroyAll`) reuse exactly the same region/SKU |
| Rocky Linux 10 image version | The newest version `Get-AzVMImage` reports for the frozen publisher/offer/SKU in the *resolved* `-Location`; this command never accepts Marketplace terms automatically here -- if the image version is unavailable it fails clearly instead. Separately, immediately before the shared foundation is applied, this command *can* accept the image's Marketplace terms, but only via one explicit, separate, informed action -- see below |

Identity, naming, and image-version values can still be supplied explicitly
for automation or recovery. Region, location suffix, and VM SKU are not
one-shot parameters; the quota-aware deployment-profile resolver owns those
choices and persists them for reruns.

#### Explicit `-NameSeed`: persisted and reused, never silently drifted

Supplying `-NameSeed <value>` explicitly (instead of leaving it to be
derived) is also persisted into the exact same context-bound
`runtime/state/name-seed.json` record, so a *later* invocation that leaves
`-NameSeed` blank -- most importantly a simple
`& ./deploy.ps1 -UsersCsv ../config/users.csv -DestroyAll` run after an earlier
explicit-seed deploy -- reuses that same explicit value automatically
instead of silently deriving (or reusing) a different one and missing the
real backend/resources entirely. This closes what would otherwise be a
"NameSeed drift" gap between an explicit deploy and an unqualified
teardown:

- **First deploy with an explicit seed, no record yet:** the seed is
  written to `runtime/state/name-seed.json` bound to the resolved
  subscription/tenant.
- **A later run repeats the exact same explicit `-NameSeed` for the same
  subscription/tenant:** accepted idempotently (no error, no rewrite).
- **A later run supplies a *different* explicit `-NameSeed` for the same
  subscription/tenant than the one already on record:** fails closed
  (throws) rather than silently overwriting the record -- a rerun that
  omits `-NameSeed` afterward (a plain `-DestroyAll`, for example) must
  never end up looking for the wrong seed's backend/resources. Rerun with
  the already-recorded seed instead, or fully destroy everything under the
  recorded seed first if you genuinely intend to switch.
- **A different subscription/tenant than the one already on record:**
  always fails closed, exactly like the auto-derived case.

#### Before `-DestroyAll` reports "nothing to destroy"

If the Terraform state backend does not exist, `-DestroyAll` never simply
assumes nothing was ever deployed: it independently and conservatively
checks Azure itself for the exact, deterministic canonical resource group
name(s) this CSV/shared topology would use for the resolved (or persisted)
deployment profile's location (`rg-ts-shared-testing-<location-short>` and
`rg-ts-<slug>-testing-<location-short>` per developer -- `<location-short>`
is `weu`/`swc`/etc., see "Regional adaptation" above) and fails closed
(`BLOCKED`) if
any of them exist *and* still carry this repository's own canonical
project tags (`project=techsprint`, `environment=testing`,
`managed-by=terraform`, `cloud=azure`) -- never touching, deleting, or even
inspecting anything inside a matching group. A missing backend combined
with a matching, tagged resource group almost always means a wrong/stale
`-NameSeed`, corrupted or lost `runtime/state/name-seed.json`, or a
partially retired backend -- investigate by hand (confirm the correct
`-NameSeed`, or restore `bootstrap/backend.hcl` if the backend itself still
exists) before rerunning.

```powershell
pwsh -File ./deploy.ps1 -UsersCsv ../config/users.csv
```

generates any missing Ed25519 key pair under `keys/` for every CSV row,
validates the CSV, checks which CSV users already exist in Entra, and --
still entirely read-only -- checks whether the resolved subscription has
already accepted the Rocky Linux 10 Marketplace image's legal terms (see
below). It then prints a full pre-mutation summary: the resolved
subscription/tenant, the UPN domain and every expected `<slug>@<domain>`
UPN, the NameSeed, the pinned Rocky image version, which Entra users are
missing (will be created) and which already exist (reused, never
overwritten), **whether the Rocky Marketplace terms are already accepted or
will require a separate later phrase**, and the exact actions about to
run. It then waits for one typed `yes` before doing anything that mutates
Azure or the directory:

1. Bootstraps the Terraform state backend, only if it is not already PASS.
2. Creates only the missing Entra users with `New-AzADUser`, prompting a
   masked `SecureString` temporary password for each one individually
   (`-ForceChangePasswordNextLogin`). No password is ever printed, written
   to disk, or logged -- only the resulting UPNs are then passed to
   Terraform (`entra_mode = existing`, never
   `azuread_user.password`/`entra_mode = create`, so no initial credential
   ever ends up in a saved plan or state file). Already-existing UPNs are
   reused untouched, so a rerun is safe and idempotent.
3. Plans, then applies, the shared foundation, every tenant, and shared
   reconciliation.

#### Rocky Linux 10 Marketplace image terms: a separate, explicit gate

This command checks whether the resolved subscription has already
accepted the Rocky Linux 10 Marketplace image's legal terms
(`Get-AzMarketplaceTerms`, publisher `resf`, offer `rockylinux-x86_64`,
plan `10-lvm`) **twice**, independently, at two different points:

- **Once during the pre-mutation summary above** (still inside the
  read-only phase, before the general `yes` prompt) -- purely to *disclose*
  the status up front, so you know before typing `yes` whether a separate
  legal phrase will be required later. This disclosure never itself
  accepts anything and is never treated as authorization for the mutation
  below.
- **Again, completely independently, immediately before step 3's
  shared-foundation Apply** -- the earliest point this repository ever
  provisions a VM from this image -- which is the only place that can
  actually gate `Set-AzMarketplaceTerms`. Nothing about the earlier
  disclosure (including a stale or since-changed status) is reused there;
  it is a fresh `Get-AzMarketplaceTerms` call every time.

- **Already accepted:** it continues silently -- no prompt, no mutation,
  nothing printed beyond a one-line confirmation.
- **Not yet accepted:** it prints the exact subscription ID and
  publisher/offer/plan identifiers, official review links (the Azure
  Marketplace listing and the Azure Portal's per-subscription "Legal
  terms" page), and the exact `Get-AzMarketplaceTerms` command to inspect
  it yourself -- then requires typing the separate, exact, case-sensitive
  phrase `ACCEPT-ROCKY-MARKETPLACE-TERMS` (or supplying
  `-RockyMarketplaceTermsConfirmation 'ACCEPT-ROCKY-MARKETPLACE-TERMS'` for
  non-interactive automation) before calling `Set-AzMarketplaceTerms
  -Publisher resf -Product rockylinux-x86_64 -Name 10-lvm -SubscriptionId
  <resolved> -Accept`. The general `yes` above, and
  `-ApproveSubscriptionMutations`/`-ApproveDirectoryMutations` (even both
  together), **never** satisfy or bypass this separate confirmation --
  accepting a Marketplace publisher's legal terms is its own
  subscription-level legal agreement, not an infrastructure mutation.
  Declining, cancelling, or a mismatched phrase fails clearly with **no**
  terms mutation made, before any Terraform apply. Because this gate runs
  *after* the general `yes` above (which may already have bootstrapped the
  Terraform state backend and/or created a missing Entra user), declining
  it here does **not** roll either of those back -- they remain in place.
  A subsequent rerun detects them already present and reuses them
  (idempotent) rather than repeating them; it simply stops again at this
  same terms gate until the phrase is supplied.
- Recognizing the documented "agreement has never been signed" quirk
  (`Get-AzMarketplaceTerms` throwing instead of returning
  `Accepted = $false` for a never-signed agreement) is verified against
  Az.MarketplaceOrdering 2.2.0 and matches on the single, unambiguous,
  case-insensitive substring `never been signed` in the exception text.
  Any other failure (including one that otherwise mentions "legal terms")
  is treated as fail-closed -- rethrown, never assumed to mean the terms
  are already accepted.
- **Compatibility note (live-verified):** a second, separate
  Az.MarketplaceOrdering compatibility issue has also been observed live:
  `Get-AzMarketplaceTerms` can return *without throwing* an
  `AgreementTerms` object whose `Accepted`/`Product`/`Plan` properties are
  all `$null`, even immediately after `Set-AzMarketplaceTerms` reported
  success and the exact agreement's own ARM resource
  (`/subscriptions/{sub}/providers/Microsoft.MarketplaceOrdering/agreements/{publisher}/offers/{offer}/plans/{plan}?api-version=2021-01-01`)
  independently shows `properties.state = Active`. Whenever
  `Get-AzMarketplaceTerms` returns with `Accepted` absent/`$null` (but
  does not throw), this command falls back to exactly one additional
  read-only `Invoke-AzRestMethod GET` against that exact agreement ARM
  path (every path segment URL-escaped, API version pinned to
  `2021-01-01`), and fail-closed-parses the JSON response: an explicit,
  case-insensitive `properties.state = Active` **and** a matching
  publisher/offer/plan identity is treated as accepted; any other
  explicit `properties.state` value is treated as not accepted; a
  malformed/mismatched response body, a non-2xx HTTP status, a missing
  `state`, or the REST call itself failing are all treated as unexpected,
  fail-closed errors -- never as accepted. An explicit
  `Accepted = $true`/`$false` from `Get-AzMarketplaceTerms` itself remains
  fully authoritative and never triggers this fallback. Raw response
  bodies/signatures are never logged. This fallback also backs the
  independent post-`Set-AzMarketplaceTerms` read-back described below, so
  a live ARM `Active` state is correctly recognized there too.
- Once `Set-AzMarketplaceTerms` is actually called, this command verifies
  acceptance took effect two independent ways -- the cmdlet's own returned
  `Accepted` value, and a fresh, independent `Get-AzMarketplaceTerms`
  read-back -- and fails closed if either does not confirm `Accepted =
  true`.
- `-WhatIf` only ever *reports* a missing acceptance as a legal blocker
  (with the same identifiers/links); it never prompts and never calls
  `Set-AzMarketplaceTerms`, exactly like every other mutation this command
  can make.

This command still never accepts these terms *automatically* -- the
distinction from earlier versions of this document is that it can now
accept them at all, but only through this one separate, explicit, informed
operator action (or its exact non-interactive equivalent), never as a
side effect of any other confirmation.

Typing anything other than `yes` cancels with no changes made (exit code
`1`). Add `-WhatIf` for a non-mutating preview instead: it still resolves
and prints the full summary above (so you can review exactly what would
happen, including which Entra users are currently missing), but never
prompts, never creates a user, and never applies Terraform. What `-WhatIf`
actually previews depends on whether the Terraform state backend already
exists:

- **Fresh subscription (state not yet bootstrapped):** `-WhatIf` runs
  `Preflight` (reports not-PASS) and previews `Bootstrap -WhatIf`, then
  **stops** -- it never reaches a shared-foundation `Plan` in this run,
  because the shared root cannot be planned before the state backend
  exists. To actually see a shared-foundation plan, first bootstrap for
  real (either the interactive `yes` confirmation above, or both
  `-ApproveSubscriptionMutations -ApproveDirectoryMutations`), then rerun -- optionally with `-WhatIf`
  again -- once the state backend exists.
- **Already-bootstrapped subscription:** `-WhatIf` runs `Preflight`
  (reports PASS) and a real `Plan` of the shared foundation, then stops
  before creating any Entra user or applying anything.

Generated `.tfvars`/plan files go to the ignored `runtime/deploy/` by
default (`-WorkDir` to override; must stay outside the repo or under
repository `runtime/`).

If you already know the values and want a fully non-interactive run
(CI/automation/recovery), supply the advanced switches directly -- this
skips the interactive confirmation but still creates any missing Entra user
one at a time with a masked password prompt:

```powershell
pwsh -File ./deploy.ps1 -UsersCsv ../config/users.csv `
  -ApproveSubscriptionMutations -ApproveDirectoryMutations
```

Jump SSH allows `0.0.0.0/0` by default (CGNAT-compatible), key-only from
first boot, Fail2ban-protected after Ansible. There is no
`-AllowedSshCidr`/`-SshKeyDirectory` flag on this command; narrowing SSH
source or reusing keys elsewhere is an advanced/manual Terraform input only
(see `config/README.md`).

The CSV must use the assignment brief's own header, `ime;prezime;rola`
(`config/users.example.csv`); UPN is always `<slug>@<UpnDomain>` and
`network_slot` is always deterministic -- there is no extended header and no
per-row override.

The shared MySQL administrator credential and the developer-specific Moodle
database passwords are separate from Entra account passwords and are never accepted as
plain parameters. Supply `-TenantSecretsCommand <helper>` (prints one JSON
object per tenant slug, `{"moodle_database_password": "..."}`) or omit it to
be prompted once per tenant. The shared administrator credential is read once
from shared state and is used only for shared-root Terraform operations. Each
credential is exposed only transiently as the matching `TF_VAR_*` environment
variable in the current PowerShell process and inherited by its Terraform
child process; `try`/`finally` restores the prior value after every operation.
Neither credential is ever written to a `.tfvars` file, plaintext disk file,
or a log. The export path merges the shared administrator credential with
tenant database credentials only in memory and writes only the encrypted
Ansible Vault.

Ansible is not a separate mode. The normal command always exports the merged
inventory, creates the encrypted vault if needed, and runs the fixed Moodle
playbook after Terraform reconciliation. The Lead role generates its own
operational private key in place on the private Lead VM,
propagates only its public half to the application VMs with `no_log`, creates
the Lead-side generated SSH aliases, and verifies those SSH paths. There are
no Ansible switches or path parameters. These are source-level/offline-verified
behaviors; they are not live evidence until Ansible is reapplied and the SSH
verification is captured.

SSH host-key verification is disabled by default
(`StrictHostKeyChecking=no`, `UserKnownHostsFile=/dev/null`) for this lab's
convenience: there is no `known_hosts` file to populate, verify, or manage,
and no first-run trust step. This is a deliberate reduction of MITM
protection on the Jump-proxied SSH path, accepted for this
testing-scope lab environment; it is not appropriate for a production
deployment.

### Remaining prerequisites and limitations

- A fresh subscription typically fails the first `Preflight`/summary with
  `provider_not_registered` (`Microsoft.Resources`/`Microsoft.Storage`/
  `Microsoft.Authorization` not yet registered) -- this command never
  registers a provider; an operator must run `Register-AzResourceProvider`
  explicitly, then rerun. Quota/capacity and missing-Rocky-image failures
  print a similar one-line `HINT:` next to Terraform's/the state bootstrap's
  own error text; none of these conditions are ever auto-remediated.
- Simple mode fixes Entra handling to `existing`: the script creates missing
  users with Az PowerShell before Terraform. Alternate identity modes belong
  only to the low-level `scripts/Invoke-Azure.ps1` recovery path.
- Entra user creation is inherently interactive (one masked password prompt
  per missing user); there is no non-interactive way to supply those
  passwords through this command, by design (item 6: never accept a Terraform
  `azuread_user.password`, never accept a password as a plain parameter).
- The non-mutating `-WhatIf` preview never plans a tenant, since tenant
  plans need the same two secure MySQL/Moodle prompts as an apply. On a
  fresh, not-yet-bootstrapped subscription it previews only `Preflight` +
  `Bootstrap -WhatIf` and then stops (see above) -- it does not reach a
  shared-foundation plan in that run. On an already-bootstrapped
  subscription it plans only the shared foundation root. This mirrors the
  existing `-ApproveSubscriptionMutations`/`-ApproveDirectoryMutations`-less
  behavior of the advanced interface below.

## Advanced/recovery: the root-at-a-time path

The rest of this runbook documents the lower-level path
(`scripts/Invoke-Azure.ps1` / `& ./deploy.ps1 -Command ...`) that
`Deploy-Azure.ps1` calls underneath. Use it directly only for advanced
cases: rerunning one root by hand, recovery, or reconciling tenant
isolation after an out-of-band change. `Plan` always runs `terraform init`
+ `validate` first, so there is no separate `Init` command.

```powershell
$common = @{
  SubscriptionId = '00000000-0000-0000-0000-000000000000'
  TenantId = '00000000-0000-0000-0000-000000000000'
  NameSeed = 'replace-with-a-stable-non-secret-seed'
  StateAdministratorObjectId = @('00000000-0000-0000-0000-000000000000')
}
```

`NameSeed` has no default here either: Azure Storage account names are
globally unique across all of Azure and are derived from it, so a shared
constant would collide the moment two operators deploy at once. (This is
exactly the value `pwsh -File ./deploy.ps1 -UsersCsv ...` above derives and persists
for you automatically.)

```powershell
# State backend (Bootstrap creates only rg-ts-state-testing-<location-short>, its
# StorageV2 account, the private tfstate container, and state-account Blob
# Data Contributor assignments, via Microsoft Entra -- no keys/SAS. Writes
# ignored bootstrap/backend.hcl.)
& ./deploy.ps1 -Command Preflight @common
& ./deploy.ps1 -Command Bootstrap @common -ApplyStateBootstrap

# Shared foundation first (app_gateway_enabled = false), then one tenant
# input per developer, then the shared-reconcile input once every tenant's
# outputs exist. The shared administrator password is used only for shared
# operations; each tenant supplies only its own Moodle database-user password.
$dir = 'runtime/deploy'   # or any path outside the repository

& ./deploy.ps1 -Command Plan @common -Root shared `
  -VarFile "$dir/shared.tfvars" -PlanFile "$dir/shared-foundation.tfplan"

$env:TF_VAR_moodle_database_password = Read-Host -MaskInput 'Moodle database password'

& ./deploy.ps1 -Command Plan @common -Root tenant -TenantSlug luka-lukic `
  -VarFile "$dir/tenant-luka-lukic.tfvars" -PlanFile "$dir/tenant-luka-lukic.tfplan"

$env:TF_VAR_moodle_database_password = $null

& ./deploy.ps1 -Command Plan @common -Root shared `
  -VarFile "$dir/shared.tfvars" -VarFile "$dir/shared-reconcile.tfvars" `
  -PlanFile "$dir/shared-reconcile.tfplan"
```

## Generated Ansible inventory

A normal approved Terraform apply writes independent YAML staging fragments below the ignored `runtime/ansible/inventory/` directory. After shared reconciliation, the one-shot orchestrator merges them with `ansible-inventory --export` into the conventional, gitignored `ansible/inventories/production/hosts.yml`. Do not hand-edit or commit either runtime form. Run Terraform and Ansible in the same trusted workspace so the generated files carry over.

| Apply stage | File | Content |
| --- | --- | --- |
| Each tenant root | `20-<slug>.yml` | Private `app01`/`app02` via Jump `ProxyJump`, MySQL/NFS/Blob/UAMI values, the developer's public key, `mysql_allowed_client_ips` |
| Shared reconciliation (`app_gateway_enabled = true`) | `00-shared.yml` | `ansible_user`, `allowed_ssh_cidr`, Jump, the private Lead host, the private Application Gateway IP:8080 |

The initial shared apply writes no shared fragment; do not run Ansible until every tenant fragment and `00-shared.yml` exist and `hosts.yml` has been exported. No passwords, private keys, SAS values, or Terraform state ever appear in these files. Tracked `inventories/production/group_vars/*.yml` files contain non-secret defaults only.

## Apply

Apply always takes an already reviewed, saved plan plus both approval
switches:

```powershell
& ./deploy.ps1 -Command Apply @common -Root shared `
  -PlanFile "$dir/shared-foundation.tfplan" `
  -ApproveSubscriptionMutations -ApproveDirectoryMutations
```

A tenant `Apply` creates the tenant's app, storage, identity, and networking
against the already-created shared MySQL server; it consumes the shared
server's exact FQDN/HA contract and its own `moodle_<slug>` database/user/grant.
The shared server is the single `GP_Standard_D2ds_v4`, GeneralPurpose,
ZoneRedundant service on `10.10.3.0/24`; its shared DNS link is finalized in
the post-tenant reconciliation window. Not yet exercised against a live
subscription from this repository -- verify end-to-end first.

## Reconcile existing tenants after onboarding a developer

Each tenant keeps a separate Terraform state, so its foreign-spoke
deny-NSG/blackhole-UDR rules only reflect `known_developers` as of its own
last apply. After adding a developer, re-plan/re-apply the shared root and
**every already-existing tenant**, not just the new one:

```powershell
& ./deploy.ps1 -Command Reconcile @common `
  -VarFile "$dir/shared.tfvars" -VarFile "$dir/shared-reconcile.tfvars" `
  -TenantVarFileDirectory "$dir/tenants" `
  -TenantSecretsCommand /secure/azure/get-tenant-secrets.sh
```

This is read-only (plan-only, `-detailed-exitcode`); it requires
`$dir/tenants` to hold exactly one `<slug>.tfvars` per developer in the
supplied shared var file(s) (verified via `terraform console`, not trusted
blindly), and fails closed (`BLOCKED`/`FAIL`) until every root is converged.
`-TenantSecretsCommand` is invoked once per tenant slug and must print
`{"moodle_database_password": "..."}`; the shared administrator credential is
never requested from this helper, and neither value is ever written to disk or
logged.

## Configure storage after reconciliation

This is part of the default `pwsh -File ./deploy.ps1 -UsersCsv ...` flow. After Terraform
reconciliation, the script exports the production inventory, generates
`ansible/inventories/production/group_vars/all/vault.yml` and
`ansible/.vault-password` when absent, then runs Ansible. Both secret files are
gitignored and mode `0600`; an existing vault and password are preserved.

If the encrypted vault exists but its password file is missing, deployment
fails closed. Restore it from a secure backup. To deliberately replace an
existing vault after changing tenant secrets, run:

```powershell
pwsh -File ./scripts/Export-AnsibleSecrets.ps1 -UsersCsv ./config/users.csv -Force
```

Ansible decrypts the vault automatically through `ansible/ansible.cfg`. The
normal route remains the one-shot command above and manages its isolated SSH
agent automatically. For a deliberate
configuration-only rerun from Linux Bash, use this single block from the
repository root. It creates an isolated agent for this rerun, so a pre-existing
user agent is not changed; `ansible.cfg` supplies the generated inventory and
vault paths.

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

The generated private-host ProxyCommand starts a nested `ssh ... -W` to the
Jump host. `--private-key` covers the destination SSH command but does not
reliably provide the key to that nested SSH process, which is why the
dedicated agent is required here. In this situation, `Connection closed by
UNKNOWN port 65535` means nested ProxyCommand/Jump authentication failed; it
does not mean TCP port 65535 was used or that the Lead VM was deleted.

The former plaintext `ansible/moodle-secrets.yml` workflow is obsolete.

The mount is native NFSv4.1 (`nfs-utils`,
`vers=4,minorversion=1,sec=sys,noresvport,nconnect=4`) -- not SMB/CIFS, no
Kerberos, no storage keys or SAS. Blob stays a separate UAMI/BlobFuse2 path.

## Post-deployment test commands (Linux Bash)

Run these checks only after confirming the intended subscription, tenant, slug,
Jump host and private addresses. The configuration-only rerun block in
"Configure storage after reconciliation" changes live VM configuration: run it
once after the source fixes, then repeat its identical second run for the
idempotence proof. It starts and cleans up its own SSH agent. `ansible.cfg`
selects the generated inventory and vault; record only `PLAY RECAP`, never
either file or their contents.

Ovo je promjena žive konfiguracije, a ne offline provjera. Potvrdite ciljni
kontekst i odobrenje prije pokretanja. Ne prikazujte vault, lozinku za vault,
generirani inventar, plan, state ili privatni ključ.

### Pre-record automatska provjera

Ovaj blok koristi samo lokalne placeholder vrijednosti. Ispisuje statuse i
sažetak opaženih backend markera; ne ispisuje tijelo Moodle početne stranice.

```bash
set -euo pipefail
TENANT_SLUG='<slug>'
JUMP_PUBLIC_IP='<JUMP_PUBLIC_IP>'
KEY="Azure/keys/${TENANT_SLUG}"
HOST="${TENANT_SLUG}.moodle.test"
test -r "$KEY"; test -n "$JUMP_PUBLIC_IP"

ready="$(curl -sS -o /dev/null -w '%{http_code}' \
  --resolve "${HOST}:8080:127.0.0.1" "http://${HOST}:8080/readyz")"
printf 'readyz_status=%s\n' "$ready"; test "$ready" = 200
root="$(curl -sS -L -o /dev/null -w '%{http_code}' \
  --resolve "${HOST}:8080:127.0.0.1" "http://${HOST}:8080/")"
printf 'root_final_status=%s\n' "$root"; test "$root" = 200

seen_app01=0; seen_app02=0
for sample in 1 2 3 4 5 6; do
  response="$(curl -fsS --resolve "${HOST}:8080:127.0.0.1" \
    "http://${HOST}:8080/whoami")"
  case "$response" in *app01*) seen_app01=1;; *app02*) seen_app02=1;; esac
  printf 'whoami_sample=%s backend_marker_seen=yes\n' "$sample"
done
printf 'observed_app01=%s observed_app02=%s\n' "$seen_app01" "$seen_app02"
test "$seen_app01" = 1; test "$seen_app02" = 1
```

Šest poziva `/whoami` služe samo za dokazivanje oba backenda; ne obećavaju
redoslijed ili round-robin. Ako oba markera nisu opažena, provjerite backend
health umjesto da HA zaključite iz broja zahtjeva.

### Tunel, readiness i canonical Moodle ruta

Developerski račun na Jumpu je točan slug i koristi `Azure/keys/<slug>`. Lead
ili operator može koristiti `azureuser` i `Azure/keys/<LEAD_SLUG>`.

```bash
# Developer
JUMP_IP='<JUMP_PUBLIC_IP>'
ssh -i "Azure/keys/<slug>" -o IdentitiesOnly=yes \
  -o ExitOnForwardFailure=yes -N \
  -L 127.0.0.1:8080:10.10.2.10:8080 "<slug>@${JUMP_IP}"

# Lead/operator alternative
ssh -i "Azure/keys/<LEAD_SLUG>" -o IdentitiesOnly=yes \
  -o ExitOnForwardFailure=yes -N \
  -L 127.0.0.1:8080:10.10.2.10:8080 "azureuser@${JUMP_IP}"
```

S aktivnim tunelom readiness ispisuje tijelo i status te vraća grešku ako
status nije 200. Root test prati redirecte, skriva tijelo i zahtijeva konačni
HTTP 200:

```bash
set -euo pipefail
HOST='<slug>.moodle.test'
ready_body="$(mktemp)"
trap 'rm -f -- "$ready_body"' EXIT
ready_status="$(curl -sS --resolve "${HOST}:8080:127.0.0.1" \
  -o "$ready_body" -w '%{http_code}' "http://${HOST}:8080/readyz")"
printf 'readyz_body='
tr '\n' ' ' < "$ready_body"
printf 'readyz_status=%s\n' "$ready_status"
test "$ready_status" = 200
root_status="$(curl -sS -L -o /dev/null -w '%{http_code}' \
  --resolve "${HOST}:8080:127.0.0.1" "http://${HOST}:8080/")"
printf 'root_final_status=%s\n' "$root_status"; test "$root_status" = 200
```

Za praktičniji dokaz `/readyz` tijela može se koristiti `curl -i` izvan
automatiziranog bloka, ali ne prikazujte tajne ili runtime inventar.

### Gateway health, mountovi i Lead SSH

Azure CLI naredba koristi očekivanu `show-backend-health` shemu i prikazuje
samo adresu člana poola, health i probe log:

```bash
az network application-gateway show-backend-health \
  --resource-group '<SHARED_RG>' --name '<APP_GATEWAY_NAME>' \
  --query 'backendAddressPools[].backendHttpSettingsCollection[].servers[].{address:address,health:health,probeLog:healthProbeLog}' \
  -o table
```

Ako verzija CLI-ja vraća drukčiju strukturu, upotrijebite nakon odobrene
prijave ekvivalentni `Get-AzApplicationGatewayBackendHealth` cmdlet i odaberite
samo ta tri polja; nemojte ispisati cijeli objekt.

Kroz Jump provjerite oba privatna app VM-a:

```bash
check_mounts() {
  ssh -i "Azure/keys/<slug>" -o IdentitiesOnly=yes \
    -o ProxyJump="<slug>@<JUMP_PUBLIC_IP>" "<APP_SSH_USER>@$1" -- \
    'findmnt -rn -o TARGET,FSTYPE,OPTIONS --target /srv/moodle-local;
     findmnt -rn -o TARGET,FSTYPE,OPTIONS --target /mnt/moodle-shared;
     findmnt -rn -o TARGET,FSTYPE,OPTIONS --target /mnt/moodle-objects'
}
check_mounts '<APP01_PRIVATE_IP>'
check_mounts '<APP02_PRIVATE_IP>'
```

Očekujte odvojeni data disk na `/srv/moodle-local`, Azure Files NFSv4.1 s
`sec=sys` na `/mnt/moodle-shared` i uspješan BlobFuse2 na
`/mnt/moodle-objects`. Ne hardkodirajte FUSE filesystem type jer se može
razlikovati po verziji BlobFuse2.

Disk role nakon mounta trajno mapira samo lokalno stablo
`/srv/moodle-local(/.*)?` na SELinux type `httpd_sys_rw_content_t`, izvršava
rekurzivni `restorecon` i provjerava očekivani `matchpathcon` te stvarni
mount-root context. Ako marker već postoji, provjerava se i njegov context;
na prvom prolazu marker još ne mora postojati. Ovo je ciljani popravak živog
AVC-a u kojem je enforcing `httpd_t` PHP-FPM-u odbijen `getattr` nad
`.techsprint-mount-ready` s `var_t`. NFS/Blob labeli se ne diraju. Nakon
izvornog popravka obavezno ponovite Ansible i potvrdite `/readyz` 200 uživo;
offline provjera sama po sebi nije dokaz oporavka.

Nakon reapply-a, s privatnog Lead VM-a provjerite generirane alias-e i prikažite
samo hostname/non-secret rezultat:

```bash
ssh "app-<slug>-app01" -- 'hostname'
ssh "app-<slug>-app02" -- 'hostname'
```

Kod greške su sigurni dijagnostički izvodi:

```bash
sudo systemctl --failed
sudo systemctl status nginx php-fpm --no-pager
sudo journalctl -u nginx -u php-fpm --since '-15 min' --no-pager
```

Ansible prije pokretanja web-usluga root-level `findmnt --mountpoint` provjerava
sva tri točna mounta i tek zatim na njima stvara deployment-bound
`.techsprint-mount-ready` markere. Nova `/readyz` 200 znači da su ti markeri
čitljivi i vezani uz očekivani deployment ID te da je TLS MySQL `SELECT 1`
uspješan; gubitak mounta skriva njegov marker i vraća 503. PHP ne čita
`/proc/self/mountinfo`, a SELinux se ne proširuje izvan lokalnog XFS stabla.
root 200 znači da Nginx/Moodle put radi. 403 znači da je Nginx ili aplikacija
dosegnuta, ali odbija zahtjev; 502 znači da gateway nije dobio valjan backend
odgovor; 503 znači da backend ili readiness/gateway health nije spreman.

### Opcionalna RBAC/power provjera

Start, restart i deallocate su **mutirajuće** radnje. Izvršite ih samo s
izričito odobrenim ciljem, zabilježenim početnim stanjem i planom vraćanja:
developer smije upravljati samo vlastitim app VM-ovima, drugi developer mora
biti odbijen, a Lead smije upravljati svim projektnim VM-ovima. Ne pokrećite
`az vm start`, `az vm stop`, `az vm deallocate` ili restart u snimci bez tog
odobrenja i obavezne restauracije.

## Destroy

State is preserved. Make and review a saved destroy plan for one tenant at
a time:

```powershell
& ./deploy.ps1 -Command Plan @common -Root tenant -TenantSlug luka-lukic `
  -VarFile "$dir/tenant-luka-lukic.tfvars" -DestroyPlan `
  -PlanFile "$dir/tenant-luka-lukic.destroy.tfplan"

& ./deploy.ps1 -Command Destroy @common -Root tenant -TenantSlug luka-lukic `
  -PlanFile "$dir/tenant-luka-lukic.destroy.tfplan" `
  -ApproveSubscriptionMutations -ApproveDirectoryMutations `
  -AllowDestroy -DestroyConfirmation 'AZURE-DESTROY'
```

Destroy tenant roots before the shared root. Leave the state resource
group/account/container and `bootstrap/backend.hcl` in place unless a
separate, approved state retirement is intended.

## Full teardown: `& ./deploy.ps1 -UsersCsv ../config/users.csv -DestroyAll`

This is the one-command mirror of the normal simple-mode deploy above: the
same CSV, the same read-only session-derived subscription/tenant/NameSeed
resolution, no other switches required for the normal case.

```powershell
# Preview only -- never applies, deletes, or removes anything.
& ./deploy.ps1 -UsersCsv ../config/users.csv -DestroyAll -WhatIf

# Full teardown for real.
& ./deploy.ps1 -UsersCsv ../config/users.csv -DestroyAll
```

The execute form always prints the exact resource-group scopes and Entra
UPNs it is about to affect, then requires the exact, case-sensitive typed
phrase `AZURE-DESTROY-ALL` (or `-DestroyAllConfirmation 'AZURE-DESTROY-ALL'`
for non-interactive/automation use). This is a *different* phrase from the
advanced per-root `AZURE-DESTROY` used by `-Command Destroy` above, and is
never satisfied or bypassed by `-ApproveSubscriptionMutations`/
`-ApproveDirectoryMutations` -- those two only ever gate the normal deploy
path's own mutations.

### Order (dependency-safe; never a raw `terraform destroy`)

0. **Recover a missing local `bootstrap/backend.hcl`, if needed** -- happens
   automatically, immediately after the read-only Preflight check, strictly
   before any Plan call. If Preflight *conclusively* reports the Azure-side
   state backend already exists (exit code 0 and a relayed `"status":
   "PASS"`) but this exact checkout's own `bootstrap/backend.hcl` is
   missing (a fresh clone, a lost/never-committed file, or a different
   `-WorkDir`), `-DestroyAll` writes that one local, non-secret file itself
   using the exact deterministic resource_group_name/storage_account_name/
   container_name identity it already independently computed -- it never
   creates or repairs anything in Azure to do this. Mode `0600`. An
   existing file whose content does not match that exact identity is never
   overwritten: `-DestroyAll` fails closed instead (investigate by hand --
   usually a wrong/stale `-NameSeed`). This is the fix for "Preflight
   passes but the next Plan still fails with a missing backend.hcl error".
1. **Detach the shared foundation** -- plans and (once confirmed) applies the
   shared root with the original shared-foundation shape
   (`app_gateway_enabled = false`, no `tenant_networks`/`tenant_backends`):
   removes the private Application Gateway, every hub-to-spoke peering, and
   every shared private DNS zone virtual-network link to a tenant VNet. This
   step is required, not just tidy -- Azure refuses to delete a VNet that
   still has an active private DNS zone virtual-network link pointing to it.
2. **Destroy every tenant** in the CSV, one at a time, each via its own
   reviewed, delete-only saved plan (`Invoke-Azure.ps1`'s existing
   `-DestroyPlan` + `Destroy`, exactly like the advanced per-root path
   above -- never a raw `terraform destroy`). A tenant whose destroy plan
   already shows no pending resource changes is reported and skipped rather
   than re-attempted, so a rerun after a partial failure is safe.
3. **Destroy the shared foundation** itself (Jump, Lead, hub network,
   identity) -- only once every tenant above destroyed cleanly.
4. **Remove the out-of-band-verified project custom role**
   (`TechSprint VM Power Operator`, `infra/azure/shared/main.tf`'s
   `azurerm_role_definition.vm_power_operator`) -- only after phases 1-3
   above succeed. This role is **subscription-scoped**, not resource-group
   scoped, so it survives a resource-group/backend deletion performed
   outside Terraform entirely (the exact failure mode that motivated this
   phase: an operator had to manually delete every project resource group
   because `-DestroyAll` itself had failed, orphaning this role with no
   Terraform state left to destroy it again). Runs **regardless of whether
   the state backend or any canonical project resource group exists** --
   it is discovered and shown in the pre-mutation summary up front, then
   re-discovered fresh immediately before the actual deletion (never
   trusting the earlier snapshot). A role is only ever removed once its
   full ownership fingerprint is verified against this project's own
   canonical Terraform definition (exact name, description, `IsCustom`,
   single subscription assignable scope, and the exact
   actions/not_actions/data_actions/not_data_actions sets) -- never by name
   alone. More than one role sharing the exact name, or one role sharing
   the name but failing any other part of the fingerprint, fails the whole
   run closed (`BLOCKED`) instead of guessing. A role that still has one or
   more active role assignments (checked fresh immediately before deletion)
   also fails closed rather than force-deleting through Azure's own
   "role definition still has assignments" refusal or touching a foreign
   assignment. If this project's own normal Terraform teardown (phases 1-3)
   already removed the role, this phase finds nothing and is a silent
   no-op. **Ordered before Entra removal, not after**: a subscription-scoped
   custom role and its role assignments are treated as an
   infrastructure/subscription-RBAC dependency, so any failure here --
   including a role that still has assignments -- blocks phase 5 (Entra
   removal) below entirely; deleting directory identities first would leave
   no safe way to still investigate/re-verify manifest-tracked ownership
   while this RBAC cleanup remains unresolved.
5. **Remove only the Entra users this script itself created** (see manifest
   below), each re-verified by its immutable object ID first -- only after
   phases 1-4 (including the role cleanup in phase 4) all succeed. Any
   incomplete infrastructure or role-cleanup teardown skips this directory
   mutation entirely so reruns retain the identities Terraform may still
   need to evaluate remaining state.
6. **Retire the Terraform state backend** (`rg-ts-state-testing-<location-short>`, its
   storage account, and the `tfstate` container) -- only once every phase
   above succeeded with zero failures, no manifest-tracked Entra user
   remains, no tenant state exists in the backend container outside this
   CSV, and one more independent, fresh check proves both the shared root's
   and every tenant's own Terraform state are *actually* empty (see "Final
   empty-state verification" below). Skip this with `-KeepStateBackend` to
   redeploy again afterwards without re-bootstrapping. `bootstrap/backend.hcl`
   is only removed after the backend deletion itself actually succeeds.
   Generated SSH private keys under `keys/` are never touched by
   `-DestroyAll`.
7. **Remove the persisted deployment-profile record**
   (`runtime/state/deployment-profile.json`) -- only reached immediately
   after step 6's backend retirement actually succeeds for real (never on
   `-KeepStateBackend`, an already-absent backend, or any earlier phase
   failure). The next normal deploy for this subscription/tenant then
   re-runs `scripts/Resolve-AzureDeploymentProfile.ps1`'s read-only,
   quota-aware resolution from scratch instead of silently reusing the
   just-retired profile's region/VM SKU. This is how a subscription whose
   previously-selected SKU's own quota has since changed (for example
   `Standard_B2als_v2`'s `standardBasv2Family` quota dropping below this
   project's 12-vCPU fleet requirement) safely switches to a different
   quota-aware SKU (for example `Standard_D2als_v6`) on the very next
   redeploy: run `-DestroyAll` (which always reuses the *old* persisted
   profile to tear down what was actually deployed under it), confirm it
   reports `DESTROYED`, then rerun the normal deploy -- no manual removal of
   `runtime/state/deployment-profile.json` is needed or should be attempted
   by hand.

#### Final empty-state verification (before backend retirement only)

Backend deletion never relies solely on the exit codes of the Destroy
commands run in steps 1-3 above. Immediately before retiring the backend,
`-DestroyAll` generates one more fresh, delete-only Terraform plan for the
shared root and for every tenant slug (reusing the exact same
`Plan -DestroyPlan` command as every other destroy step) and requires each
one to show **zero** pending managed-resource changes right now. If this
independent proof cannot be completed at all (a transient error, a plan
that cannot even be generated), or if it comes back showing residual
managed-resource changes for any root, backend retirement is refused --
this is treated as "verification failed, do not retire", never as "assume
it is empty". Investigate by hand (rerun the advanced per-root
`Plan -DestroyPlan`/`Destroy` for the affected root) before retrying
`-DestroyAll`.

The sensitive tenant Terraform variable (`TF_VAR_moodle_database_password`) is
never prompted for or read from a real secret during a destroy: a fixed,
clearly-named, non-credential placeholder is set in the current process's
environment only for the duration of each tenant's plan/destroy pair and is
restored (typically to unset) in a `finally` immediately after, exactly like
the advanced Reconcile path above. Shared destroy plans reuse the existing
shared administrator credential and never generate a replacement.
A destroy plan's set of delete actions comes entirely from what is already
tracked in that tenant's own Terraform state, never from attribute values
such as the Rocky image version or an SSH key's content, so the placeholders
never change what gets deleted. Phase 1 is an ordinary shared reconciliation
plan rather than a delete-only plan, so it deliberately reuses the persisted
Rocky image version; this prevents an image-version placeholder from proposing
VM replacements while detaching Application Gateway, peering, and DNS links.

### `-WhatIf` behavior

`-DestroyAll -WhatIf` never changes Azure. One intentional local-only exception exists: if the Azure-side backend passes the read-only preflight but the ignored `bootstrap/backend.hcl` file is missing, the command reconstructs that deterministic, non-secret file (mode `0600`) so Terraform can produce the requested preview plans. An existing conflicting file is never overwritten.

- **State backend does not exist yet, no manifest-tracked Entra user, and no
  out-of-band project custom role:** reports `NOTHING_TO_DESTROY` -- there
  is no shared/tenant Terraform state to plan a destroy against. A
  subscription-scoped project custom role is always checked for, even with
  an absent backend (see phase 4 above): if a verified role is still
  present, `-DestroyAll` never reports `NOTHING_TO_DESTROY` -- it proceeds
  so that role can still be removed. Only once neither a backend, a
  manifest-tracked Entra user, nor this role remain does a rerun report
  `NOTHING_TO_DESTROY` again (idempotent).
- **State backend exists:** previews Phase 1 (the shared-detach plan) and
  Phase 2 (each tenant's own destroy plan) via genuine, read-only
  `terraform plan` calls (never `apply`/`destroy`), reporting for each
  either `changes_pending` (there is something to detach/destroy),
  `already_detached`/`already_empty` (a prior run already got there), or
  `preview_failed` (best-effort: one phase's preview failing never aborts
  the rest). Phase 3 (the shared root's own full destroy plan) is
  deliberately **not** previewed: its accuracy depends on Phase 1's detach
  having already been *applied*, not merely planned -- Azure refuses to
  delete a VNet while a private DNS zone virtual-network link from the
  shared root still points to it. Rerun `-DestroyAll` without `-WhatIf` to
  apply Phase 1 for real before a later Phase 3 preview would be meaningful.
  Entra-removal, project-custom-role-removal, and backend-retirement phases
  are only ever listed in the printed summary under `-WhatIf`, never
  executed.

### The Entra user manifest (why pre-existing accounts are never deleted)

Every Entra user the normal deploy path actually creates with `New-AzADUser`
is recorded -- non-secret, no password -- in a context-bound manifest at the
ignored `runtime/state/entra-users.json`: exact UPN, the immutable object ID
`New-AzADUser` returned, the normalized subscription ID, and tenant ID. A
user this repository finds already existing in Entra is never added to this
manifest and is therefore never a `-DestroyAll` deletion candidate, no
matter how many times the CSV is reused.

`-DestroyAll` deletes **only** manifest-recorded users, and only after
re-resolving that UPN's *current* Entra object ID and confirming it still
exactly matches the ID recorded at creation time:

- **Missing** (UPN no longer resolves to any account): treated as already
  removed; the manifest entry is simply dropped.
- **Match**: deleted with `Remove-AzADUser`, then the manifest entry is
  dropped only once that deletion actually succeeds.
- **Mismatch** (the UPN now resolves to a *different* object ID -- for
  example someone deleted and recreated the same UPN by hand in between):
  fails closed, deletes nothing, leaves the manifest entry in place, and is
  reported as a phase failure that blocks state-backend retirement until it
  is resolved by hand.

A same-context rerun of the normal deploy path merges new entries into this
manifest idempotently (by UPN); a manifest found belonging to a *different*
subscription/tenant, or one that is invalid/corrupt JSON, fails closed
instead of being silently trusted, migrated, or overwritten.

### The out-of-band project custom role (why a manual RG deletion cannot orphan it forever)

`infra/azure/shared/main.tf`'s `azurerm_role_definition.vm_power_operator`
(display name `TechSprint VM Power Operator`) is **subscription-scoped**,
not resource-group scoped -- unlike every other resource this project
creates, deleting the resource groups it lives "inside" (there is no
resource group; a custom role definition is a direct child of the
subscription) does nothing to it. A prior version of this project's own
`-DestroyAll` had no way to find or remove this role once the backend/state
that would normally track it was gone (for example after an operator
manually deleted every project resource group because `-DestroyAll` itself
had failed) -- the role stayed present in subscription RBAC forever. This
carries no direct Azure charge of its own (a role definition is not a
billed resource), but it is a stale subscription-scoped object with no
owning Terraform state: a future fresh bootstrap creates a *second*,
differently-ID'd role sharing the same name rather than reusing/replacing
the orphan, and `-DestroyAll`'s own discovery deliberately refuses to guess
between two same-named roles -- a redeploy conflict, not a billing one.

`-DestroyAll` now discovers, fingerprint-verifies, and (only after the same
typed `AZURE-DESTROY-ALL` confirmation as everything else) removes exactly
this one role as its own phase 4, ordered *before* Entra user removal
(phase 5) since a subscription-scoped role and its assignments are treated
as an infrastructure/subscription-RBAC dependency -- independently of
whether the state backend or any canonical project resource group exists.
Ownership is proven
by an exact match of name, description, `IsCustom`, the single subscription
assignable scope, and the exact actions/not_actions/data_actions/
not_data_actions sets against `infra/azure/shared/main.tf`'s own canonical
definition -- **never by the role's name alone**, and never by its ID
alone either (the one legacy role deployed before this project pinned
`role_definition_id` to a fixed literal has a provider-generated ID, and is
still correctly recognized by its fingerprint). More than one role sharing
the exact name, or a role sharing the name but failing any other part of
the fingerprint, fails the entire `-DestroyAll` run closed (`BLOCKED`)
instead of guessing -- investigate by hand
(`Get-AzRoleDefinition -Name 'TechSprint VM Power Operator'`) before
retrying. A role that still has one or more active role assignments (this
is re-checked fresh, immediately before deletion, never trusting an earlier
snapshot) is also refused rather than force-deleted or having a foreign
assignment silently removed.

### Recovery from a partial failure

`-DestroyAll` reports `PARTIAL` (nonzero exit) and lists exactly which named
phase(s) failed (for example `shared-detach`, `tenant:<slug>`,
`entra-mismatch:<upn>`, or `project-role-removal`) if anything did not
complete. Every phase above is safe to simply rerun: an already-detached
shared foundation, an already-destroyed tenant, an already-removed Entra
user, and an already-removed (or never-existed) project custom role are
each detected and skipped rather than re-attempted or double-deleted. The
state backend is retired only once a rerun reports zero phase failures.

Backend retirement being skipped for its own, independent reasons (every
Terraform/Entra phase above already succeeded, but retirement itself was
still refused) is reported the same way -- `PARTIAL`, nonzero exit -- with
one of these markers, so a caller checking `status`/exit code alone is
never told teardown fully completed while the billable state backend is
still standing:

| Marker | Meaning |
| --- | --- |
| `backend-retirement-skipped:entra-manifest-nonempty` | The Entra manifest still has an entry on disk after removal was attempted (re-read fresh, independently of what the removal step itself reported -- see "The Entra user manifest" above) |
| `backend-retirement-skipped:verification-failed` | The final empty-state verification (see above) could not be completed at all |
| `backend-retirement-skipped:orphan-tenant-state` | The backend container has a `tenants/<slug>.tfstate` not covered by this CSV -- add the developer back and rerun, or remove it by hand first |
| `backend-retirement-skipped:residual-managed-state` | The final empty-state verification ran but found pending managed-resource changes for one or more roots |

Each of these is safe to investigate and resolve independently, then rerun
`-DestroyAll` (every already-completed Terraform/Entra phase is skipped
again, as above); resolving the underlying condition is what allows
retirement to proceed on the next run.

### Concurrency

Two invocations of `scripts/Deploy-Azure.ps1` (deploy or `-DestroyAll`, in
any combination) against the **same checkout** are prevented by a same-
checkout advisory lock: a non-secret file at the ignored
`runtime/state/orchestration.lock` (recording the owning process ID, start
time, and hostname), acquired via an atomic exclusive file create as the
very first thing the command does -- before any CSV/Terraform/Azure I/O --
and always released afterward, on every exit path (success, a handled
error, or an interrupted run), including one that instead reclaims a
*stale* lock left behind by a prior run that crashed or was killed without
cleanup (its recorded process ID is checked and, only if it is no longer
running, the lock is reclaimed automatically rather than wedging the
checkout permanently). A second, genuinely concurrent invocation against
the same checkout fails immediately and closed, naming the process ID and
start time already holding the lock, before touching anything:

```
Refusing to run: another deploy/-DestroyAll invocation (process ID <pid>,
started <timestamp> UTC) already holds the same-checkout orchestration
lock at '.../runtime/state/orchestration.lock'. ...
```

This is advisory, not an OS-level lock, and it is explicitly scoped to one
checkout's own `runtime/state/` directory:

- It **is** sufficient to stop an operator (or a script) from accidentally
  running two overlapping `deploy.ps1`/`-DestroyAll` invocations from the
  same clone -- for example two terminal tabs, or a cron job overlapping a
  manual run.
- It **does not** prevent two *different* checkouts (a second `git clone`,
  or a second CI runner with its own independent working copy) from running
  concurrently against the very same Azure subscription and Terraform state
  backend. Nothing in this repository can enforce that across separate
  checkouts; treat "only ever run deploy/-DestroyAll for a given
  subscription from one designated checkout/runner at a time" as an
  operational rule instead, exactly like the Terraform state backend's own
  remote-state locking already protects the Terraform state itself but not
  this script's own local, pre-Terraform steps (Entra user creation/lookup,
  tfvars generation, the NameSeed/Entra-manifest JSON records under
  `runtime/state/`).
- If you are certain no other invocation is actually running (for example
  after a hard host reboot) but the lock still appears held, remove
  `runtime/state/orchestration.lock` by hand only after that independent
  confirmation.

### Cost-stop check

After `-DestroyAll` reports `DESTROYED`, confirm nothing billable remains:

```powershell
Get-AzResourceGroup | Where-Object ResourceGroupName -Match '^rg-ts-'
```

This should return nothing once the backend has also been retired (the
default; add `-KeepStateBackend` to intentionally keep
`rg-ts-state-testing-<location-short>` for a later redeploy). Retained by design and
unaffected by `-DestroyAll`: the Entra tenant/subscription itself, any
resource provider registrations, and every generated SSH key pair under
`keys/`.
