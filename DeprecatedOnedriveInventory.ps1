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

# ==========================================================
# Power Platform Inventory - OneDrive Consumer Connector Scan
#
# Purpose:
#   Identify Power Apps and Power Automate resources using
#   the deprecated OneDrive Consumer connector.
#
# Connector:
#   shared_onedrive
#
# Compatible:
#   Windows PowerShell 5.1+
# ==========================================================


# -------------------------------
# Module validation
# -------------------------------

$requiredModules = @(
    "Az.Accounts",
    "Az.ResourceGraph"
)

foreach ($module in $requiredModules) {

    if (-not (Get-Module -ListAvailable -Name $module)) {

        Write-Host "Installing missing module: $module" -ForegroundColor Yellow

        Install-Module `
            -Name $module `
            -Scope CurrentUser `
            -Force
    }
}


Import-Module Az.Accounts
Import-Module Az.ResourceGraph


# -------------------------------
# Authentication
# -------------------------------

Write-Host ""
Write-Host "Connecting to Azure..." -ForegroundColor Cyan

Connect-AzAccount


# -------------------------------
# Validate Inventory access
# -------------------------------

Write-Host ""
Write-Host "Testing Power Platform Inventory access..." -ForegroundColor Cyan


$testQuery = @"
PowerPlatformResources
| take 1
"@


try {

    $testResult = Search-AzGraph -Query $testQuery

}
catch {

    Write-Error "Unable to query Power Platform Inventory."
    Write-Error $_
    exit
}


if (-not $testResult) {

    Write-Error "
No inventory data returned.

Verify:
- Power Platform Inventory is enabled
- Your account has permission to query inventory
"
    exit
}


Write-Host "Inventory access confirmed." -ForegroundColor Green



# -------------------------------
# Query resources
# -------------------------------

$query = @"
PowerPlatformResources
| where type in (
    "microsoft.powerautomate/cloudflows",
    "microsoft.powerapps/apps"
)
| extend props=parse_json(properties)
| mv-expand connector=props.powerPlatformConnectors
| where tostring(connector.connectorId) == "shared_onedrive"
| project
    ResourceType=type,
    Name=tostring(props.displayName),
    ResourceId=name,
    Environment=tostring(props.environmentId),
    OwnerId=tostring(props.ownerId),
    Created=tostring(coalesce(props.createdAt, props.createdTime)),
    Modified=tostring(coalesce(props.lastModifiedAt, props.lastModifiedTime)),
    Status=tostring(props.status),
    Connector=tostring(connector.connectorId)
| order by ResourceType, Name
"@



# -------------------------------
# Execute query with pagination
# -------------------------------

Write-Host ""
Write-Host "Searching for OneDrive Consumer connector usage..." -ForegroundColor Cyan


$results = @()

$skipToken = $null


do {

    if ($skipToken) {

        $page = Search-AzGraph `
            -Query $query `
            -First 1000 `
            -SkipToken $skipToken

    }
    else {

        $page = Search-AzGraph `
            -Query $query `
            -First 1000

    }


    # Handle newer response format
    if ($page.Data) {

        $results += $page.Data
        $skipToken = $page.SkipToken

    }
    else {

        # Handle older Az.ResourceGraph response format
        $results += $page
        $skipToken = $null

    }


}
while ($skipToken)



# -------------------------------
# Results
# -------------------------------

Write-Host ""

if ($results.Count -eq 0) {

    Write-Host `
        "No resources found using OneDrive Consumer connector." `
        -ForegroundColor Green

    exit
}


Write-Host `
    "Found $($results.Count) resources using OneDrive Consumer." `
    -ForegroundColor Yellow


$results |
    Select-Object `
        ResourceType,
        Name,
        Environment,
        OwnerId,
        Modified,
        Status,
        Connector |
    Format-Table -AutoSize



# -------------------------------
# Export CSV
# -------------------------------

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$outputPath = Join-Path `
    ([Environment]::GetFolderPath("Desktop")) `
    "OneDriveConsumer-Connector-Impact-$timestamp.csv"


$results |
    Export-Csv `
        -Path $outputPath `
        -NoTypeInformation `
        -Encoding UTF8



Write-Host ""
Write-Host "CSV report created:" -ForegroundColor Green
Write-Host $outputPath -ForegroundColor Cyan
Write-Host ""
Write-Host "Complete." -ForegroundColor Green