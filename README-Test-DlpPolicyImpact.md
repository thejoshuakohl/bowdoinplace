# Test-DlpPolicyImpact.ps1

Previews which **apps, flows and agents** would violate a DLP (data) policy **before** you apply it to an environment. Output is a spreadsheet listing each resource (name, ID, type, owner name and email) and the connector that causes the violation.
DISCLAIMER
This script is provided as-is, for demonstration purposes only.
Not supported by Microsoft.

## How it works
1. Reads the DLP policy (from the tenant, or from a saved JSON file) and builds the Business / Non-business / Blocked connector lists. Unlisted connectors take the policy's default group.
2. Queries the **Power Platform inventory API** (`resourcequery`) for the connectors used by every canvas app, model-driven app, code app, cloud flow, agent flow and Copilot Studio agent.
3. Flags:
   - **Uses a Blocked connector**
   - **Mixes Business and Non-business connectors** in one resource (flagged against each connector involved)
4. Looks up each owner in Microsoft Graph (name, email, UPN).

The policy's own environment scoping is ignored on purpose, so a policy applied to no environments can still be analyzed.

## Prerequisites
- PowerShell 7+ and the **Azure CLI** (`az`).
- A **user** account with one of: Global admin, Power Platform admin, Dynamics 365 admin, or Global reader. The inventory API rejects service principals and managed identities (HTTP 403).
- Optional: `Install-Module ImportExcel -Scope CurrentUser` for `.xlsx` output. Without it, a `.csv` is written.
- Not available in GCC, GCC High or DoD (connector inventory is not supported there).

## Usage
```powershell
# 1. List the tenant's DLP policies
.\Test-DlpPolicyImpact.ps1 -TenantId <tenant-id-or-domain>

# 2. Analyze one policy against every environment
.\Test-DlpPolicyImpact.ps1 -TenantId <tenant> -PolicyName <policy-guid>

# 3. Analyze against specific environments only
.\Test-DlpPolicyImpact.ps1 -TenantId <tenant> -PolicyName <policy-guid> -EnvironmentId <env-guid>,<env-guid>

# Offline policy (JSON saved from the governance API)
.\Test-DlpPolicyImpact.ps1 -PolicyFile .\policy.json
```

| Parameter | Purpose |
|---|---|
| `-TenantId` | Tenant ID or domain. Triggers `az login` (device code) if needed. |
| `-PolicyName` | Policy GUID. Omit to list policies and exit. |
| `-PolicyFile` | Policy JSON instead of calling the tenant. |
| `-EnvironmentId` | One or more environment GUIDs. Default: all environments. |
| `-OutFile` | Output path without extension. |
| `-SkipOwnerLookup` | Skip Graph; owner is shown as an object ID only. |

## Output
**Violations** sheet columns: Environment, EnvironmentId, ResourceType, ResourceName, ResourceId, OwnerName, OwnerEmail, OwnerUPN, OwnerObjectId, Violation, Connector, ConnectorClassification, ClassificationSource, OperationsUsed.
Also a **Summary** sheet (per environment) and a **Policy** sheet (the connector lists used).

Owner is the resource owner (the creator for flows). Owners that are no longer in the directory, or are service principals, show only the object ID.

## Limitations (it is a preview, not a guarantee)
- **Built-in connectors may be missing from the inventory.** In testing, a built-in HTTP action was not listed for a flow, so a policy blocking HTTP would not be caught. Spot-check any policy that restricts HTTP or other built-in actions.
- Not evaluated: custom connector URL-pattern rules, connector action rules, endpoint filtering, and interaction with other DLP policies already applied to the environment.
- Microsoft-trusted connectors (for example Dataverse, SharePoint, Outlook, Approvals) cannot be set to Blocked, so they can only produce "mixes" findings.
- Newly created or changed resources may take time to appear in the inventory.
- Policy JSON shape was validated against the live API (flat object with `connectorGroups[]`). The `-PolicyFile` option accepts either that or a `properties`-wrapped form.

## Newer PAC CLI
`pac resource-query` (preview, newer PAC CLI versions) wraps the same inventory API. This script calls the REST API directly so it works with any PAC version.
