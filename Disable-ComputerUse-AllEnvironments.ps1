<#
.SYNOPSIS
  Disables Copilot Studio "computer use" (iscomputeruseinmcsenabled) in every Power Platform environment that has Dataverse.

.DESCRIPTION
  1. Lists environments through the Power Platform admin API (az CLI sign-in).
  2. For each environment with a Dataverse instance, reads the setting with PAC CLI, sets it to false, and reads it back to verify.
  3. Writes a CSV of results. Environments that can't be changed (no Dataverse, disabled, no access) are reported, not fatal.

  Use -WhatIf first to preview without changing anything.
  The tenant-wide "Hosted browser in computer use" switch is separate (Power Platform admin center > Tenant settings).

.EXAMPLE
  .\Disable-ComputerUse-AllEnvironments.ps1 -TenantId contoso.onmicrosoft.com -WhatIf
  .\Disable-ComputerUse-AllEnvironments.ps1 -TenantId contoso.onmicrosoft.com
  .\Disable-ComputerUse-AllEnvironments.ps1 -TenantId contoso.onmicrosoft.com -ExcludeEnvironmentId <guid>
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$TenantId,
    [string[]]$EnvironmentId,          # limit to these environment GUIDs (default: all)
    [string[]]$ExcludeEnvironmentId,   # skip these environment GUIDs
    [string]$OutFile = ".\ComputerUse-Disable-results.csv",
    [switch]$EnableInstead             # re-enable computer use (rollback)
)

$ErrorActionPreference = 'Stop'
$SettingName = 'iscomputeruseinmcsenabled'
$TargetValue = if ($EnableInstead) { 'true' } else { 'false' }
$TargetLabel = if ($EnableInstead) { 'Yes' } else { 'No' }

foreach ($tool in 'az', 'pac') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "'$tool' not found on PATH. Install Azure CLI and Power Platform CLI first." }
}

# ---------- 1. Sign in ----------
$null = az account show 2>$null
if ($LASTEXITCODE -ne 0 -or ($TenantId -and (az account show --query tenantId -o tsv) -ne $TenantId -and (az account show --query tenantDomain -o tsv 2>$null) -ne $TenantId)) {
    if ($TenantId) { az login --tenant $TenantId --allow-no-subscriptions --use-device-code | Out-Null } else { az login --allow-no-subscriptions --use-device-code | Out-Null }
}
$tenant = az account show --query tenantId -o tsv
Write-Host "Tenant: $tenant"

function Invoke-Retry([scriptblock]$Block, [int]$Tries = 3) {
    for ($i = 1; $i -le $Tries; $i++) {
        try { return & $Block } catch { if ($i -eq $Tries) { throw }; Start-Sleep -Seconds (2 * $i) }
    }
}

# ---------- 2. List environments ----------
$tok = az account get-access-token --resource https://service.powerapps.com/ --query accessToken -o tsv
$hdr = @{ Authorization = "Bearer $tok" }
$envs = (Invoke-Retry { Invoke-RestMethod -Headers $hdr -Uri 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2020-10-01' }).value
if ($EnvironmentId)        { $envs = @($envs | Where-Object { $EnvironmentId -contains $_.name }) }
if ($ExcludeEnvironmentId) { $envs = @($envs | Where-Object { $ExcludeEnvironmentId -notcontains $_.name }) }
Write-Host "Environments found: $(@($envs).Count)"

# ---------- 3. PAC auth (needs admin rights in each environment) ----------
$authList = pac auth list 2>&1 | Out-String
if ($authList -notmatch '\*') {
    Write-Host 'No active PAC auth profile - creating one (sign in as an admin).'
    pac auth create --tenant $tenant | Out-Null
}

function Get-Setting([string]$url) {
    $out = pac env list-settings --environment $url 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $out -match '(?im)^\s*Error:') { throw (($out -split "`n" | Where-Object { $_ -match 'Error' } | Select-Object -First 1).Trim()) }
    $m = [regex]::Match($out, "(?im)^\s*$SettingName\s+(\S+)")
    if ($m.Success) { return $m.Groups[1].Value } else { return '(not present)' }
}

# ---------- 4. Process ----------
$results = foreach ($e in $envs) {
    $p = $e.properties
    $row = [ordered]@{
        Environment = $p.displayName; EnvironmentId = $e.name; Type = $p.environmentSku
        DataverseUrl = $p.linkedEnvironmentMetadata.instanceUrl; Before = ''; After = ''; Status = ''; Detail = ''
    }
    if (-not $row.DataverseUrl) { $row.Status = 'Skipped'; $row.Detail = 'No Dataverse database'; [pscustomobject]$row; continue }
    if ($p.states.runtime.id -and $p.states.runtime.id -ne 'Enabled') { $row.Status = 'Skipped'; $row.Detail = "Environment state: $($p.states.runtime.id)"; [pscustomobject]$row; continue }

    try {
        $row.Before = Invoke-Retry { Get-Setting $row.DataverseUrl } 2
        if ($row.Before -eq $TargetLabel) { $row.After = $row.Before; $row.Status = 'AlreadySet'; [pscustomobject]$row; continue }

        if ($PSCmdlet.ShouldProcess("$($row.Environment) ($($row.EnvironmentId))", "Set $SettingName = $TargetValue")) {
            $out = pac env update-settings --environment $row.DataverseUrl --name $SettingName --value $TargetValue 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0 -or $out -match '(?im)^\s*Error:') { throw (($out -split "`n" | Where-Object { $_ -match 'Error' } | Select-Object -First 1).Trim()) }
            $row.After = Get-Setting $row.DataverseUrl
            $row.Status = if ($row.After -eq $TargetLabel) { 'Changed' } else { 'VerifyFailed' }
        } else { $row.Status = 'WhatIf'; $row.After = $row.Before }
    } catch {
        $row.Status = 'Failed'; $row.Detail = $_.Exception.Message
    }
    Write-Host ("{0,-12} {1} ({2})" -f $row.Status, $row.Environment, $row.EnvironmentId)
    [pscustomobject]$row
}

# ---------- 5. Report ----------
$results | Export-Csv -LiteralPath $OutFile -NoTypeInformation -Encoding utf8
Write-Host ''
$results | Group-Object Status | Select-Object @{n = 'Status'; e = { $_.Name } }, Count | Format-Table -AutoSize
Write-Host "Results: $((Resolve-Path $OutFile).Path)"
if ($results | Where-Object Status -in 'Failed', 'VerifyFailed') {
    Write-Warning 'Some environments could not be updated. Check the Detail column (admin access or Dataverse state).'
}
Write-Host 'Reminder: the tenant-wide "Hosted browser in computer use" setting is separate (admin center > Tenant settings).'
