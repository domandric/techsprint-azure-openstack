# Azure state bootstrap

`Initialize-AzureTerraformState.ps1` is a small, fail-closed Azure PowerShell
bootstrap for the remote Terraform state backend. It is deliberately separate
from the Terraform lifecycle: it creates only the canonical state resources
and writes a non-secret partial backend configuration.

It never performs `Connect-AzAccount`, provider registration, key listing, SAS
creation, or a storage-key/connection-string operation. Authenticate before
running it, set the intended Az context, and pass the matching subscription and
tenant IDs explicitly.

## Preconditions

- PowerShell 7.4 or newer and `Az.Accounts`, `Az.Resources`, and `Az.Storage`.
- The current Az context is already authenticated and exactly matches
  `-SubscriptionId` and `-TenantId`.
- `Microsoft.Resources`, `Microsoft.Storage`, and `Microsoft.Authorization`
  are already registered. The script reads their state and exits fail-closed if
  any is not registered; it never registers them.
- The executing identity can read the subscription, resource groups, storage
  accounts, and scoped role assignments. For `-Apply` it also needs permission
  to create the state RG/account, assign the data role at the storage-account
  scope, and create a blob container.
- `-StateAdministratorObjectId` contains the object IDs that must write
  Terraform state, including the identity used by the lifecycle runner. The
  script grants only `Storage Blob Data Contributor` at the one state storage
  account scope. For `-Apply`, the currently authenticated bootstrap identity
  must be in this list or already have equivalent blob-data access; it creates
  and verifies the container through that identity's OAuth context.

The non-secret `NameSeed` must exactly match the Terraform input. The account
name is deterministic: `sttsstateb` plus the first four lowercase hex
characters of SHA-256 over `name_seed + ":state"`.

`-Location`/`-LocationShortName` (both optional; default to the historical
`westeurope`/`weu`) parameterize the state resource group's region and its
name suffix (`rg-ts-state-testing-<LocationShortName>`) -- see
`docs/architecture/README.md`'s "Regional adaptation" section.
`scripts/Invoke-Azure.ps1` always passes its own caller's resolved values
explicitly (normally `scripts/Resolve-AzureDeploymentProfile.ps1`'s output,
via `scripts/Deploy-Azure.ps1`); a manual invocation of this script directly
should supply the exact same values used for the Terraform state that
backend actually holds -- a mismatch is caught by the resource-group-identity
conflict check (`resource_group_identity_conflict`), never silently
tolerated.

## Run

First authenticate and select the intended context outside this script. Do not
put any credential material into command arguments or files.

Read-only preflight (default; exit `0` only when fully ready, `2` when state is
missing or drifted, and `1` for a fail-closed error):

```powershell
pwsh -File ./bootstrap/Initialize-AzureTerraformState.ps1 `
  -SubscriptionId '<subscription-guid>' `
  -TenantId '<tenant-guid>' `
  -NameSeed '<same-non-secret-name-seed-as-Terraform>' `
  -StateAdministratorObjectId '<terraform-runner-object-guid>' `
  -PreflightOnly
```

Preview the only possible changes:

```powershell
pwsh -File ./bootstrap/Initialize-AzureTerraformState.ps1 `
  -SubscriptionId '<subscription-guid>' `
  -TenantId '<tenant-guid>' `
  -NameSeed '<same-non-secret-name-seed-as-Terraform>' `
  -StateAdministratorObjectId '<terraform-runner-object-guid>' `
  -Apply -WhatIf
```

After the user's Azure-change approval, run the same command with `-Apply`.
The high-impact PowerShell confirmation remains enabled. Run preflight again
after RBAC propagation before initializing Terraform.

## Result and Terraform handoff

`-Apply` creates or reuses only:

- `rg-ts-state-testing-<LocationShortName>` (`rg-ts-state-testing-weu` in
  West Europe by default; `rg-ts-state-testing-swc` when `-Location
  swedencentral -LocationShortName swc` is resolved/supplied instead -- see
  above);
- the deterministic `StorageV2`, `Standard_LRS` account with TLS 1.2, HTTPS,
  infrastructure encryption, shared-key access disabled, public blob access
  disabled, local users/SFTP disabled, and `DefaultAction = Allow` network
  rules (network access is intentionally unrestricted; identity is the
  security boundary — see below);
- private `tfstate`; and
- the requested scoped Azure RBAC data-role assignments.

Both preflight and apply verify `tfstate` through an OAuth storage context.
A missing or publicly accessible container is reported as `BLOCKED` during
preflight and repaired by `-Apply`.

Any unexpected Azure API failure (most importantly a region-level policy
deny, for example `RequestDisallowedByAzure: selected region is currently
not accepting new customers`) is reported with a short, sanitized,
allow-listed `failure_detail` field alongside the existing `failure_code`
JSON field, instead of only the generic `fail_closed` code -- see
`Get-SanitizedAzureFailureDetail` in the script. This never echoes the raw
exception message or any secret/inventory value verbatim; only a small,
fixed set of known-safe phrases is ever emitted.

The generated, gitignored file is `bootstrap/backend.hcl`. It contains only these azurerm backend
identifiers:

```hcl
resource_group_name  = "rg-ts-state-testing-weu"
storage_account_name = "<deterministic-name>"
container_name       = "tfstate"
use_azuread_auth     = true
```

It intentionally omits `key`. The lifecycle runner must provide the
root-specific state key separately, for example with a second
`-backend-config=...` argument. Do not add a key, credentials, tokens, or
connection strings to the generated file. The repository root `.gitignore`
excludes it.

If this local file is ever lost (a fresh clone, a different `-WorkDir`, or
accidental deletion) while the Azure-side backend it describes still
exists, `scripts/Deploy-Azure.ps1 -DestroyAll` recovers it automatically
and safely: immediately after its own read-only Preflight check, and only
once Preflight *conclusively* reports every Azure-side component already
matches this exact canonical identity (never on a `BLOCKED`/`FAIL`
Preflight result), it (re)writes this exact four-line file itself, using
the same deterministic identity this repository always derives, and
enforces mode `0600`. This recovery path makes zero Azure API calls beyond
the Preflight check itself -- it never creates or repairs an Azure
resource. An existing file whose content does not already match that exact
identity is never overwritten; the command fails closed instead
(investigate by hand -- usually a wrong/stale `-NameSeed`). See the "Full
teardown" section of the
[operations runbook](../docs/operations/runbook.md) for the full ordering.

The script uses `New-AzStorageContext -UseConnectedAccount`, so its blob
operations use Microsoft Entra ID rather than an account key. The Az Storage
cmdlets used here do not expose the portal-default OAuth preference; the
security boundary is enforced by disabled shared-key access, scoped RBAC to
only the requested administrator object IDs, and the generated Terraform
backend's `use_azuread_auth = true` — not by a network-level IP allow-list.

Official cmdlet references: [New-AzStorageAccount](https://learn.microsoft.com/en-us/powershell/module/az.storage/new-azstorageaccount), [New-AzStorageContext](https://learn.microsoft.com/en-us/powershell/module/az.storage/new-azstoragecontext), and [New-AzStorageContainer](https://learn.microsoft.com/en-us/powershell/module/az.storage/new-azstoragecontainer).
