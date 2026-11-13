# Disable-ComputerUse-AllEnvironments.ps1

Turns off Copilot Studio **computer use** in every Power Platform environment that has a Dataverse database, and writes a CSV of what happened.

It sets the environment setting `iscomputeruseinmcsenabled` to `false` (the method Microsoft documents: `pac env update-settings`), then reads it back to confirm.

## Prerequisites
- PowerShell 7+.
- **Azure CLI** (`az`), used to list environments.
- **Power Platform CLI** (`pac`), used to read and change the setting.
- An admin account that can administer the environments (Power Platform admin or Global admin, and admin rights on each Dataverse environment).

## Usage
```powershell
# 1. Preview only - changes nothing
.\Disable-ComputerUse-AllEnvironments.ps1 -TenantId <tenant-id-or-domain> -WhatIf

# 2. Apply
.\Disable-ComputerUse-AllEnvironments.ps1 -TenantId <tenant-id-or-domain>

# Only some environments / skip some
.\Disable-ComputerUse-AllEnvironments.ps1 -TenantId <tenant> -EnvironmentId <guid>,<guid>
.\Disable-ComputerUse-AllEnvironments.ps1 -TenantId <tenant> -ExcludeEnvironmentId <guid>

# Roll back (re-enable)
.\Disable-ComputerUse-AllEnvironments.ps1 -TenantId <tenant> -EnableInstead
```
The script asks for confirmation before each change. Add `-Confirm:$false` to run unattended.

| Parameter | Purpose |
|---|---|
| `-TenantId` | Tenant ID or domain. Starts `az login` (device code) and `pac auth create` if no sign-in exists. |
| `-EnvironmentId` | Only process these environment GUIDs. Default: all. |
| `-ExcludeEnvironmentId` | Skip these environment GUIDs. |
| `-OutFile` | CSV path. Default `.\ComputerUse-Disable-results.csv`. |
| `-EnableInstead` | Sets the value back to `true`. |
| `-WhatIf` | Preview. |

## Output
CSV columns: Environment, EnvironmentId, Type, DataverseUrl, Before, After, Status, Detail.

| Status | Meaning |
|---|---|
| Changed | Was enabled, now disabled and verified. |
| AlreadySet | Already disabled, nothing done. |
| Skipped | No Dataverse database, or the environment is not in an enabled state. |
| Failed / VerifyFailed | Could not change or confirm. See Detail (usually admin access or a disabled Dataverse org). |
| WhatIf | Preview only. |

## Notes
- The PAC sign-in must have admin rights in each environment. If it doesn't, those environments show `Failed`.
- **New environments default to enabled.** Re-run the script periodically or after new environments are created.
- The **tenant-wide** "Hosted browser in computer use" switch is separate: Power Platform admin center > Tenant settings > Hosted browser in computer use.
- To check one environment by hand: `pac env list-settings --environment <env-url>` and look for `iscomputeruseinmcsenabled`.
- You can also toggle it in the admin center: Environments > (environment) > Settings > Product > Features > Computer use. If the toggle isn't visible yet in your tenant, use this script.

## Status of testing
The script parses cleanly and the `iscomputeruseinmcsenabled` setting was confirmed to exist via `pac env list-settings`. The change/verify path was **not run end to end**, so run with `-WhatIf` first and then on one environment (`-EnvironmentId`) before going tenant-wide.

Reference: https://learn.microsoft.com/en-us/microsoft-copilot-studio/administer-computer-use
