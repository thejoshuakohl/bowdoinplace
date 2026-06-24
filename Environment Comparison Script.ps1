<#
Disclaimer The sample scripts are not supported under any Microsoft standard support program or service. 
The sample scripts are provided AS IS without warranty of any kind. Microsoft further disclaims all implied warranties 
including, without limitation, any implied warranties of merchantability or of fitness for a particular purpose. 
The entire risk arising out of the use or performance of the sample scripts and documentation remains with you. 
In no event shall Microsoft, its authors, or anyone else involved in the creation, production, or delivery of the scripts 
be liable for any damages whatsoever (including, without limitation, damages for loss of business profits, business interruption, 
loss of business information, or other pecuniary loss) arising out of the use of or inability to use the sample scripts or 
documentation, even if Microsoft has been advised of the possibility of such damages.
#>

# ===========================================
# Dataverse Environment Comparison Tool
# ===========================================

# Prerequisites:
# - App Registration with Client Secret
# - Application User created in each environment
# - Security Role with read access to Organization table
#
# Output:
# EnvironmentComparison.csv

# ===========================================
# Configuration
# ===========================================

# App Registration must be created and App User must be added to all environments
# Easiest is to give System Administrator role for that App User (for testing purposes), but a more limited role
# would be recommended to read the Organization table for actual use
$TenantId = "[TENANT ID]"
$ClientId = "[CLIENT ID]"
$ClientSecret = "[CLIENT SECRET]"

# Can take any number of environment urls
$EnvironmentUrls = @(
    "<org[YOUR UNIQUE URL 1].crm.dynamics.com>",
    "<org[YOUR UNIQUE URL 2].crm.dynamics.com>",
    "<org[YOUR UNIQUE URL 3].crm.dynamics.com>"
)

# ===========================================
# Get OAuth Token
# ===========================================

function Get-DataverseToken {

    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret,
        [string]$EnvironmentUrl
    )

    $Body = @{
        client_id     = $ClientId
        client_secret = $ClientSecret
        grant_type    = "client_credentials"
        scope         = "https://$EnvironmentUrl/.default"
    }

    $Response = Invoke-RestMethod `
        -Method Post `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Body $Body `
        -ContentType "application/x-www-form-urlencoded"

    return $Response.access_token
}

# ===========================================
# Flatten Nested JSON
# ===========================================

function Flatten-Object {

    param(
        $Object,
        [string]$Prefix = ""
    )

    $Result = @{}

    foreach ($Property in $Object.PSObject.Properties) {

        $Name = if ($Prefix) {
            "$Prefix.$($Property.Name)"
        }
        else {
            $Property.Name
        }

        if ($Property.Value -is [PSCustomObject]) {

            $Child = Flatten-Object `
                -Object $Property.Value `
                -Prefix $Name

            foreach ($Key in $Child.Keys) {
                $Result[$Key] = $Child[$Key]
            }
        }
        else {
            $Result[$Name] = $Property.Value
        }
    }

    return $Result
}

# ===========================================
# Collect Organization Settings
# ===========================================

$EnvironmentData = @{}

foreach ($EnvironmentUrl in $EnvironmentUrls) {

    Write-Host ""
    Write-Host "Processing $EnvironmentUrl..." -ForegroundColor Cyan

    try {

        $Token = Get-DataverseToken `
            -TenantId $TenantId `
            -ClientId $ClientId `
            -ClientSecret $ClientSecret `
            -EnvironmentUrl $EnvironmentUrl

        $Headers = @{
            Authorization      = "Bearer $Token"
            Accept             = "application/json"
            "OData-Version"    = "4.0"
            "OData-MaxVersion" = "4.0"
        }

        # Verify authentication

        $WhoAmI = Invoke-RestMethod `
            -Method Get `
            -Uri "https://$EnvironmentUrl/api/data/v9.2/WhoAmI()" `
            -Headers $Headers

        Write-Host "Connected. UserId: $($WhoAmI.UserId)"

        # Retrieve Organization record

        $Organizations = Invoke-RestMethod `
            -Method Get `
            -Uri "https://$EnvironmentUrl/api/data/v9.2/organizations?`$top=1" `
            -Headers $Headers

        if (-not $Organizations.value) {
            throw "No Organization records returned."
        }

        $Organization = $Organizations.value[0]

        $Flattened = Flatten-Object -Object $Organization

        $EnvironmentData[$EnvironmentUrl] = $Flattened

        Write-Host "Retrieved $($Flattened.Count) properties"

    }
    catch {

        Write-Warning "Failed: $EnvironmentUrl"
        Write-Warning $_.Exception.Message

        continue
    }
}

# ===========================================
# Build Comparison Matrix
# ===========================================

$AllProperties = $EnvironmentData.Values |
    ForEach-Object { $_.Keys } |
    Sort-Object -Unique

$Results = foreach ($Property in $AllProperties) {

    $Row = [ordered]@{
        Setting = $Property
    }

    foreach ($EnvironmentUrl in $EnvironmentUrls) {

        if (
            $EnvironmentData.ContainsKey($EnvironmentUrl) -and
            $EnvironmentData[$EnvironmentUrl].ContainsKey($Property)
        ) {
            $Row[$EnvironmentUrl] = $EnvironmentData[$EnvironmentUrl][$Property]
        }
        else {
            $Row[$EnvironmentUrl] = $null
        }
    }

    [PSCustomObject]$Row
}

# ===========================================
# Export Results
# ===========================================

# Path to file
$OutputFile = ".\EnvironmentComparison.csv"

$Results |
    Export-Csv `
        -Path $OutputFile `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host ""
Write-Host "Completed" -ForegroundColor Green
Write-Host "Output File: $OutputFile"