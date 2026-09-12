# Manual Terraform inputs

`pwsh -File ./deploy.ps1 -UsersCsv ../config/users.csv` (`scripts/Deploy-Azure.ps1`) is the
normal, one-invocation entry point: it derives the subscription/tenant, the
state administrator, the UPN domain, `NameSeed`, and the pinned Rocky Linux
image version read-only from your active `Connect-AzAccount` session
(`scripts/Resolve-AzureContext.ps1`), generates any missing key pair under
`keys/`, validates the CSV, creates any missing Entra user after one typed
confirmation, and drives the whole workflow -- see
`docs/operations/runbook.md`. `scripts/Invoke-Azure.ps1`
(`./deploy.ps1 -Command ...`) is the low-level, root-at-a-time runner it
calls underneath; use it (and the example `.tfvars` files below) directly
only for advanced cases: rerunning one root by hand, recovery, hand-edited
tfvars, or overriding just one of the auto-derived values explicitly on the
`pwsh -File ./deploy.ps1 -UsersCsv ...` command line. Copy these examples to a
directory outside the repository (or under ignored `runtime/`) and replace
every placeholder.

## Users CSV

The only accepted header is the assignment brief's own example
(`docs/IRUO_Projekt_2025_2026-2.pdf`, page 3): `ime;prezime;rola`. UPN is
derived from the required `-UpnDomain <domain>` (`<slug>@<domain>`), SSH keys
are auto-generated under `keys/`, and `network_slot` is always deterministic.
See `config/users.example.csv`.

```powershell
pwsh -File scripts/Validate-AzureUsers.ps1 -Path config/users.example.csv -UpnDomain tenant.example
```

- `shared.example.tfvars` is the initial shared foundation input. Keep
  `app_gateway_enabled = false` until every tenant root has been applied.
  `allowed_ssh_cidr` defaults to `0.0.0.0/0` (CGNAT); narrow it here by hand
  if you have a stable source CIDR -- the one-shot `pwsh -File ./deploy.ps1 -UsersCsv`
  command has no such flag and always writes `0.0.0.0/0`.
- `tenant.example.tfvars` is one file per developer. Copy the non-secret
  `hub_network`, `identity`, and private DNS values from `terraform output -json`
  of the shared root, including `shared_values.jump_public_ip` and
  `shared_values.admin_username` for the generated Ansible `ProxyJump` hand-off.
- `shared-reconcile.example.tfvars` is a second, non-secret var file applied
  alongside the shared input after tenant outputs provide their VNet and app
  addresses.

Do not put MySQL, Moodle, Azure, storage, or private-key credentials in
these files. Terraform receives the two tenant passwords only from local
`TF_VAR_mysql_administrator_password` and `TF_VAR_moodle_database_password`
environment variables in the current secure shell session.
