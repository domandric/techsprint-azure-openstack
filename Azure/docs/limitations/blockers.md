# Known limitations

| Area | What to resolve before use |
| --- | --- |
| Local tools and access | Install PowerShell 7.4+, Terraform, the required Az modules and Ansible. Select the intended subscription and tenant before running anything. |
| Azure registration and capacity | Required providers must already be registered. `scripts/Resolve-AzureDeploymentProfile.ps1` automatically checks region/SKU capacity (VM SKU restrictions, zones 1/2, SKU-family + regional vCPU quota via `Get-AzVMUsage`, resource-provider regional support, best-effort policy assignments) across an ordered candidate region set (`westeurope`, then `swedencentral`) and resolves whichever actually works for the active subscription -- see `docs/architecture/README.md`'s "Regional adaptation". The tooling never registers a provider, changes quota, or requests a quota increase. |
| Region/SKU blocked entirely for a subscription | Some subscriptions (notably free-trial subscriptions) block an entire region via management-group policy (`RequestDisallowedByAzure: selected region is currently not accepting new customers`) and/or restrict `Standard_B2s`/`Standard_B1ms`/`Standard_D2s_v3` per subscription, or cap a SKU family's own vCPU quota below this project's 12-vCPU (6-VM) fleet requirement even though the SKU itself is otherwise unrestricted. The resolver above handles this automatically by falling back through Sweden Central + `Standard_B2als_v2`, then `Standard_D2als_v6`, whichever's own hardware AND quota actually fit; if every candidate region/SKU combination in the ordered set is also blocked/quota-insufficient, rerun after requesting access to a suitable region/SKU/quota; the one-shot command fails closed rather than bypassing its quota-aware profile resolver. Switching an already-deployed subscription to a different quota-driven SKU requires a full `-DestroyAll` first -- see "Regional adaptation" for the exact persisted-profile-removal sequencing. |
| Leftover empty West Europe state resource group | A prior failed bootstrap attempt in West Europe (before this resolver existed, or before an operator discovered West Europe was blocked) may have left an empty, canonical-tagged `rg-ts-state-testing-weu` resource group behind. `Deploy-Azure.ps1` detects this read-only and prints a one-time, non-blocking `NOTICE` with the exact cleanup command; it is never removed automatically, never mistaken for the resolved region's own backend, and never touched by `-DestroyAll`. |
| Manually deleted resource groups after a failed `-DestroyAll` | If an operator manually deletes every project resource group outside Terraform (for example to recover from an earlier `-DestroyAll` failure), the local `bootstrap/backend.hcl` and the subscription-scoped `TechSprint VM Power Operator` custom role can both be left orphaned -- neither lives inside a resource group. `-DestroyAll` now recovers the former automatically (only once Preflight conclusively proves the Azure-side backend still matches the exact expected identity; never repairs Azure itself) and discovers/fingerprint-verifies/removes the latter as its own phase, in both cases regardless of whether any project resource group or the state backend still exists -- see `docs/architecture/README.md`'s "Recovering from a manual/partial resource-group deletion" and the operations runbook's "Full teardown" section. |
| Directory and role changes | Shared custom-role and Entra group/membership work needs the appropriate explicit approval and permissions. |
| Public IP inventory | There must be no unrelated public IP competing with the single Jump public IP rule. |
| MySQL Private Access/VNet Integration | One shared `GP_Standard_D2ds_v4` GeneralPurpose ZoneRedundant server uses the delegated hub subnet `10.10.3.0/24` and shared private DNS. Each developer has a separate database/user/grant. The DNS link to tenant spokes appears after shared reconciliation. It has not been exercised against a live Azure subscription from this repository/agent, which has no Azure credentials and must not run `terraform apply`; verify it end-to-end before relying on it. |
| Blob/Files DNS staleness for a brand-new tenant | A tenant's Blob/Files private endpoints write their DNS records into the *shared* zones at tenant-apply time, but those zones are linked to the new tenant's own VNet only by the post-tenant shared reconciliation apply. Resolution from the tenant's app VMs is complete only after shared reconciliation reports `PASS`. |
| Tenant isolation staleness | Onboarding a developer changes `known_developers`, which every *other* already-applied tenant's foreign-spoke deny-NSG/blackhole-UDR rules and the shared hub's peering/private-DNS depend on. Run `Reconcile` (below) and treat onboarding as incomplete until it reports PASS. |

## MySQL Flexible Server: Private Access/VNet Integration

**Status: TESTING-ONLY, not yet live-validated.** This design is deterministic
by construction (see below), but the actual Azure Resource Manager behavior
has never been run against a live subscription from this repository/agent
(see "What remains unverified" below). Treat it as safe to plan/inspect and
safe to `testing`-scope experiment with once an operator supplies real
credentials and reviews each plan; do not describe it as production-verified
until that live run has happened.

