# Lists apps and flows using premium features in UNMANAGED developer environments.
# Usage: .\Scan-UnmanagedDevEnvPremium-REST.ps1 -TenantId <tenant id or domain>
# Auth: Azure CLI device-code sign-in (done automatically with -TenantId). No PowerApps modules needed.
# DISCLAIMER This script is provided as-is, for demonstration purposes only. Not supported by Microsoft.
param(
    [string]$TenantId,            # tenant (GUID or domain) to scan; signs in with device code if not already signed into it
    [string]$OutCsv = ".\Unmanaged-DevEnv-Premium-$(Get-Date -Format yyyyMMdd).csv",
    [switch]$IncludeManaged,      # also scan managed developer environments (for testing)
    [switch]$SkipLicenseCheck     # skip Graph license lookup
)

# VERIFY: service plans that grant premium rights. Developer Plan (POWERAPPS_DEV) excluded on purpose.
$PremiumPlans = @('POWERAPPS_PER_USER','POWERAPPS_PER_APP','POWERAPPS_DYN_APPS','POWERAPPS_DYN_P2')
$PremiumActionTypes = @('Http','HttpWebhook')

function Get-Hdr($resource) { @{ Authorization = "Bearer $(az account get-access-token --resource $resource --query accessToken -o tsv)" } }
function Invoke-Api($uri, $hdr) {
    foreach ($i in 1..4) {
        try { return Invoke-RestMethod -Headers $hdr -Uri $uri } catch { if ($i -eq 4) { throw }; Start-Sleep ($i * 3) }
    }
}
function Get-All($uri, $hdr) {
    while ($uri) {
        $r = Invoke-Api $uri $hdr
        $r.value
        $uri = $r.nextLink
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) not found. Install it from https://aka.ms/installazurecliwindows' }

# ---- 0. Sign-in (only prompts when not already signed into the requested tenant) ----
$current = az account show --query tenantId -o tsv 2>$null
if ($TenantId) {
    $isGuid = $TenantId -match '^[0-9a-fA-F-]{36}$'
    if (-not $current -or ($isGuid -and $current -ne $TenantId)) {
        az login --use-device-code --tenant $TenantId --allow-no-subscriptions --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'az login failed.' }
    }
} elseif (-not $current) {
    throw 'Not signed in. Re-run with -TenantId <tenant id or domain>, or run: az login --use-device-code --tenant <id> --allow-no-subscriptions'
}
Write-Host "Scanning tenant: $(az account show --query tenantId -o tsv)"

$bap  = Get-Hdr 'https://service.powerapps.com/'
$flow = Get-Hdr 'https://service.flow.microsoft.com/'
$gph  = if ($SkipLicenseCheck) { $null } else { Get-Hdr 'https://graph.microsoft.com/' }

# ---- 1. Developer environments, with managed state (protectionLevel Standard = managed, Basic = not) ----
$envs = Get-All "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2021-04-01&`$expand=properties.governanceConfiguration" $bap |
    ForEach-Object {
        [pscustomobject]@{
            Id = $_.name; Name = $_.properties.displayName; Sku = $_.properties.environmentSku
            IsManaged = ($_.properties.governanceConfiguration.protectionLevel -eq 'Standard')
        }
    }
$targets = $envs | Where-Object { $_.Sku -eq 'Developer' -and ($IncludeManaged -or -not $_.IsManaged) }
Write-Host "Environments: $(@($envs).Count) total; developer: $(@($envs | ? Sku -eq 'Developer').Count); scanning: $(@($targets).Count)"

# ---- 2. User lookup + license (secondary), cached ----
$userCache = @{}
function Get-UserInfo([string]$UserId) {
    if (-not $UserId) { return [pscustomobject]@{ Upn = ''; Has = $null; Skus = '' } }
    if ($userCache.ContainsKey($UserId)) { return $userCache[$UserId] }
    $info = [pscustomobject]@{ Upn = $UserId; Has = $null; Skus = '' }
    if ($gph) {
        try {
            $u = Invoke-RestMethod -Headers $gph -Uri "https://graph.microsoft.com/v1.0/users/$UserId`?`$select=userPrincipalName"
            $info.Upn = $u.userPrincipalName
            $lic = (Invoke-RestMethod -Headers $gph -Uri "https://graph.microsoft.com/v1.0/users/$UserId/licenseDetails").value
            $plans = $lic.servicePlans | Where-Object { $_.provisioningStatus -ne 'Disabled' }
            $info.Has  = [bool]($plans | Where-Object { $_.servicePlanName -in $PremiumPlans })
            $info.Skus = ($lic.skuPartNumber -join '; ')
        } catch { $info.Skus = 'LOOKUP FAILED' }
    }
    $userCache[$UserId] = $info
    return $info
}

