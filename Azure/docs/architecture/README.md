# Azure architecture and RBAC

The diagrams are Mermaid text so the topology stays readable without embedding
screenshots or runtime values.

- [Network and service topology](azure-architecture.mmd)
- [Entra/RBAC and workload identity topology](rbac.mmd)
- [Video arhitektura na hrvatskom — pregled, izvor](azure-architecture-video-hr.mmd)
- [Video arhitektura na hrvatskom — pregled, prezentacijski SVG](azure-architecture-video-hr.svg)
- [Video arhitektura na hrvatskom — pregled, PNG fallback](azure-architecture-video-hr.png)
- [Video arhitektura na hrvatskom — detalj developerskog okruženja, izvor](azure-developer-environment-video-hr.mmd)
- [Video arhitektura na hrvatskom — detalj developerskog okruženja, prezentacijski SVG](azure-developer-environment-video-hr.svg)
- [Video arhitektura na hrvatskom — detalj developerskog okruženja, PNG fallback](azure-developer-environment-video-hr.png)
- [Element choices, Load Balancer comparison, and Azure/OpenStack comparison](decisions.md)

Za snimanje najprije otvorite [pregledni SVG](azure-architecture-video-hr.svg), a
zatim [detaljni SVG](azure-developer-environment-video-hr.svg) u pregledniku.
Ako recorder ili preglednik ne podržava SVG tekst, koristite [pregledni PNG](azure-architecture-video-hr.png)
i [detaljni PNG](azure-developer-environment-video-hr.png); PNG je preporučeni
fallback jer sadrži već rasterizirane vidljive oznake.
Za svaki uključite cijeli zaslon (`F11` na uobičajenoj Linux tipkovnici; u
izborniku preglednika odaberite **Fullscreen** ako `F11` nije mapiran). Po
potrebi povećajte zum preglednika, ali zadržite cijeli dijagram u kadru.
Izvorni Mermaid služi za izmjene i ponovno renderiranje; SVG-ovi su samostalni
i ne ovise o runtime inventaru ili cloud podacima.

Render locally only when Mermaid CLI is already available. Izvori koriste
`htmlLabels: false`, pa se oznake renderiraju kao native SVG tekst bez
`foreignObject` elemenata; nakon renderiranja provjerite i PNG fallback:

```bash
mmdc -i docs/architecture/azure-architecture.mmd -o /tmp/azure-architecture.svg
mmdc -i docs/architecture/rbac.mmd -o /tmp/azure-rbac.svg
mmdc -i docs/architecture/azure-architecture-video-hr.mmd -o /tmp/azure-video-overview.svg -w 1920 -H 1080
mmdc -i docs/architecture/azure-developer-environment-video-hr.mmd -o /tmp/azure-video-detail.svg -w 1920 -H 1080
```

## Resource groups and state

| Scope | Resource group / state key | Contents |
| --- | --- | --- |
| State | `rg-ts-state-testing-<location-short>` / backend configuration | State storage account and container, created by PowerShell before Terraform |
| Shared | `rg-ts-shared-testing-<location-short>` / `shared.tfstate` | Hub, Jump, lead, one public IP, shared MySQL, private Application Gateway and shared DNS |
| Developer `<slug>` | `rg-ts-<slug>-testing-<location-short>` / `tenants/<slug>.tfstate` | Isolated spoke, app VMs, UAMI, Blob, Files and private endpoints; one database/user/grant on the shared MySQL server |

`<location-short>` is resolved per subscription (see "Regional adaptation"
below); it is `weu` for West Europe and `swc` for Sweden Central. All
resource groups are siblings in the TechSprint testing subscription.

## Naming convention

