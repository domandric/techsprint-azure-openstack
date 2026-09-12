# Azure security controls

## Network

- The only public IP belongs to the Jump VM. Jump SSH accepts Internet IPv4 by default (`allowed_ssh_cidr = 0.0.0.0/0`) so it works behind CGNAT and changing client addresses. Azure VM provisioning disables password authentication from first boot; Ansible also disables keyboard-interactive/root login and installs Fail2ban with incremental nftables bans for recurring SSH offenders. Operators with a stable source CIDR may optionally narrow `allowed_ssh_cidr`.
- Moodle has no public frontend. A private-only `Standard_v2` Application
  Gateway serves tenant hostnames under `moodle.test`.
- Developer spokes are isolated. Peering, routes and NSGs preserve Jump
  administration/SNAT without creating spoke-to-spoke access. Each tenant's
  foreign-spoke deny-NSG/blackhole-UDR rules are generated from that tenant's
  own `known_developers` input at its last apply, so adding a developer
  requires re-planning/re-applying every already-existing tenant (and the
  shared root) before onboarding is complete; run
  `scripts/Invoke-Azure.ps1 -Command Reconcile` and require `PASS`. See
  `docs/limitations/blockers.md`.
- The Lead reaches every app VM's SSH port **directly** over the hub-spoke
  VNet peering (`allow_virtual_network_access = true` on both peering
  legs), not through the Jump NVA's IP-forwarding/NAT path: each tenant's
  app NSG explicitly allows the Lead's private IP (`10.10.1.10/32`) on port
  22 (`infra/azure/modules/network/main.tf`'s `tenant_ssh_from_lead` rule).
  Jump's own NAT/forward chain (`ansible/roles/jump`) is used only for the
  app subnet's own outbound-to-Internet default route, not for Lead-to-app
  traffic, which never transits Jump. Developers, by contrast, only ever
  reach their own app hosts through Jump's restricted, forced-command SSH
  tunnel accounts (`ansible/roles/jump`), never directly.
- MySQL, Azure Files and Blob all use private networking and private DNS,
  and their public data paths stay disabled after provisioning. MySQL
  Flexible Server uses Private Access (VNet Integration) through a dedicated
  delegated subnet (`snet-mysql`), not a Private Endpoint:
  `public_network_access` is `Disabled` from the very first apply, with no
  bootstrap window and no second, tooling-enforced apply required. Azure
  Files and Blob are each reached through an ordinary Private Endpoint
  instead, since only MySQL Flexible Server supports VNet Integration. See
  `docs/limitations/blockers.md`. There is no Azure Managed Redis anywhere in
  this deployment -- see `docs/architecture/README.md` for why it was
  evaluated and not used.

## SELinux and the local Moodle tree

- The XFS data disk mounted at `/srv/moodle-local` (the value of
  `moodle_local_mount`) has a persistent, path-specific
  `httpd_sys_rw_content_t` file-context rule for `(/.*)?`. The disk role runs
  recursive `restorecon` after mounting and verifies both `matchpathcon` and
  the actual mount-root context; an existing readiness marker is checked when
  present. This permits the enforcing `httpd_t` PHP-FPM domain to read and
  write Moodle's local cache/log paths without weakening readiness.
- This fix is deliberately least-scoped to the local XFS tree. It does not
  relabel or apply the local rule to Azure Files NFS or BlobFuse mounts, and it
  does not use `audit2allow` or permissive mode. The live AVC that motivated
  the fix was `httpd_t` denied `getattr` on
  `/srv/moodle-local/.techsprint-mount-ready` while it had `var_t`; a live
  rerun is still required to verify the source fix and `/readyz` recovery.

## Azure Files NFS

The Moodle file area is an Azure Files Premium `FileStorage` LRS NFSv4.1 share
behind a tenant-private endpoint. App hosts mount it with native `nfs-utils`
over TCP/2049 using `AUTH_SYS` (`sec=sys`), not SMB.

There is no CIFS client, Kerberos setup, Azure Files SMB Entra authorization,
storage-account key or SAS path. `AUTH_SYS` conveys UID/GID values, so NFS
permissions are not a replacement for network isolation: a process that can
reach the endpoint can present a UID. Keep the endpoint private and restrict
routes, NSGs and DNS accordingly.

The native client intentionally does not use AZNFS encryption in transit. The
Files-only account has Secure transfer disabled; this relies on the private
endpoint and tenant network and must not be described as encrypted NFS
transport. The Blob account is separate and keeps HTTPS required.

## Identity and secrets

- Developers receive Reader plus the narrow `TechSprint VM Power Operator`
  role only on their own app VMs.
- The DevOps lead group can manage app VMs across the estate. Creating the
  subscription-scoped role and changing Entra membership require approval.
- Each developer UAMI gets `Storage Blob Data Contributor` only on its own
  Blob account. It has no Azure Files NFS data-plane role.
- Keep passwords, private keys, plans and private Terraform output outside the
  repository. Do not put keys, SAS values, connection strings or passwords in
  variables files, terminal output or screenshots.

## Terraform-to-Ansible hand-off

- Terraform writes only sanitized, generated YAML fragments to the ignored
  `runtime/ansible/inventory/` directory: one tenant fragment per successful
  tenant apply and `00-shared.yml` only after shared reconciliation enables the
  private Application Gateway. The orchestrator then merges them into the mode-0600, gitignored `ansible/inventories/production/hosts.yml`; tracked production `group_vars` contain no secrets.
- These fragments contain topology and public SSH material only. They contain
  no passwords, private keys, SAS values, storage keys, connection strings, or
  Terraform state. Regenerate them with Terraform; do not hand-edit or commit
  them.
- Ansible must use the generated production `hosts.yml` together with a separately managed
  mode-0600 `moodle_secrets` vars file and an operator-held private key. SSH
  host-key verification is disabled by default (`StrictHostKeyChecking=no`,
  `UserKnownHostsFile=/dev/null`) for this lab's convenience; there is no
  `known_hosts` file to manage.