A Private Endpoint was considered and rejected: Azure Database for MySQL
Flexible Server only allows attaching one to a server *already* created with
public network access enabled (see
[Azure Database for MySQL private-link networking](https://learn.microsoft.com/en-us/azure/mysql/flexible-server/concepts-networking-private-link)),
which would force a two-phase bootstrap-then-converge apply sequence just to
reach a public-access-disabled final state.

Azure Database for MySQL Flexible Server's **Private Access (VNet
Integration)** is a different, simpler mechanism: the server joins a subnet
that is exclusively delegated to `Microsoft.DBforMySQL/flexibleServers`
(`infra/azure/modules/network`'s shared `snet-mysql-shared` at
`10.10.3.0/24`) and resolves through a private
DNS zone that must already be linked to that VNet *before* the server is
created -- but, unlike Private Link, there is no "must start with public
access enabled" requirement at all. `infra/azure/modules/paas` therefore:

1. creates one shared `privatelink.mysql.database.azure.com` private DNS zone
   and links it to the hub (tenant links follow reconciliation);
2. creates one shared MySQL Flexible Server with `delegated_subnet_id`,
   `private_dns_zone_id`, and `public_network_access = "Disabled"` all set
   from the very first `create`, `depends_on` the zone-VNet link above so the
   ordering requirement is met inside this one apply; and
3. uses the fixed `GP_Standard_D2ds_v4` GeneralPurpose ZoneRedundant SKU,
   primary zone 1 and standby zone 2, with one database per developer. This is
   intentionally one shared failure/blast-radius and network-reachability
   boundary in exchange for one fixed HA server cost.

Because the shared zone, hub link, and server are created in the shared apply,
the tenant roots only consume the shared contract and create their own app
environment. Tenant DNS links and Application Gateway records appear during
the post-tenant shared reconciliation. There is no MySQL network-stage flag or
plan-shape inspection step in `scripts/Invoke-Azure.ps1`.

**What remains unverified:** the exact behavior of the live Azure Resource
Manager API for creating a MySQL Flexible Server with `delegated_subnet_id`,
`private_dns_zone_id`, and `public_network_access = "Disabled"` all set from
creation, against a zone/VNet link created moments earlier in the same apply,
has not been run against a real subscription. This environment has no Azure
credentials and must not run `terraform apply`. Run a real tenant apply in a
`testing`-scope subscription and confirm the server reaches `Ready`, DNS
resolves the server's FQDN from an app VM in the same VNet, and no public
endpoint is ever reachable, before treating this as production-ready.

## Tenant isolation reconciliation

Each tenant keeps a separate Terraform state (`tenants/<slug>.tfstate`);
`infra/azure/modules/network`'s per-tenant `deny-<foreign-slug>` NSG rules and
`blackhole-<foreign-slug>` routes are generated from that tenant's own
`known_developers` input at its *last* apply. Adding a developer updates
`known_developers`, but only the new tenant's own first apply automatically
reflects the full updated roster (it denies/blackholes every existing peer).
Every already-applied tenant keeps denying/blackholing only the peers it knew
about at its own last apply -- it does not automatically pick up the new
tenant. The catch-all NSG deny rule (priority 4096) still blocks inbound
traffic from an unlisted new tenant, but the missing blackhole route leaves
that stale tenant's *outbound* traffic to the new tenant's spoke CIDR
following the default route to the hub NVA instead of being explicitly
blackholed -- a real defense-in-depth gap, not merely a cosmetic one.

`scripts/Invoke-Azure.ps1 -Command Reconcile -VarFile <shared.tfvars>
[-VarFile <shared-reconcile.tfvars>] -TenantVarFileDirectory
<dir-of-one-tfvars-per-known-developer>` is a read-only, plan-only
(`terraform plan -detailed-exitcode`) check across the shared root and every
tenant `.tfvars` file in that directory. `-VarFile` accepts more than one
file so the same base `shared.tfvars` used for the initial foundation can be
combined with the non-secret `shared-reconcile.tfvars`
(`app_gateway_enabled = true` plus `tenant_networks`/`tenant_backends`) for a
post-tenant convergence check -- see `config/README.md` and the runbook.

Before planning anything, Reconcile fails closed on an incomplete or
inconsistent tenant directory: it asks the already-initialized shared root
itself to evaluate `var.users.developers` from the exact supplied shared var
file(s) through `terraform console` (read-only; never writes to the backend;
only the non-secret slug list is read, never plan/state content), and
requires `TenantVarFileDirectory` to contain exactly one `<slug>.tfvars` per
slug in that list -- no missing slug, no extra file, no duplicate. This is
deliberately more robust than trusting whichever `*.tfvars` files happen to
be present.

Only once that completeness check passes does Reconcile plan the shared root
and every tenant file. It fails closed: `BLOCKED` if any root has a pending
Terraform change (stale), `FAIL` if any root cannot even be planned. Treat
onboarding a new developer as complete only once Reconcile reports `PASS`,
meaning the shared root and every existing tenant have already been
re-planned and re-applied with the updated `known_developers` map. See the
runbook's onboarding section for the full command, including how the two
sensitive tenant passwords are supplied per tenant through
`-TenantSecretsCommand` (or an operator-exported equivalent) without ever
being written to disk or logged.

## NFS boundary

Azure Files uses private networking and `AUTH_SYS` UID/GID values, not the
Microsoft Entra SMB path. Every tenant has a separate Files account and private
endpoint, so private DNS, spoke routing and NSGs must stop one tenant from
reaching another tenant's endpoint.

The app role refuses to mount if the Files hostname does not resolve to RFC1918
space or TCP/2049 is unavailable. The native `nfs-utils` mount does not use the
AZNFS encryption-in-transit helper; the Files-only account has Secure transfer
disabled as a deliberate private-network tradeoff. It is not TLS-protected NFS
traffic. SMB, CIFS, Kerberos, storage keys and SAS are not fallbacks.

## First Ansible connection

Terraform inventory is incomplete until every tenant apply has produced its
`20-<slug>.yml` fragment and shared reconciliation has produced
`runtime/ansible/inventory/00-shared.yml`, after which the orchestrator exports `ansible/inventories/production/hosts.yml`. This is an environment/order
blocker, not a reason to create a hand-written inventory.

Use that generated directory with a private key held in gitignored
repository-local paths. SSH host-key verification is disabled by default
(`StrictHostKeyChecking=no`, `UserKnownHostsFile=/dev/null`) for this lab's
convenience, so there is no first-connection trust step or `known_hosts` file
to manage.
