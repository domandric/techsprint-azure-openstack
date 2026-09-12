# Azure cost review

This is a planning aid for the tested scope of two developers and one lead,
not a live subscription quote. Retail prices vary by region, agreement, VM
SKU, usage, and date; re-query before budgeting.

## Current topology and cost model

The deployment has one shared MySQL Flexible Server 8.4,
`GP_Standard_D2ds_v4`, GeneralPurpose, ZoneRedundant (primary zone 1,
standby zone 2). Its compute, 32 GiB storage, and HA standby are one fixed
shared database meter, not one server per developer. Each developer adds one
`moodle_<slug_with_underscores>` database, user, and grant, but no MySQL server
or MySQL DNS zone. The trade-off is shared database failure/blast radius and
network reachability.

Jump, Lead, and app VMs use one resolver-selected SKU. Application Gateway is
one shared fixed-cost service. Each developer adds two app VMs, disks, Blob,
Files, and two private endpoints. There is no Redis; Moodle's default
file-based session/cache stores use the shared Files `dataroot`.

Terraform creates two private endpoints per developer (Blob and Files), so the
two-developer scope has four. The topology has four shared private DNS zones
(Blob, Files, Moodle, and MySQL); VNet links have no separate meter here. The
old tenant MySQL subnet is retained unused for migration compatibility.

## Itemized meters to re-check

| Scope | Meter | Cost treatment |
| --- | --- | --- |
| Shared | Jump, Lead, and private Application Gateway | Fixed shared meters; VM rate follows the resolved profile |
| Shared | One MySQL Flexible Server 8.4, `GP_Standard_D2ds_v4`, ZoneRedundant | One fixed shared HA meter plus configured storage |
| Per developer | Two app VMs, OS/data disks, Files, Blob | Per-developer meters |
| Per developer | Two private endpoints | At the applicable Private Link hourly rate |
| Shared | Four private DNS zones | One shared zone meter for Blob, Files, Moodle, and MySQL |
| Variable | Private Link processing, DNS queries, bandwidth, egress, transactions | Measure or estimate from actual usage |

For the fixed two-developer example, four private endpoints at the previously
observed public reference rate of `$0.01/hour` would be `$29.20/month` at 730
hours, and four DNS zones at `$0.50/zone-month` would be `$2.00/month`. These
are reference rates only; verify the applicable meters.

## Reproducing or updating the estimate

Query the Azure Retail Prices API for the resolver-selected region and VM SKU,
then verify each result against Cost Management. Do not reuse historical
multi-server database calculations; price the one shared HA MySQL meter plus
the per-developer app and storage meters above.

```bash
curl -sG 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "\$filter=serviceName eq 'Azure Private Link' and priceType eq 'Consumption'"
curl -sG 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "\$filter=serviceName eq 'Azure DNS' and priceType eq 'Consumption'"
```

Taxes, discounts, reservations, Savings Plans, Hybrid Benefit, and
subscription-specific credits are excluded.