# ---- 3. Scan apps and flows ----
$results = foreach ($e in $targets) {
    Write-Host "Scanning $($e.Name) (managed: $($e.IsManaged)) ..."

    # --- Apps ---
    $apps = Get-All "https://api.powerapps.com/providers/Microsoft.PowerApps/scopes/admin/environments/$($e.Id)/apps?api-version=2021-02-01" $bap
    foreach ($app in $apps) {
        $p = $app.properties
        if (-not [bool]$p.usesPremiumApi) { continue }     # VERIFY on a known premium app
        $u = Get-UserInfo $p.owner.id
        [pscustomobject]@{
            Type = 'App'; Environment = $e.Name; EnvManaged = $e.IsManaged
            Name = $p.displayName; Id = $app.name
            Owner = $(if ($p.owner.userPrincipalName) { $p.owner.userPrincipalName } else { $u.Upn })
            PremiumBecause = 'usesPremiumApi = true'
            Connectors = (@($p.connectionReferences.PSObject.Properties.Value.displayName) -join '; ')
            State = ''; LastModified = $p.lastModifiedTime
            OwnerHasPremiumLicense = $u.Has; OwnerSkus = $u.Skus
        }
    }

    # --- Flows ---
    $flows = Get-All "https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple/scopes/admin/environments/$($e.Id)/v2/flows?api-version=2016-11-01" $flow
    foreach ($f in $flows) {
        $p = $f.properties
        if (-not $p.definitionSummary -or $null -eq $p.connectionReferences) {
            try { $p = (Invoke-Api "https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple/scopes/admin/environments/$($e.Id)/flows/$($f.name)?api-version=2016-11-01" $flow).properties }
            catch { Write-Warning "Skipped flow $($f.name) in $($e.Name): $($_.Exception.Message)"; continue }
        }
        $reasons = @()
        $refs = @($p.connectionReferences.PSObject.Properties.Value)
        $premRefs = $refs | Where-Object { $_.tier -eq 'Premium' }
        if ($premRefs) { $reasons += 'Premium connector: ' + (($premRefs.displayName | Sort-Object -Unique) -join ', ') }

        $summary  = @($p.definitionSummary.actions) + @($p.definitionSummary.triggers)
        $httpType = $summary | Where-Object { $_.type -in $PremiumActionTypes } | ForEach-Object type | Sort-Object -Unique
        if ($httpType) { $reasons += 'Action type: ' + ($httpType -join ', ') }
        # "When an HTTP request is received" = Request trigger with kind Http (button/PowerApps/Teams triggers have other kinds)
        if ($p.definitionSummary.triggers | Where-Object { $_.type -eq 'Request' -and $_.kind -eq 'Http' }) { $reasons += 'Trigger: HTTP request received' }

        if (-not $reasons) { continue }
        $u = Get-UserInfo $p.creator.userId
        [pscustomobject]@{
            Type = 'Flow'; Environment = $e.Name; EnvManaged = $e.IsManaged
            Name = $p.displayName; Id = $f.name; Owner = $u.Upn
            PremiumBecause = ($reasons -join ' | ')
            Connectors = (($refs.displayName | Sort-Object -Unique) -join '; ')
            State = $p.state; LastModified = $p.lastModifiedTime
            OwnerHasPremiumLicense = $u.Has; OwnerSkus = $u.Skus
        }
    }
}

# ---- 4. Output ----
$results | Sort-Object Environment, Type, Name | Export-Csv $OutCsv -NoTypeInformation
Write-Host "`nPremium items: $(@($results | ? Type -eq 'App').Count) apps, $(@($results | ? Type -eq 'Flow').Count) flows  ->  $OutCsv"
$results | Sort-Object Environment, Type, Name | Format-Table Type, Environment, EnvManaged, Name, Owner, PremiumBecause, OwnerHasPremiumLicense -AutoSize
