<#
.SYNOPSIS
    Exports an inventory of Dataverse table/message combinations that support
    custom plug-in registration.

.DESCRIPTION
    Queries Dataverse metadata to determine where a custom SDK Message Processing
    Step (plug-in) may be registered.

    The authoritative source is the SdkMessageFilter table. Each row joins a message
    (Create, Update, Assign, ...) to a table, and the IsCustomProcessingStepAllowed
    column declares whether Dataverse permits a custom plug-in step on that pair.

    Results are joined to table metadata so the output can be searched by friendly
    display name as well as logical name.

    IMPORTANT - interpreting the results:
      * A pair appearing in this export means registration is *permitted*. It does
        not guarantee the message is raised by any particular user action or UI.
      * Microsoft blocks custom steps on the singular Create/Update/Delete messages
        for some system tables while still allowing CreateMultiple/UpdateMultiple.
        Dataverse raises the *Multiple* event with a single-record Targets
        collection for ordinary single-record operations, so a step on
        CreateMultiple still fires on a single create.
        See: https://learn.microsoft.com/power-apps/developer/data-platform/bulk-operations
      * Registering steps on Microsoft-managed tables may be unsupported even when
        technically accepted. Confirm supportability before relying on it.

.PARAMETER EnvironmentUrl
    Dataverse environment URL, e.g. https://contoso.crm.dynamics.com

.PARAMETER OutputFile
    Path for the CSV output. Defaults to .\DataversePluginCompatibility.csv

.PARAMETER TableFilter
    Optional wildcard filter applied to table display name, logical name and schema
    name. Example: -TableFilter '*account*'

.PARAMETER IncludeAllMessages
    Include every table/message pair, adding a CustomProcessingStepAllowed column of
    True/False, rather than only the allowed pairs. Useful for seeing what is blocked.

.PARAMETER ApiVersion
    Dataverse Web API version. Defaults to v9.2

.EXAMPLE
    .\Export-DataversePluginCompatibility.ps1 -EnvironmentUrl https://contoso.crm.dynamics.com

.EXAMPLE
    .\Export-DataversePluginCompatibility.ps1 -EnvironmentUrl https://contoso.crm.dynamics.com `
        -TableFilter '*ai*' -IncludeAllMessages -OutputFile .\AiTables.csv

.NOTES
    Requires PowerShell 7+ and Azure CLI, signed in via 'az login'.
    The signed-in user needs read access to Dataverse metadata (System Customizer
    or equivalent).
#>

#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^https://', ErrorMessage = "EnvironmentUrl must start with https://")]
    [string] $EnvironmentUrl,

    [string] $OutputFile = ".\DataversePluginCompatibility.csv",

    [string] $TableFilter,

    [switch] $IncludeAllMessages,

    [string] $ApiVersion = "v9.2"
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-DataverseToken {
    param([Parameter(Mandatory)][string] $Resource)

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI ('az') was not found on PATH. Install it from https://aka.ms/installazurecli"
    }

    $token = az account get-access-token --resource $Resource --query accessToken --output tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw "Unable to obtain a Dataverse access token for '$Resource'. Run 'az login' (and 'az account set --subscription <id>' if needed), then retry."
    }
    return $token
}

