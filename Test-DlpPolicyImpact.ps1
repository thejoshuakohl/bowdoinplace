<#
.SYNOPSIS
  Previews the impact of adding environment(s) to a DLP (data) policy, using the Power Platform inventory.

.DESCRIPTION
  Reads a DLP policy (from the tenant or a JSON file), pulls apps, flows and agents plus the connectors
  they use from the Power Platform inventory API, and reports every resource that WOULD violate the policy:
    1. Uses a connector classified Blocked.
    2. Mixes Business and Non-business connectors in one resource.
  Connectors not listed in the policy take the policy's default classification.
  Output: one row per resource + connector in question (XLSX if the ImportExcel module is present, otherwise CSV).
  Read-only. Changes nothing in the tenant.

.EXAMPLE
  .\Test-DlpPolicyImpact.ps1 -TenantId contoso.onmicrosoft.com                      # lists the tenant's policies
  .\Test-DlpPolicyImpact.ps1 -TenantId contoso.onmicrosoft.com -PolicyName <guid> -EnvironmentId <env guid>
  .\Test-DlpPolicyImpact.ps1 -PolicyFile .\policy.json                              # all environments, offline policy
#>
param(
    [string]$TenantId,                 # tenant GUID or domain; signs in with device code if needed
    [string]$PolicyName,               # DLP policy GUID (tenant-level policy). Omit to list policies and exit.
    [string]$PolicyFile,               # alternative: policy JSON saved from the governance API
    [string[]]$EnvironmentId,          # environment GUID(s) to analyze. Omit to analyze every environment.
    [string]$OutFile = ".\DlpImpact-$(Get-Date -Format yyyyMMdd-HHmm)",   # extension added automatically
    [switch]$SkipOwnerLookup           # skip Microsoft Graph owner lookup (owner shown as object ID)
)

$ErrorActionPreference = 'Stop'

# ---------- Auth (Azure CLI, delegated user token: the inventory API rejects service principals) ----------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) not found. Install: https://aka.ms/installazurecliwindows' }
$current = az account show --query tenantId -o tsv 2>$null
if ($TenantId) {
    $isGuid = $TenantId -match '^[0-9a-fA-F-]{36}$'
    if (-not $current -or ($isGuid -and $current -ne $TenantId)) {
        az login --use-device-code --tenant $TenantId --allow-no-subscriptions --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'az login failed.' }
    }
} elseif (-not $current) {
    throw 'Not signed in. Re-run with -TenantId <tenant id or domain>.'
}
Write-Host "Tenant: $(az account show --query tenantId -o tsv)"

function Get-Hdr($resource) {
    $t = az account get-access-token --resource $resource --query accessToken -o tsv
    if (-not $t) { throw "Could not get a token for $resource" }
    @{ Authorization = "Bearer $t"; 'Content-Type' = 'application/json' }
}
function Invoke-Retry([scriptblock]$Call) {
    foreach ($i in 1..4) {
        try { return & $Call } catch {
            $msg = "$($_.ErrorDetails.Message) $($_.Exception.Message)"
            if ($i -eq 4 -or $msg -match '400|401|403|404') { throw }
            Start-Sleep ($i * 3)
        }
    }
}

# ---------- 1. Policy ----------
$BapUri = 'https://api.bap.microsoft.com/providers/PowerPlatform.Governance/v1/policies'
if (-not $PolicyName -and -not $PolicyFile) {
    $list = Invoke-Retry { Invoke-RestMethod -Headers (Get-Hdr 'https://service.powerapps.com/') -Uri "$BapUri`?`$top=50&api-version=2016-11-01" }
    if (-not @($list.value).Count) { Write-Host 'No tenant DLP policies found.'; return }
    $list.value | ForEach-Object { $q = if ($_.properties) { $_.properties } else { $_ }; [pscustomobject]@{ PolicyName = $_.name; DisplayName = $q.displayName; EnvironmentType = $q.environmentType } } | Format-Table -AutoSize
    Write-Host 'Re-run with -PolicyName <PolicyName>.'
    return
}
$policy = if ($PolicyFile) { Get-Content -LiteralPath $PolicyFile -Raw | ConvertFrom-Json }
          else { Invoke-Retry { Invoke-RestMethod -Headers (Get-Hdr 'https://service.powerapps.com/') -Uri "$BapUri/$PolicyName`?api-version=2016-11-01" } }
$pp = if ($policy.properties) { $policy.properties } else { $policy }
if (-not $pp.connectorGroups) { throw 'Policy has no connectorGroups - is this a DLP policy JSON?' }

