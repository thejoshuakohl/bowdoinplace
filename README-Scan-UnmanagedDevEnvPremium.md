# Unmanaged developer environment premium scan

DISCLAIMER
This script is provided as-is, for demonstration purposes only.
Not supported by Microsoft.

Microsoft is making developer environments managed, so they will no longer grant premium
features without a premium license. This script lists the **canvas apps and cloud flows in
unmanaged developer environments that use premium features**, and shows whether each owner
holds a premium license (secondary information).

The script is read-only. It changes nothing in the tenant.

## Prerequisites

| Requirement | Notes |
|---|---|
| PowerShell 5.1 or 7+ | |
| [Azure CLI](https://aka.ms/installazurecliwindows) | Used only for sign-in and tokens. No PowerApps modules needed. |
| Admin account | Power Platform Administrator or Global Administrator, to list all environments, apps and flows. |
| Graph read access (optional) | Directory Reader or User Administrator, to look up owner licenses. Without it the license column shows `LOOKUP FAILED`. Use `-SkipLicenseCheck` to skip. |

## Usage

```powershell
.\Scan-UnmanagedDevEnvPremium-REST.ps1 -TenantId <tenant id or domain>
```

`-TenantId` triggers an `az login --use-device-code` prompt if you aren't already signed into
that tenant. Open the link shown, enter the code, and sign in as the admin. Use a private
browser window if you need a specific account.

| Parameter | Purpose |
|---|---|
| `-TenantId` | Tenant GUID or domain to scan. Required unless you already ran `az login`. |
| `-OutCsv` | Output file. Default: `Unmanaged-DevEnv-Premium-<yyyyMMdd>.csv` in the current folder. |
| `-IncludeManaged` | Also scan managed developer environments (to see what is already protected). |
| `-SkipLicenseCheck` | Skip the Graph license lookup. |

When finished, run `az logout`.

## What it does

1. Lists all environments, keeps those with SKU `Developer`, and excludes managed ones
   (`protectionLevel = Standard` means managed, `Basic` means unmanaged).
2. For each environment, scans apps and flows.
3. Looks up each owner in Microsoft Graph and checks for a premium service plan.

### What counts as premium

| Item | Flagged when |
|---|---|
| Apps | `usesPremiumApi = true` |
| Flows | Uses a connector with tier `Premium` |
| Flows | Has an `Http` or `HttpWebhook` action or trigger |
| Flows | Trigger is "When an HTTP request is received" |

### Output columns

`Type, Environment, EnvManaged, Name, Id, Owner, PremiumBecause, Connectors, State,
LastModified, OwnerHasPremiumLicense, OwnerSkus`

## Limitations

- **Review list, not a licensing verdict.** Custom connectors may not report tier Premium.
  Flows inside Dataverse solutions may be licensed differently from what the connector tier suggests.
- **Premium license list.** `$PremiumPlans` at the top of the script
  (`POWERAPPS_PER_USER`, `POWERAPPS_PER_APP`, `POWERAPPS_DYN_APPS`, `POWERAPPS_DYN_P2`) is
  not an official list. Confirm it against the SKUs your organization owns.
  The Developer Plan is excluded on purpose.
- **System-owned flows.** Microsoft-supplied flows (for example Dynamics 365 flows) are owned by
  a system identity, so the owner shows as a GUID with a blank license.
- **Owner is the creator.** For flows the owner is the creator, which may differ from the current owner or co-owners.
- **Large tenants** take a while. Transient 500 errors from the admin API are retried up to 4 times.
- **Sovereign clouds (GCC, China)** use different endpoints. The URLs in the script would need changing.