Every resource name is generated deterministically by
`infra/azure/modules/naming` from `name_seed` (a stable, non-secret,
operator-chosen value) and the developer's slug -- never hand-typed, so the
same inputs always produce the same names (I1's "documented and applied
naming convention" rubric item). The pattern is
`<kind>-ts-<scope-or-slug>-testing-<location-short>`, where `ts` is the
fixed TechSprint project abbreviation, `testing` is the fixed environment,
and `<location-short>` is auto-derived from the resolved Azure region
(`westeurope=>weu`, `swedencentral=>swc`; see "Regional adaptation" below)
-- never a single region-agnostic constant, so no resource is ever placed in
a different region while retaining a misleading `weu` suffix:

| Kind | Pattern | Example (West Europe) | Example (Sweden Central) |
| --- | --- | --- | --- |
| Resource group | `rg-ts-<slug\|shared\|state>-testing-<location-short>` | `rg-ts-luka-lukic-testing-weu` | `rg-ts-luka-lukic-testing-swc` |
| Virtual network | `vnet-ts-<slug\|hub>-testing-<location-short>` | `vnet-ts-luka-lukic-testing-weu` | `vnet-ts-luka-lukic-testing-swc` |
| VM | `vm-ts-<slug>-<role>-testing-<location-short>` | `vm-ts-luka-lukic-app01-testing-weu` | `vm-ts-luka-lukic-app01-testing-swc` |
| Application Gateway | `agw-ts-shared-testing-<location-short>` | (one, shared) | (one, shared) |
| MySQL Flexible Server | `mysql-ts-shared-<hash>` | `mysql-ts-shared-a1b2` | `mysql-ts-shared-a1b2` (location-independent) |
| Storage account (Blob/Files) | `stts<slug-compact><b\|f><hash>` | `sttslukalukicb1a2c` (Storage account names cannot contain hyphens; the 4-hex-character `<hash>` is `sha256(name_seed:slug:kind)`, so a name collision between two developers or a name guess by a third party is not feasible without knowing `name_seed`. Also location-independent.) | |
| Entra security group | `grp-ts-dev-<slug>` / `grp-ts-devops-leads` | `grp-ts-dev-luka-lukic` | `grp-ts-dev-luka-lukic` (location-independent) |

## Regional adaptation

`docs/IRUO_Projekt_2025_2026-2.pdf` does not pin a specific Azure region or
VM SKU; AGENTS.md's earlier "frozen" West Europe/`Standard_B2s` assumption
was a reasonable *default*, not a brief requirement, and does not hold for
every subscription. Some subscriptions (notably free-trial subscriptions)
block an entire region via a management-group policy assignment, or
restrict individual VM SKUs per subscription, independently of this
repository's own defaults.

`scripts/Resolve-AzureDeploymentProfile.ps1` is a dedicated, read-only,
quota-aware resolver/preflight, dot-sourced by `scripts/Deploy-Azure.ps1`,
that chooses a deployment profile (region, its short-name suffix, and one VM
SKU applied consistently to Jump, Lead, and both app hosts) from a
conservative ordered candidate set (`westeurope`, then `swedencentral`),
using the active subscription's own real, read-only signals:

- **SKU restrictions/capabilities**: `Get-AzComputeResourceSku` per
  candidate region, requiring an x64 VM SKU with at least 2 vCPU, at least
  4 GiB RAM, both Availability Zones 1 and 2 present, and no
  `NotAvailableForSubscription`-class restriction.
- **SKU-family and regional vCPU quota**: `Get-AzVMUsage` per candidate
  region (read-only quota/usage listing; never a quota increase request),
  requiring BOTH the region's own total "Total Regional vCPUs" (`cores`)
  quota AND that SKU's own family quota (e.g. `standardBasv2Family`,
  `standardDalv6Family` -- `Get-AzComputeResourceSku`'s own `.Family`) to
  have at least 12 vCPUs of headroom -- this project's full verification fleet
  (Jump, Lead, plus `app01` and `app02` for each of two developers, each 2
  vCPU on the one uniform resolved SKU). A
  SKU can be individually hardware-approved and otherwise unrestricted yet
  still be rejected here if its own family quota cannot fit the whole
  fleet. Quota data that cannot be established at all (a missing usage
  entry, an unparsable value, a missing `.Family`) fails closed -- rejected,
  never assumed unlimited.
  `Standard_B2s` (the brief's own literal example) is preferred;
  `Standard_B2als_v2` (the same hardware shape) is the assignment-compliant
  fallback when `Standard_B2s` is restricted or its own quota is
  insufficient; `Standard_D2als_v6` (the same x64/2 vCPU/4 GiB/zone-1+2
  shape, AMD-based "Dalsv6" family) is a further assignment-compliant
  fallback when `Standard_B2als_v2` is itself unrestricted but its own
  family quota also cannot fit the fleet. `Standard_B2ats_v2` (only 1 GiB
  RAM) is never selected -- hard-excluded by name regardless of its own
  reported capabilities.
- **Resource-provider regional support**: `Get-AzResourceProvider`
  (read-only registration-state and per-resource-type location check;
  never registers anything).
- **Management-group/subscription policy** (best-effort):
  `Get-AzPolicyAssignment`/`Get-AzPolicyDefinition`, recognizing common
  region-restriction rule shapes (`field: location` combined with
  `equals`/`in`/`notIn` and `effect: deny`, including parameterized
  effects and `allOf`/`anyOf` wrapping) so a region an operator-visible
  Deny policy already blocks is never auto-selected in the first place.
- **Rocky Linux 10 image availability** in the candidate region (reusing
  `Resolve-DeployRockyImageVersion`).

This command **never** registers a resource provider or feature, accepts
Marketplace terms, requests a quota increase, or probes by creating a real
resource -- every check above is read-only.

For the free-trial subscription this repository was verified against:
West Europe is blocked entirely by a management-group policy assignment
(`sys.blockwesteurope`, effect Deny; Azure error `RequestDisallowedByAzure:
selected region is currently not accepting new customers`), and
`Standard_B2s`/`Standard_B1ms`/`Standard_D2s_v3` are
`NotAvailableForSubscription`. Sweden Central's `Standard_B2als_v2` was
initially hardware-unrestricted (x64, 2 vCPU, 4 GiB, zones 1/2/3,
`PremiumIO=true`) and was deployed there first -- but that subscription's own
`standardBasv2Family` vCPU quota (`Get-AzVMUsage`) has only a 4-vCPU family
limit, which can never fit this project's 12-vCPU (6-VM) fleet regardless of
current usage. The resolver's quota check now correctly rejects
`Standard_B2als_v2` for that reason and falls through to **`Standard_D2als_v6`**
(same x64/2 vCPU/4 GiB/zone-1+2 shape; `standardDalv6Family` quota raised
to at least 12 vCPUs) -- another runtime-compatible substitution forced by subscription
quota, not an architecture change: still the same 2 vCPU / 4 GiB / x64 /
zone-1+2 shape the brief requires, applied consistently to Jump, Lead, and each developer's
`app01` and `app02`. MySQL is one shared `GP_Standard_D2ds_v4` server (a
different service/SKU namespace from the VM resolver), so its fixed HA/SKU
choice is independent of VM quota resolution.

Switching an already-deployed subscription from `Standard_B2als_v2` to
`Standard_D2als_v6` requires a full `-DestroyAll` first (Terraform cannot
resize a running VM's SKU family in place inside this project's guardrails):
`-DestroyAll` always reuses the exact persisted profile (including its old
VM SKU) to safely tear down what was actually deployed, and only once that
teardown's own backend retirement fully succeeds does
`scripts/Deploy-Azure.ps1` remove the persisted
`runtime/state/deployment-profile.json` record, so the next normal deploy
re-runs this resolution from scratch and picks up the new quota-driven SKU.
A partial or failed `-DestroyAll` never clears that record, so a retry keeps
targeting the correct, already-deployed profile.

The resolved profile (location, location_short_name, VM SKU, and the exact
Rocky Linux 10 image reference) is persisted, non-secret and context-bound
(subscription + tenant), at `runtime/state/deployment-profile.json`
(git-ignored). A same-context rerun -- including `-DestroyAll` -- always
reuses exactly the persisted profile rather than re-resolving or silently
drifting; a persisted record that belongs to a different subscription/tenant fails
closed instead of being silently reused (mirroring the
`runtime/state/name-seed.json` context binding). The one-shot interface takes no location/SKU
parameters: `pwsh -File ./deploy.ps1 -UsersCsv ../config/users.csv` auto-selects and
prints the resolved profile before the pre-mutation confirmation.

### Recovering from a manual/partial resource-group deletion

Every resource this project creates lives inside one of the resource groups
above, with one deliberate exception: `infra/azure/shared/main.tf`'s
`azurerm_role_definition.vm_power_operator` (`TechSprint VM Power
Operator`) is a **subscription-scoped** custom role, not resource-group
scoped -- deleting every project resource group by hand (for example after
a failed `-DestroyAll` an operator resolves by deleting resource groups
directly, out of band) does nothing to it, and that manual deletion also
removes the Terraform state backend that would otherwise still know the
role exists. Two changes close this gap:

- **Deterministic role identity.** `azurerm_role_definition.vm_power_operator`
  now pins `role_definition_id` to one fixed literal GUID (Terraform
  provider support: `azurerm_role_definition`'s own optional
  `role_definition_id` argument), instead of leaving it provider-generated.
  Every future bootstrap of this project's own role -- across every
  create/destroy/re-bootstrap cycle -- therefore shares the exact same ARM
  resource ID. Changing this value forces Terraform to replace the role
  (a new create + delete, never renamed in place); it must only ever be
  changed together with a full, approved `-DestroyAll` of the old role
  first.
- **Out-of-band discovery and cleanup.** `scripts/Deploy-Azure.ps1`'s
  `-DestroyAll` independently discovers, fingerprint-verifies, and (only
  after the same typed `AZURE-DESTROY-ALL` confirmation as everything
  else) removes this one role, regardless of whether the state backend or
  any canonical project resource group still exists -- see the "out-of-band
  project custom role" section of the
  [operations runbook](../operations/runbook.md) for the exact ownership
  proof, refusal rules, and phase ordering. Ownership is proven by a full
  fingerprint match (name, description, `IsCustom`, the single subscription
  assignable scope, and the exact permission sets) rather than by name or
  ID alone, so the one already-deployed legacy role that predates the
  `role_definition_id` pin above (its own ID is provider-generated) is
  still safely recognized and removable.

`bootstrap/backend.hcl` -- the one piece of local, non-secret backend
metadata this repository ever writes -- has the same "survives a partial
manual cleanup, but not the local file" asymmetry in reverse: the Azure-side
state backend (resource group, storage account, container) can outlive a
lost/never-committed local `bootstrap/backend.hcl` (a fresh clone, a
different `-WorkDir`, or simple accidental deletion). `-DestroyAll` recovers
this file itself, automatically, immediately after its own read-only
Preflight check -- but only once Preflight *conclusively* proves (exit code
0 and a relayed `"status": "PASS"`) every Azure-side backend component
already exists with the exact canonical identity this checkout
independently computes. It never creates or repairs anything in Azure to do
this, and an existing file whose content does not match that exact identity
is never silently overwritten -- `-DestroyAll` fails closed instead.

Every *taggable* Azure resource also carries the mandatory tags
`project = techsprint` and `environment = testing`
(`infra/azure/modules/naming`'s `locals.tags`, applied by every module),
plus `owner` (the developer slug, or `shared`) and `scope`, satisfying I1's
"all resources tagged" rubric item without relying on a human to remember to
tag anything -- tags are generated alongside every name from the same
module. A small number of resource *types* Azure/Entra does not support
tagging on at all (for example `azurerm_role_definition`, Entra ID
groups/users, and association/child objects like
`azurerm_mysql_flexible_database`) are the only exceptions, not a gap in
applying the convention.

## Address plan

| Network component | CIDR or address |
| --- | --- |
| Hub VNet | `10.10.0.0/16` |
| Jump subnet / VM | `10.10.0.0/24` / `10.10.0.10` |
| Lead subnet / VM | `10.10.1.0/24` / `10.10.1.10` |
| Application Gateway subnet / private frontend | `10.10.2.0/24` / `10.10.2.10` |
| Developer spoke | `10.20.(network_slot*4).0/22` |
| Developer app subnet | `10.20.(network_slot*4).0/24` |
| Developer private-endpoint subnet (Blob, Files) | `10.20.(network_slot*4+1).0/24` |
| Shared MySQL delegated subnet (`snet-mysql-shared`, `Microsoft.DBforMySQL/flexibleServers`) | `10.10.3.0/24` |
| Reserved legacy tenant MySQL subnet (`snet-mysql`, unused) | `10.20.(network_slot*4+2).0/24` |

## Important choices

These choices are deliberately scoped to what `docs/IRUO_Projekt_2025_2026-2.pdf`
(pages 2-5, the authoritative assignment brief) actually requires for a
`testing`-scope deployment of 2 developers + 1 lead, not a larger production
posture. See `docs/costs/README.md` for the priced trade-offs.

- Every VM uses Rocky Linux 10. `app01` is in zone 1 and `app02` is in zone
  2, both on the resolved deployment profile's VM SKU (2 vCPU / 4 GiB each,
  matching the brief's hardware requirement) -- `Standard_B2s` where the
  active subscription actually offers it (hardware and quota),
  `Standard_B2als_v2` then `Standard_D2als_v6` as quota-aware,
  assignment-compliant fallbacks otherwise; see "Regional adaptation" above.
- MySQL is one shared MySQL Flexible Server 8.4, `GP_Standard_D2ds_v4`,
  GeneralPurpose, ZoneRedundant with primary zone 1 and standby zone 2. It
  uses Private Access over the dedicated hub subnet `10.10.3.0/24`; each
  developer gets one `moodle_<slug_with_underscores>` database and its own
  Moodle user and grant. This reduces fixed cost to one HA server but makes
  database failure and reachability a shared developer blast radius. The old
  tenant `snet-mysql` delegation remains reserved/unused for migration
  compatibility and is not referenced by the server, DNS zone, or databases.
  The shared private DNS link appears after shared reconciliation.
- No Azure Managed Redis: it was evaluated and is not required. Moodle's
  `dataroot` (moodledata, including its default file-based session and cache
  stores) already lives on the Azure Files NFS share mounted on both app
  instances, which is Moodle's own documented supported pattern for a
  multi-web-server deployment -- adding Redis would be an extra paid
  resource with no functional benefit here.
- Azure Files is Premium `FileStorage` LRS NFSv4.1 with `AUTH_SYS` over a
  private endpoint on TCP/2049. It holds the shared `moodledata` and Moodle's
  primary automated course-backup destination. Blob is a separate
  UAMI/BlobFuse2 mount; an `app01` timer replicates those Moodle-generated
  backup files into Blob. This follows the brief's file-storage backup wording
  while avoiding the unsafe use of object FUSE for Moodle's concurrently
  written POSIX dataroot. Both storage services are mounted on both apps and
  are genuinely used. Azure Files' 100 GiB size is the platform minimum for
  Premium NFS, not an arbitrary upsize.
- The native NFS choice does not use AZNFS encryption in transit. The Files
  account is private-endpoint-only but its NFS transport is not TLS-protected.