# Confidential = Business, General = Non-business
$classMap = @{ Confidential = 'Business'; General = 'Non-business'; Blocked = 'Blocked' }
function Get-ConnKey([string]$id) { ($id -split '/')[-1].ToLowerInvariant() }
$policyClass = @{}
foreach ($g in $pp.connectorGroups) {
    foreach ($c in $g.connectors) { $policyClass[(Get-ConnKey $c.id)] = $classMap[[string]$g.classification] }
}
$defaultClass = if ($pp.defaultConnectorsClassification) { $classMap[[string]$pp.defaultConnectorsClassification] } else { 'Non-business' }
$policyLabel = if ($pp.displayName) { $pp.displayName } else { $PolicyName }
Write-Host "Policy: $policyLabel | explicit connectors: $($policyClass.Count) | unlisted connectors default to: $defaultClass"

function Get-Classification([string]$connectorId) {
    $k = Get-ConnKey $connectorId
    if ($policyClass.ContainsKey($k)) { return @{ Class = $policyClass[$k]; Listed = $true } }
    return @{ Class = $defaultClass; Listed = $false }
}

# ---------- 2. Inventory ----------
$QueryUri = 'https://api.powerplatform.com/resourcequery/resources/query?api-version=2024-10-01'
function Invoke-Inventory($clauses) {
    $skip = ''
    do {
        $body = @{ TableName = 'PowerPlatformResources'; Clauses = $clauses; Options = @{ Top = 1000; Skip = 0; SkipToken = $skip } } | ConvertTo-Json -Depth 12
        $r = Invoke-Retry { Invoke-RestMethod -Method POST -Headers (Get-Hdr 'https://api.powerplatform.com/') -Body $body -Uri $QueryUri }
        $r.data
        $skip = $r.skipToken
    } while ($skip)
}

$envNames = @{}
Invoke-Inventory @(
    [ordered]@{ '$type' = 'where'; FieldName = 'type'; Operator = '=='; Values = @("'microsoft.powerplatform/environments'") },
    [ordered]@{ '$type' = 'project'; FieldList = @('name', 'displayName = tostring(properties.displayName)') }
) | ForEach-Object { $envNames[$_.name.ToLower()] = $_.displayName }

$types = @(
    "'microsoft.powerapps/canvasapps'", "'microsoft.powerapps/modeldrivenapps'", "'microsoft.powerapps/codeapps'",
    "'microsoft.powerapps/apps'", "'microsoft.powerautomate/cloudflows'", "'microsoft.powerautomate/agentflows'",
    "'microsoft.powerautomate/m365agentflows'", "'microsoft.copilotstudio/agents'"
)
$clauses = @(
    [ordered]@{ '$type' = 'where'; FieldName = 'type'; Operator = 'in~'; Values = $types },
    [ordered]@{ '$type' = 'extend'; FieldName = 'environmentId'; Expression = 'tolower(tostring(properties.environmentId))' }
)
if ($EnvironmentId) {
    $clauses += [ordered]@{ '$type' = 'where'; FieldName = 'environmentId'; Operator = 'in~'; Values = @($EnvironmentId | ForEach-Object { "'$($_.ToLower())'" }) }
}
$clauses += [ordered]@{ '$type' = 'project'; FieldList = @(
    'name', 'type', 'environmentId',
    'displayName = tostring(properties.displayName)',
    'ownerId = tostring(properties.ownerId)',
    'connectors = properties.powerPlatformConnectors'
) }

Write-Host 'Querying inventory ...'
$resources = @(Invoke-Inventory $clauses)
Write-Host "Resources returned: $($resources.Count)"

# ---------- 3. Owner lookup (cached) ----------
$ownerCache = @{}
$gph = if ($SkipOwnerLookup) { $null } else { Get-Hdr 'https://graph.microsoft.com/' }
function Get-Owner([string]$id) {
    if (-not $id) { return [pscustomobject]@{ Name = ''; Email = ''; Upn = '' } }
    if ($ownerCache.ContainsKey($id)) { return $ownerCache[$id] }
    $v = [pscustomobject]@{ Name = ''; Email = ''; Upn = $id }
    if ($gph) {
        try {
            $u = Invoke-RestMethod -Headers $gph -Uri "https://graph.microsoft.com/v1.0/users/$id`?`$select=displayName,mail,userPrincipalName"
            $v = [pscustomobject]@{ Name = $u.displayName; Email = $(if ($u.mail) { $u.mail } else { $u.userPrincipalName }); Upn = $u.userPrincipalName }
        } catch { }
    }
    $ownerCache[$id] = $v
    return $v
}