function Invoke-DataverseQuery {
    <#
        Issues a Web API GET and follows @odata.nextLink until all pages are read.
        $RelativeUri is appended to the API base, e.g. 'sdkmessages?$select=name'
    #>
    param(
        [Parameter(Mandatory)][string] $RelativeUri,
        [Parameter(Mandatory)][string] $BaseUrl,
        [Parameter(Mandatory)][hashtable] $Headers
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $uri     = $BaseUrl + $RelativeUri

    while ($uri) {
        try {
            $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $Headers
        }
        catch {
            $detail = $null
            if ($_.ErrorDetails.Message) {
                try { $detail = ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch { $detail = $_.ErrorDetails.Message }
            }
            throw "Dataverse query failed.`n  URI   : $uri`n  Error : $(if ($detail) { $detail } else { $_.Exception.Message })"
        }

        if ($response.value) { $results.AddRange([object[]]$response.value) }
        $uri = $response.'@odata.nextLink'
    }

    return $results
}

function Save-Csv {
    <#
        Writes the CSV, giving a clear message if the target file is locked
        (commonly because it is open in Excel).
    #>
    param(
        [Parameter(Mandatory)] $Data,
        [Parameter(Mandatory)][string] $Path
    )

    try {
        $Data | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    }
    catch [System.IO.IOException] {
        throw "Could not write '$Path' because the file is in use. Close it (for example in Excel) or pass a different -OutputFile, then retry."
    }
    return (Resolve-Path $Path).Path
}

# ---------------------------------------------------------------------------
# Connect
# ---------------------------------------------------------------------------

$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
$baseUrl        = "$EnvironmentUrl/api/data/$ApiVersion/"

Write-Host "Environment : $EnvironmentUrl" -ForegroundColor Cyan
Write-Host "API version : $ApiVersion"     -ForegroundColor Cyan

Write-Verbose "Requesting access token..."
$accessToken = Get-DataverseToken -Resource $EnvironmentUrl

$headers = @{
    Authorization      = "Bearer $accessToken"
    Accept             = 'application/json'
    'OData-MaxVersion' = '4.0'
    'OData-Version'    = '4.0'
    Prefer             = 'odata.maxpagesize=5000'
}

# ---------------------------------------------------------------------------
# 1. Table metadata - maps logical name to display/schema name
# ---------------------------------------------------------------------------

Write-Host "Retrieving table metadata..." -ForegroundColor Yellow

$entities = Invoke-DataverseQuery -BaseUrl $baseUrl -Headers $headers -RelativeUri (
    'EntityDefinitions?$select=LogicalName,SchemaName,DisplayName,IsCustomEntity'
)

$entityMap = @{}
foreach ($entity in $entities) {
    $displayName = $entity.DisplayName.UserLocalizedLabel.Label
    if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $entity.SchemaName }

    $entityMap[$entity.LogicalName] = [PSCustomObject]@{
        DisplayName = $displayName
        SchemaName  = $entity.SchemaName
        IsCustom    = [bool]$entity.IsCustomEntity
    }
}

Write-Host "  $($entities.Count) tables." -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# 2. SDK messages and their filters
#
#    Single-quoted strings are used so that $select / $filter / $expand reach the
#    server literally; PowerShell must not expand them as variables.
# ---------------------------------------------------------------------------

Write-Host "Retrieving SDK message metadata..." -ForegroundColor Yellow

$filterClause = if ($IncludeAllMessages) {
    '$filter=isvisible eq true'
} else {
    '$filter=iscustomprocessingstepallowed eq true and isvisible eq true'
}

$messageQuery = 'sdkmessages?$select=name' +
                '&$filter=isprivate eq false' +
                '&$expand=sdkmessageid_sdkmessagefilter(' +
                    '$select=primaryobjecttypecode,iscustomprocessingstepallowed,isvisible;' +
                    $filterClause +
                ')' +
                '&$orderby=name'

$messages = Invoke-DataverseQuery -BaseUrl $baseUrl -Headers $headers -RelativeUri $messageQuery

Write-Host "  $($messages.Count) messages." -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# 3. Flatten into table/message rows
# ---------------------------------------------------------------------------

$results = foreach ($message in $messages) {
    foreach ($msgFilter in $message.sdkmessageid_sdkmessagefilter) {

        $logicalName = $msgFilter.primaryobjecttypecode

        # 'none' denotes a message that is not bound to a specific table.
        if ([string]::IsNullOrWhiteSpace($logicalName) -or $logicalName -eq 'none') { continue }

        $meta = $entityMap[$logicalName]

        if ($TableFilter) {
            $candidates = @($logicalName, $meta.DisplayName, $meta.SchemaName) | Where-Object { $_ }
            if (-not ($candidates | Where-Object { $_ -like $TableFilter })) { continue }
        }

        [PSCustomObject]@{
            TableDisplayName            = $meta.DisplayName
            TableLogicalName            = $logicalName
            TableSchemaName             = $meta.SchemaName
            IsCustomTable               = $meta.IsCustom
            Message                     = $message.name
            CustomProcessingStepAllowed = [bool]$msgFilter.iscustomprocessingstepallowed
        }
    }
}

$results = @($results | Sort-Object TableDisplayName, TableLogicalName, Message)

if ($results.Count -eq 0) {
    Write-Warning "No matching table/message pairs were found$(if ($TableFilter) { " for TableFilter '$TableFilter'" })."
    return
}

# ---------------------------------------------------------------------------
# 4. Summary and export
# ---------------------------------------------------------------------------

$distinctTables = ($results.TableLogicalName | Sort-Object -Unique).Count

Write-Host ""
Write-Host "Table/message pairs : $($results.Count)" -ForegroundColor Green
Write-Host "Distinct tables     : $distinctTables"   -ForegroundColor Green

if ($IncludeAllMessages) {
    $allowed = @($results | Where-Object CustomProcessingStepAllowed).Count
    Write-Host "  Plug-in allowed   : $allowed"                       -ForegroundColor Green
    Write-Host "  Plug-in blocked   : $($results.Count - $allowed)"   -ForegroundColor DarkYellow
}

$savedPath = Save-Csv -Data $results -Path $OutputFile

Write-Host ""
Write-Host "Export complete: $savedPath" -ForegroundColor Green

# Emit to the pipeline so the script can be composed with other commands.
return $results
