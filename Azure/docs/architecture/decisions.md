# Element choices, load balancer comparison, and Azure/OpenStack comparison

This document exists to satisfy `docs/IRUO_Projekt_2025_2026-2.pdf`
(pages 2-5) rubric item **I1** ("Objašnjenje odabira elemenata... 7 bodova",
"Usporedba ponude Azure i OpenStack elemenata... 4 boda") and **I4**
("Implementirano i uspoređeno rješenje za Load Balancer... 2 boda"). The Azure implementation is maintained under `Azure/`; the corresponding OpenStack implementation and its current limitations are maintained under `OpenStack/`.

## Element choices (why each Azure service was picked)

| Element | Choice | Why |
| --- | --- | --- |
| Load balancer | Private-only Application Gateway `Standard_v2` | The brief needs the private frontend to route by **hostname** to the correct developer's backend pool (each developer gets `<slug>.moodle.test`) behind the single Jump-only-public-IP boundary. Only an L7 (HTTP) load balancer can do hostname-based routing; a plain L4 Azure Load Balancer cannot distinguish tenants by hostname on the same port, so a Standard Load Balancer per tenant (or a single shared one with no host routing) does not fit the "no direct public access to app VMs, one shared, hostname-routed frontend" shape. See the dedicated comparison below. |
| Object storage (Moodle-generated files and backup replica) | Azure Blob Storage (StorageV2, `LRS`, public access disabled) | The app identity mounts Blob with least privilege. A timer on `app01` replicates Moodle-generated course backups from the primary file-storage backup directory into Blob. This satisfies the brief's object-storage use without placing Moodle's concurrently-written POSIX dataroot on BlobFuse2. |
| File storage (shared dataroot and primary backups) | Azure Files Premium `FileStorage` LRS, NFSv4.1 | Azure Files provides the locking and atomic filesystem semantics required by a two-node Moodle dataroot. It also holds the primary automated-backup destination, matching the brief's explicit file-storage backup wording. |
| App VM type | One resolved VM SKU (`scripts/Resolve-AzureDeploymentProfile.ps1`): `Standard_B2s` (2 vCPU / 4 GiB) preferred where the active subscription/region actually offers it (hardware AND quota), `Standard_B2als_v2` (same x64/2 vCPU/4 GiB/zone-1+2 shape) as the assignment-compliant fallback when `Standard_B2s` is `NotAvailableForSubscription` or its own SKU-family quota cannot fit the 12-vCPU/6-VM fleet, `Standard_D2als_v6` (same shape, AMD-based "Dalsv6" family) as a further fallback when `Standard_B2als_v2`'s own family quota also cannot fit the fleet | Matches the brief's hardware requirement exactly (2 vCPU, 4 GB RAM) at the lowest-cost suitable VM tier for a `testing`-scope Moodle instance; resolved per subscription rather than hardcoded so a policy/SKU/quota-blocked subscription does not fail deployment (see "Regional adaptation" in `docs/architecture/README.md`). |
| Jump/Lead VM type | The **same** resolved VM SKU as the app tier (`var.vm_sku`, applied identically to Jump, Lead, `app01`, and `app02` -- `infra/azure/shared/main.tf`, `infra/azure/tenant/main.tf`) | Jump is a network appliance (NAT/SSH bastion) and Lead is an administration console (SSH client + Ansible); neither strictly needs the app tier's 4 GiB floor on its own, but the brief does not require a separate, smaller SKU for either, and resolving a single SKU for every host keeps the deployment-profile resolver simple (one approved-SKU list, one guardrail in `infra/azure/modules/compute`) instead of maintaining a second, independently-validated small-SKU candidate set purely to shave a few dollars off two VMs. |
| Disk type | `StandardSSD_LRS`, 32 GiB (OS) + 32 GiB (data), per app VM | Meets the brief's "two disks per app VM" requirement (OS disk + data disk) at the balanced cost/performance tier appropriate for testing; Premium SSD was not chosen because Moodle's actual live data lives on the shared NFS mount, not the local data disk, so the data disk does not need Premium IOPS. |
| Local data-disk SELinux labeling | Path-specific `httpd_sys_rw_content_t` mapping for `{{ moodle_local_mount }}(/.*)?`, recursively applied after the XFS mount | PHP-FPM runs in `httpd_t` and needs read/write access to Moodle's local cache/log tree; the persistent rule is limited to this local tree and does not alter Azure Files or Blob labels. |
| Database | One shared MySQL Flexible Server 8.4, `GP_Standard_D2ds_v4`, GeneralPurpose, ZoneRedundant (primary zone 1, standby zone 2), Private Access/VNet Integration | One HA server provides a fixed shared cost and one shared network path; each developer still receives a separate `moodle_<slug_with_underscores>` database, user, and grant. The trade-off is shared failure/blast radius and shared network reachability. The shared DNS link appears after reconciliation; the old tenant MySQL subnet remains reserved/unused. |
| Session/cache store | None (Moodle's own file-based default on the shared NFS `dataroot`) | Evaluated and rejected Azure Managed Redis: since `dataroot` is already the shared Azure Files NFS mount common to both app instances, Moodle's default file-based session and cache stores are already safely shared across `app01`/`app02` without an extra paid service. See "Load balancer vs Standard Load Balancer" below for why this matters (the App Gateway backend pool round-robins across both instances without cookie affinity, so session sharing has to actually work, not just be assumed). |

## Load balancer: Application Gateway vs Azure Load Balancer (Standard)

Both were evaluated for exposing the two Moodle app instances behind the
Jump-only-public-IP boundary.

| | **Application Gateway `Standard_v2`** (chosen) | Azure Load Balancer `Standard` |
| --- | --- | --- |
| OSI layer | L7 (HTTP/HTTPS) | L4 (TCP/UDP) |
| Hostname-based routing | Yes -- one listener + routing rule per developer hostname (`<slug>.moodle.test`) on a single shared gateway | No -- an L4 LB cannot inspect the HTTP `Host` header, so it cannot route different developers' traffic differently on the same port without one LB per developer |
| Health probing | Application-level, dependency-aware (`GET /readyz`, expects `200-399`; Ansible first verifies all three exact mountpoints with root-level `findmnt --mountpoint` and writes a deployment-bound marker inside each mounted filesystem, then the endpoint verifies those readable markers, opens a real TLS connection to MySQL, and runs `SELECT 1`, returning 503 -- outside the match range -- when any dependency fails). A separate static `/healthz` exists only for process-liveness checks (`ansible/roles/healthcheck`), never for Application Gateway routing, because it cannot detect a backend that is up but actually broken. PHP does not read `/proc/self/mountinfo`; the local XFS tree is persistently labeled only with `httpd_sys_rw_content_t`, while NFS/Blob labels are untouched. | TCP/HTTP(S) probe, coarser (reachability only, not app-level "ready") |
| Session affinity | Configurable (cookie-based); this deployment leaves it **disabled**, so both `app01`/`app02` serve real round-robin traffic, not active/passive failover -- this is why the shared-NFS session-store finding above matters | N/A (L4, connection-level distribution only) |
| Monthly cost (West Europe, see `docs/costs/README.md`) | ≈$195.64/month fixed + capacity units, **regardless of developer count** (shared, amortized) | A Standard LB itself has no fixed hourly charge (only per-rule + data-processed charges), materially cheaper |
| Fits the brief | Yes -- single shared frontend, hostname routing to per-developer backend pools, no direct public access to app VMs | Would need either one LB per developer (defeats "single Jump-only public IP" simplicity) or no host-based separation at all |

**Conclusion:** Application Gateway is the correct choice for the hostname-routing
requirement despite its materially higher fixed cost; a Standard Load Balancer
was rejected because it cannot distinguish developers by hostname on a shared
frontend. This is the direct trade-off documented for I4's "implemented and
compared" rubric item.

## Azure vs OpenStack element comparison

This table records the Azure design and the corresponding implementation now maintained under `OpenStack/` (see `AGENTS.md`).

| Element | Azure (implemented here) | OpenStack equivalent |
| --- | --- | --- |
| Compute | Azure VM (one resolved SKU: `Standard_B2s` preferred, `Standard_B2als_v2` then `Standard_D2als_v6` quota-aware fallbacks -- see the element-choices table above), Rocky Linux 10 marketplace image | Nova instance, Rocky Linux 10 Glance image |
| Object storage | Blob Storage (StorageV2, UAMI-authenticated) | Swift container, Keystone-scoped credentials |
| Application data storage | Azure Files Premium NFSv4.1 | Five local Cinder volumes per developer: a DB disk, `/dev/vdb` for local cache/temp on each app, and `/dev/vdc` for the local Moodle data directory on each app; no shared data directory |
| Block storage | Managed Disk (`StandardSSD_LRS`) | Cinder volume |
| Load balancing | Application Gateway `Standard_v2` (L7) | Two shared private HAProxy/Keepalived VMs with one isolated VIP and backend per developer |
| Network isolation | VNet per developer + NSG/ASG + hub-spoke peering + UDR blackhole routes | Neutron project network per developer + security groups; router isolation via separate Neutron routers/projects |
| Identity/IAM | Microsoft Entra ID groups + Azure RBAC custom role, scoped per Resource Group | Keystone projects/domains + custom Keystone roles, scoped per project |
| Bastion/jump access | Dedicated Jump VM (NAT + forced-command SSH tunnels) | Equivalent pattern: a dedicated bastion instance, or Nova's `console-log`/`console-url` combined with a floating-IP-only bastion |
| Tenant isolation boundary | Resource Group + VNet per developer | Project (tenant) + network per developer |

Both platforms can satisfy every requirement in the brief; Azure's managed
PaaS services (Application Gateway, Managed Disks, Blob/Files, Managed
Identity/RBAC) require less operational code than the equivalent
self-managed OpenStack services (HAProxy/Keepalived, Cinder, Swift, Keystone),
at the cost of being tied to one cloud provider -- exactly the trade-off
TechSprint's brief frames as "testing providers" (`multi-cloud` section,
page 2).