$typeLabel = @{
    'microsoft.powerapps/canvasapps' = 'Canvas app'; 'microsoft.powerapps/modeldrivenapps' = 'Model-driven app'
    'microsoft.powerapps/codeapps' = 'Code app'; 'microsoft.powerapps/apps' = 'App'
    'microsoft.powerautomate/cloudflows' = 'Cloud flow'; 'microsoft.powerautomate/agentflows' = 'Agent flow'
    'microsoft.powerautomate/m365agentflows' = 'Workflow agent flow'; 'microsoft.copilotstudio/agents' = 'Agent'
}

# ---------- 4. Evaluate ----------
$rows = [System.Collections.Generic.List[object]]::new()
$violatingIds = @{}
foreach ($res in $resources) {
    $conns = @($res.connectors | Where-Object { $_.connectorId })
    if (-not $conns) { continue }
    $classified = foreach ($c in $conns) {
        $k = Get-Classification $c.connectorId
        [pscustomobject]@{
            Id = $c.connectorId; Class = $k.Class; Listed = $k.Listed
            Ops = (@($c.operations.operationId) -join ', ')
        }
    }
    $business = @($classified | Where-Object Class -eq 'Business')
    $non      = @($classified | Where-Object Class -eq 'Non-business')
    $blocked  = @($classified | Where-Object Class -eq 'Blocked')
    $reasons = @()
    foreach ($c in $blocked) { $reasons += [pscustomobject]@{ Why = 'Uses a Blocked connector'; C = $c } }
    if ($business -and $non) {
        $detail = "Business: $($business.Id -join ', ') | Non-business: $($non.Id -join ', ')"
        foreach ($c in @($business) + @($non)) { $reasons += [pscustomobject]@{ Why = "Mixes Business and Non-business connectors ($detail)"; C = $c } }
    }
    if (-not $reasons) { continue }
    $violatingIds["$($res.environmentId)|$($res.name)"] = $true
    $owner = Get-Owner $res.ownerId
    foreach ($r in $reasons) {
        $rows.Add([pscustomobject]@{
            Environment = $(if ($envNames[[string]$res.environmentId]) { $envNames[[string]$res.environmentId] } else { "(unknown) $($res.environmentId)" }); EnvironmentId = $res.environmentId
            ResourceType = $typeLabel[[string]$res.type]; ResourceName = $res.displayName; ResourceId = $res.name
            OwnerName = $owner.Name; OwnerEmail = $owner.Email; OwnerUPN = $owner.Upn; OwnerObjectId = $res.ownerId
            Violation = $r.Why
            Connector = $r.C.Id; ConnectorClassification = $r.C.Class
            ClassificationSource = $(if ($r.C.Listed) { 'Policy' } else { "Default ($defaultClass)" })
            OperationsUsed = $r.C.Ops
        })
    }
}

# ---------- 5. Output ----------
$summary = $resources | Group-Object environmentId | ForEach-Object {
    $envId = $_.Name
    $viol = @($_.Group | Where-Object { $violatingIds.ContainsKey("$envId|$($_.name)") })
    [pscustomobject]@{
        Environment = $(if ($envNames[$envId]) { $envNames[$envId] } else { "(unknown) $envId" }); EnvironmentId = $envId
        ResourcesAnalyzed = $_.Count; ResourcesWithViolations = $viol.Count
        ViolationRows = @($rows | Where-Object EnvironmentId -eq $envId).Count
    }
} | Sort-Object Environment

$sorted = $rows | Sort-Object Environment, ResourceType, ResourceName, Connector
if (Get-Module -ListAvailable ImportExcel) {
    Import-Module ImportExcel
    $path = [IO.Path]::ChangeExtension($OutFile, '.xlsx'); if (Test-Path $path) { Remove-Item $path }
    $sorted  | Export-Excel -Path $path -WorksheetName 'Violations' -TableName 'Violations' -AutoSize -FreezeTopRow -AutoFilter
    $summary | Export-Excel -Path $path -WorksheetName 'Summary' -TableName 'Summary' -AutoSize
    [pscustomobject]@{ Policy = $policyLabel; DefaultClassification = $defaultClass; GeneratedUtc = (Get-Date).ToUniversalTime().ToString('s') } |
        Export-Excel -Path $path -WorksheetName 'Policy' -AutoSize
} else {
    $path = [IO.Path]::ChangeExtension($OutFile, '.csv')
    $sorted | Export-Csv $path
    Write-Warning 'ImportExcel module not found - wrote CSV (opens in Excel). For XLSX: Install-Module ImportExcel -Scope CurrentUser'
}

Write-Host ("`nResources analyzed: {0} | resources with violations: {1} | violation rows: {2}" -f $resources.Count, $violatingIds.Count, $rows.Count)
$summary | Format-Table -AutoSize
Write-Host "Report: $((Resolve-Path $path).Path)"
