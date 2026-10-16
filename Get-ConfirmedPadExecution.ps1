<#
.SYNOPSIS
Exports recorded Power Automate desktop-flow executions across Power Platform
environments.

.DESCRIPTION
This script is read-only. It enumerates Power Platform environments, connects
to each Dataverse organization, and queries the Flow Session (flowsession)
table. Microsoft documents this table as the store for information generated
when a Power Automate desktop flow runs.

The script creates:
  - A detailed CSV with one row per recorded desktop-flow execution.
  - A summary CSV grouped by the Windows account in sessionusername.
  - A coverage CSV showing which environments were queried or skipped.

This report confirms recorded execution, not current software installation.
An execution proves that Power Automate for desktop or its machine runtime ran
on the recorded machine at that time. Hosted, shared, and unattended machines
may not be the user's own desktop.

.NOTES
Required module:
  Microsoft.PowerApps.Administration.PowerShell

Interactive mode:
The signed-in account should be a Power Platform administrator or global
administrator. It must also be provisioned in each Dataverse environment with
read access to the Flow Session table.

If the Power Apps authentication client can't obtain a Dataverse token, the
script automatically falls back to Az.Accounts device-code authentication.
Az.Accounts is required only when that fallback is used.

Service-principal mode:
The Entra application must be registered as a Power Platform management
application and must exist as an application user with Flow Session read access
in every Dataverse environment being scanned.

Run history is subject to each environment's retention and cleanup policies.
Absence from this report does not prove that PAD was never installed or used.

.EXAMPLE
.\Get-ConfirmedPadExecution.ps1 `
  -TenantId "00000000-0000-0000-0000-000000000000" `
  -RunLookbackDays 90 `
  -OutputPath ".\Confirmed-PAD-Execution.csv"

.EXAMPLE
.\Get-ConfirmedPadExecution.ps1 `
  -TenantId "00000000-0000-0000-0000-000000000000" `
  -EnvironmentName "Default-00000000-0000-0000-0000-000000000000" `
  -RunLookbackDays 30

.EXAMPLE
$secret = Read-Host "Client secret" -AsSecureString

.\Get-ConfirmedPadExecution.ps1 `
  -TenantId "00000000-0000-0000-0000-000000000000" `
  -ApplicationId "11111111-1111-1111-1111-111111111111" `
  -ClientSecret $secret `
  -RunLookbackDays 90
#>

[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
    [Parameter(Mandatory)]
    [guid]$TenantId,

    [Parameter(Mandatory, ParameterSetName = 'ServicePrincipal')]
    [guid]$ApplicationId,

    [Parameter(Mandatory, ParameterSetName = 'ServicePrincipal')]
    [Security.SecureString]$ClientSecret,

    [Parameter()]
    [ValidateRange(1, 3650)]
    [int]$RunLookbackDays = 90,

    [Parameter()]
    [string]$EnvironmentName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = (
        Join-Path $PWD (
            'Confirmed-PAD-Execution-{0}.csv' -f
            (Get-Date -Format 'yyyyMMdd-HHmmss')
        )
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:UseAzTokenFallback = (
    $PSCmdlet.ParameterSetName -eq 'Interactive'
)
$script:AzDeviceCodeAuthenticated = $false
$script:UseAzForDataverse = $false

function Assert-RequiredModule {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not (Get-Module -ListAvailable -Name $Name)) {
        throw @"
Required module '$Name' is not installed.

Install it for the current user:
  Install-Module $Name -Scope CurrentUser
"@
    }

    Import-Module $Name -DisableNameChecking -ErrorAction Stop
}

function Get-PropertyValue {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary] -and
        $InputObject.Contains($Name)) {
        return $InputObject[$Name]
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }

    return $null
}

function Get-FormattedValue {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$PropertyName
    )

    $annotation = (
        "$PropertyName@OData.Community.Display.V1.FormattedValue"
    )
    return [string](
        Get-PropertyValue -InputObject $InputObject -Name $annotation
    )
}

function ConvertFrom-SecureToken {
    param(
        [Parameter(Mandatory)]
        [Security.SecureString]$SecureToken
    )

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
        $SecureToken
    )
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Get-TokenString {
    param(
        [Parameter(Mandatory)]
        [object]$TokenResult
    )

    if ($TokenResult -is [string]) {
        return $TokenResult
    }

    if ($TokenResult -is [Security.SecureString]) {
        return ConvertFrom-SecureToken -SecureToken $TokenResult
    }

    $token = Get-PropertyValue -InputObject $TokenResult -Name 'Token'
    if ($token -is [Security.SecureString]) {
        return ConvertFrom-SecureToken -SecureToken $token
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$token)) {
        return [string]$token
    }

    throw 'Authentication succeeded but did not return a usable access token.'
}

function Get-DataverseAccessToken {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceUrl
    )

    if ($script:UseAzForDataverse) {
        $azToken = Get-AzAccessToken `
            -TenantId $TenantId `
            -ResourceUrl $ResourceUrl

        return Get-TokenString -TokenResult $azToken
    }

    try {
        $tokenResult = Get-JwtToken -Audience $ResourceUrl
        return Get-TokenString -TokenResult $tokenResult
    }
    catch {
        $powerAppsTokenError = $_.Exception.Message
        if (-not $script:UseAzTokenFallback) {
            throw
        }

        Write-Warning (
            'The Power Apps authentication client could not obtain a ' +
            'Dataverse token. Falling back to Az.Accounts device-code ' +
            'authentication.'
        )

        try {
            Assert-RequiredModule -Name 'Az.Accounts'

            if (-not $script:AzDeviceCodeAuthenticated) {
                Write-Host (
                    'Complete the device-code sign-in using the intended ' +
                    'customer account and tenant.'
                ) -ForegroundColor Yellow

                Connect-AzAccount `
                    -Tenant $TenantId `
                    -UseDeviceAuthentication `
                    -Scope Process | Out-Null

                $script:AzDeviceCodeAuthenticated = $true
            }

            $script:UseAzForDataverse = $true
            $azToken = Get-AzAccessToken `
                -TenantId $TenantId `
                -ResourceUrl $ResourceUrl

            return Get-TokenString -TokenResult $azToken
        }
        catch {
            throw @"
Both Dataverse authentication methods failed.

Power Apps authentication error:
$powerAppsTokenError

Az.Accounts authentication error:
$($_.Exception.Message)
"@
        }
    }
}

function Get-DataverseUrl {
    param(
        [Parameter(Mandatory)]
        [object]$Environment
    )

    $directUrl = Get-PropertyValue `
        -InputObject $Environment `
        -Name 'EnvironmentUrl'

    if ([string]$directUrl -match '^https://') {
        return ([string]$directUrl).TrimEnd('/')
    }

    $internal = Get-PropertyValue -InputObject $Environment -Name 'Internal'
    $properties = Get-PropertyValue -InputObject $internal -Name 'properties'

    $linkedMetadata = Get-PropertyValue `
        -InputObject $properties `
        -Name 'linkedEnvironmentMetadata'

    $instanceUrl = Get-PropertyValue `
        -InputObject $linkedMetadata `
        -Name 'instanceUrl'

    if ([string]$instanceUrl -match '^https://') {
        return ([string]$instanceUrl).TrimEnd('/')
    }

    $runtimeEndpoints = Get-PropertyValue `
        -InputObject $properties `
        -Name 'runtimeEndpoints'

    foreach ($endpointName in @(
        'microsoft.CommonDataModel',
        'microsoft.DynamicsCRM'
    )) {
        $endpoint = Get-PropertyValue `
            -InputObject $runtimeEndpoints `
            -Name $endpointName

        if ([string]$endpoint -match '^https://') {
            return ([string]$endpoint).TrimEnd('/')
        }
    }

    return $null
}

function Get-HttpStatusCode {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $responseProperty = $ErrorRecord.Exception.PSObject.Properties['Response']
    if (-not $responseProperty) {
        return $null
    }

    $response = $responseProperty.Value
    if ($null -eq $response) {
        return $null
    }

    $statusProperty = $response.PSObject.Properties['StatusCode']
    if (-not $statusProperty) {
        return $null
    }

    try {
        return [int]$statusProperty.Value
    }
    catch {
        return $null
    }
}

function Invoke-DataverseGet {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [Parameter()]
        [ValidateRange(1, 10)]
        [int]$MaxAttempts = 6
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return Invoke-RestMethod `
                -Method Get `
                -Uri $Uri `
                -Headers $Headers `
                -TimeoutSec 180
        }
        catch {
            $statusCode = Get-HttpStatusCode -ErrorRecord $_
            $isRetryable = (
                $statusCode -eq 429 -or
                $statusCode -eq 408 -or
                ($statusCode -ge 500 -and $statusCode -le 599)
            )

            if (-not $isRetryable -or $attempt -eq $MaxAttempts) {
                $details = [string]$_.ErrorDetails.Message
                if ([string]::IsNullOrWhiteSpace($details)) {
                    $details = $_.Exception.Message
                }

                if ($statusCode) {
                    throw "Dataverse GET failed (HTTP $statusCode): $Uri`n$details"
                }

                throw "Dataverse GET failed: $Uri`n$details"
            }

            $delaySeconds = [Math]::Min(
                60,
                [Math]::Pow(2, $attempt)
            )
            Write-Warning (
                "Dataverse returned HTTP {0}. Retrying in {1} seconds " +
                "(attempt {2} of {3})." -f
                $statusCode,
                $delaySeconds,
                $attempt,
                $MaxAttempts
            )
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

function Get-DataverseCollection {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [Parameter()]
        [string]$Activity = 'Dataverse records'
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $nextLink = $Uri
    $pageNumber = 0

    while (-not [string]::IsNullOrWhiteSpace($nextLink)) {
        $pageNumber++
        Write-Host (
            "  Downloading {0}, page {1}..." -f
            $Activity,
            $pageNumber
        ) -ForegroundColor DarkGray

        $response = Invoke-DataverseGet `
            -Uri $nextLink `
            -Headers $Headers

        $values = Get-PropertyValue -InputObject $response -Name 'value'
        foreach ($value in @($values)) {
            if ($null -ne $value) {
                $items.Add($value)
            }
        }

        Write-Host (
            "  Downloaded {0:N0} record(s) so far." -f
            $items.Count
        ) -ForegroundColor DarkGray

        $nextLink = [string](
            Get-PropertyValue `
                -InputObject $response `
                -Name '@odata.nextLink'
        )
    }

    return $items
}

function New-StringSet {
    $set = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )

    Write-Output -NoEnumerate $set
}

function Add-NonEmptyValue {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$Set,

        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    $text = [string]$Value
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        [void]$Set.Add($text.Trim())
    }
}

function Join-Set {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$Set
    )

    return (($Set | Sort-Object) -join '; ')
}

function Get-RunModeLabel {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value,

        [Parameter()]
        [AllowNull()]
        [string]$FormattedValue
    )

    if (-not [string]::IsNullOrWhiteSpace($FormattedValue)) {
        return $FormattedValue
    }

    switch ([string]$Value) {
        '0' { return 'Local' }
        '1' { return 'Attended' }
        '2' { return 'Unattended' }
        default { return [string]$Value }
    }
}

Assert-RequiredModule -Name 'Microsoft.PowerApps.Administration.PowerShell'

$outputDirectory = Split-Path -Parent $OutputPath
if ([string]::IsNullOrWhiteSpace($outputDirectory)) {
    $outputDirectory = $PWD.Path
    $OutputPath = Join-Path $outputDirectory $OutputPath
}

if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$baseName = [IO.Path]::GetFileNameWithoutExtension($OutputPath)
$summaryPath = Join-Path $outputDirectory "$baseName-summary.csv"
$coveragePath = Join-Path $outputDirectory "$baseName-coverage.csv"

if ($PSCmdlet.ParameterSetName -eq 'ServicePrincipal') {
    Write-Host (
        'Signing in to Power Platform administration with the service ' +
        'principal...'
    ) -ForegroundColor Cyan

    $plainTextClientSecret = ConvertFrom-SecureToken `
        -SecureToken $ClientSecret

    try {
        Add-PowerAppsAccount `
            -Endpoint 'prod' `
            -TenantID $TenantId `
            -ApplicationId $ApplicationId `
            -ClientSecret $plainTextClientSecret | Out-Null
    }
    finally {
        $plainTextClientSecret = $null
    }
}
else {
    Write-Host (
        'Signing in to Power Platform administration interactively...'
    ) -ForegroundColor Cyan
    Add-PowerAppsAccount -Endpoint 'prod' -TenantID $TenantId | Out-Null
}

$environments = @(Get-AdminPowerAppEnvironment)
if (-not [string]::IsNullOrWhiteSpace($EnvironmentName)) {
    $environments = @(
        $environments |
            Where-Object {
                [string](
                    Get-PropertyValue `
                        -InputObject $_ `
                        -Name 'EnvironmentName'
                ) -eq $EnvironmentName -or
                [string](
                    Get-PropertyValue `
                        -InputObject $_ `
                        -Name 'DisplayName'
                ) -eq $EnvironmentName
            }
    )

    if ($environments.Count -eq 0) {
        throw "No environment matched '$EnvironmentName'."
    }
}

$lookbackUtc = [DateTimeOffset]::UtcNow.AddDays(-$RunLookbackDays)
$lookbackFilter = $lookbackUtc.ToString(
    'yyyy-MM-ddTHH:mm:ssZ',
    [Globalization.CultureInfo]::InvariantCulture
)

$detailRows = [System.Collections.Generic.List[object]]::new()
$coverageRows = [System.Collections.Generic.List[object]]::new()

foreach ($environment in $environments) {
    $environmentId = [string](
        Get-PropertyValue -InputObject $environment -Name 'EnvironmentName'
    )
    $environmentDisplayName = [string](
        Get-PropertyValue -InputObject $environment -Name 'DisplayName'
    )
    if ([string]::IsNullOrWhiteSpace($environmentDisplayName)) {
        $environmentDisplayName = $environmentId
    }

    $dataverseUrl = Get-DataverseUrl -Environment $environment
    if ([string]::IsNullOrWhiteSpace($dataverseUrl)) {
        $coverageRows.Add([pscustomobject]@{
            EnvironmentName = $environmentId
            EnvironmentDisplayName = $environmentDisplayName
            DataverseUrl = $null
            Status = 'Skipped - no Dataverse URL'
            RecordedRunCount = 0
            Message = 'The environment does not expose a Dataverse organization URL.'
        })
        continue
    }

    Write-Host (
        "Reading recorded desktop-flow executions from '{0}'..." -f
        $environmentDisplayName
    ) -ForegroundColor DarkCyan

    try {
        Write-Host '  Acquiring Dataverse access token...' `
            -ForegroundColor DarkGray
        $accessToken = Get-DataverseAccessToken `
            -ResourceUrl $dataverseUrl
        Write-Host '  Access token acquired.' -ForegroundColor DarkGray

        $headers = @{
            Authorization = "Bearer $accessToken"
            Accept = 'application/json'
            'OData-Version' = '4.0'
            'OData-MaxVersion' = '4.0'
            Prefer = (
                'odata.include-annotations="' +
                'OData.Community.Display.V1.FormattedValue,' +
                'Microsoft.Dynamics.CRM.lookuplogicalname"'
            )
        }

        $apiRoot = "$dataverseUrl/api/data/v9.2"
        Write-Host '  Testing Dataverse access...' -ForegroundColor DarkGray
        Invoke-DataverseGet `
            -Uri "$apiRoot/WhoAmI" `
            -Headers $headers | Out-Null
        Write-Host '  Dataverse access confirmed.' -ForegroundColor DarkGray

        $select = @(
            'flowsessionid',
            'name',
            '_regardingobjectid_value',
            '_createdby_value',
            '_ownerid_value',
            '_machineid_value',
            '_machinegroupid_value',
            'sessionusername',
            'startedon',
            'completedon',
            'statecode',
            'statuscode',
            'runmode',
            'runsessionmode',
            'triggertype',
            'errorcode',
            'errormessage',
            'parentcloudflowrunsequenceid'
        ) -join ','

        $sessionUri = (
            "$apiRoot/flowsessions?" +
            "`$select=$select&" +
            "`$filter=startedon ge $lookbackFilter&" +
            '$orderby=startedon asc'
        )

        $sessions = @(
            Get-DataverseCollection `
                -Uri $sessionUri `
                -Headers $headers `
                -Activity (
                    "Flow Session records from '$environmentDisplayName'"
                )
        )

        foreach ($session in $sessions) {
            $startedOn = $null
            if ($session.startedon) {
                $startedOn = [DateTimeOffset]$session.startedon
            }

            $completedOn = $null
            if ($session.completedon) {
                $completedOn = [DateTimeOffset]$session.completedon
            }

            $durationSeconds = $null
            if ($startedOn -and $completedOn) {
                $durationSeconds = [Math]::Round(
                    ($completedOn - $startedOn).TotalSeconds,
                    2
                )
            }

            $executionAccount = [string]$session.sessionusername
            $accountEvidence = 'Recorded in Flow Session sessionusername'
            if ([string]::IsNullOrWhiteSpace($executionAccount)) {
                $executionAccount = '(not recorded)'
                $accountEvidence = 'Execution confirmed; account not recorded'
            }

            $detailRows.Add([pscustomobject]@{
                EnvironmentDisplayName = $environmentDisplayName
                EnvironmentName = $environmentId
                DataverseUrl = $dataverseUrl
                FlowSessionId = [string]$session.flowsessionid
                DesktopFlowName = (
                    Get-FormattedValue `
                        -InputObject $session `
                        -PropertyName '_regardingobjectid_value'
                )
                DesktopFlowId = [string](
                    Get-PropertyValue `
                        -InputObject $session `
                        -Name '_regardingobjectid_value'
                )
                ExecutionAccount = $executionAccount
                AccountEvidence = $accountEvidence
                MachineName = (
                    Get-FormattedValue `
                        -InputObject $session `
                        -PropertyName '_machineid_value'
                )
                MachineId = [string](
                    Get-PropertyValue `
                        -InputObject $session `
                        -Name '_machineid_value'
                )
                MachineGroupName = (
                    Get-FormattedValue `
                        -InputObject $session `
                        -PropertyName '_machinegroupid_value'
                )
                MachineGroupId = [string](
                    Get-PropertyValue `
                        -InputObject $session `
                        -Name '_machinegroupid_value'
                )
                InitiatingUserName = (
                    Get-FormattedValue `
                        -InputObject $session `
                        -PropertyName '_createdby_value'
                )
                InitiatingUserId = [string](
                    Get-PropertyValue `
                        -InputObject $session `
                        -Name '_createdby_value'
                )
                FlowSessionOwnerName = (
                    Get-FormattedValue `
                        -InputObject $session `
                        -PropertyName '_ownerid_value'
                )
                FlowSessionOwnerId = [string](
                    Get-PropertyValue `
                        -InputObject $session `
                        -Name '_ownerid_value'
                )
                StartedOnUtc = $startedOn
                CompletedOnUtc = $completedOn
                DurationSeconds = $durationSeconds
                RunMode = (
                    Get-RunModeLabel `
                        -Value $session.runmode `
                        -FormattedValue (
                            Get-FormattedValue `
                                -InputObject $session `
                                -PropertyName 'runmode'
                        )
                )
                RunSessionMode = (
                    Get-FormattedValue `
                        -InputObject $session `
                        -PropertyName 'runsessionmode'
                )
                TriggerType = (
                    Get-FormattedValue `
                        -InputObject $session `
                        -PropertyName 'triggertype'
                )
                Status = (
                    Get-FormattedValue `
                        -InputObject $session `
                        -PropertyName 'statuscode'
                )
                State = (
                    Get-FormattedValue `
                        -InputObject $session `
                        -PropertyName 'statecode'
                )
                ErrorCode = [string]$session.errorcode
                ErrorMessage = [string]$session.errormessage
                ParentCloudFlowRunSequenceId = [string](
                    $session.parentcloudflowrunsequenceid
                )
            })
        }

        $coverageRows.Add([pscustomobject]@{
            EnvironmentName = $environmentId
            EnvironmentDisplayName = $environmentDisplayName
            DataverseUrl = $dataverseUrl
            Status = 'Queried'
            RecordedRunCount = $sessions.Count
            Message = $null
        })
    }
    catch {
        $coverageRows.Add([pscustomobject]@{
            EnvironmentName = $environmentId
            EnvironmentDisplayName = $environmentDisplayName
            DataverseUrl = $dataverseUrl
            Status = 'Failed'
            RecordedRunCount = 0
            Message = $_.Exception.Message
        })

        Write-Warning (
            "Could not query environment '{0}': {1}" -f
            $environmentDisplayName,
            $_.Exception.Message
        )
    }
}

$detailRows |
    Sort-Object StartedOnUtc, EnvironmentDisplayName |
    Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8

$summaryGroups = @{}
foreach ($row in $detailRows) {
    $key = $row.ExecutionAccount.Trim().ToLowerInvariant()
    if (-not $summaryGroups.ContainsKey($key)) {
        $summaryGroups[$key] = [pscustomobject]@{
            ExecutionAccount = $row.ExecutionAccount
            Environments = New-StringSet
            DesktopFlows = New-StringSet
            Machines = New-StringSet
            MachineGroups = New-StringSet
            RunModes = New-StringSet
            InitiatingUsers = New-StringSet
            RunCount = 0
            SuccessfulRunCount = 0
            FailedRunCount = 0
            FirstRecordedRunUtc = $null
            LastRecordedRunUtc = $null
        }
    }

    $summary = $summaryGroups[$key]
    $summary.RunCount++
    Add-NonEmptyValue -Set $summary.Environments -Value (
        $row.EnvironmentDisplayName
    )
    Add-NonEmptyValue -Set $summary.DesktopFlows -Value (
        "{0}: {1}" -f $row.EnvironmentDisplayName, $row.DesktopFlowName
    )
    Add-NonEmptyValue -Set $summary.Machines -Value $row.MachineName
    Add-NonEmptyValue -Set $summary.MachineGroups -Value $row.MachineGroupName
    Add-NonEmptyValue -Set $summary.RunModes -Value $row.RunMode
    Add-NonEmptyValue -Set $summary.InitiatingUsers -Value (
        $row.InitiatingUserName
    )

    if ([string]$row.Status -match '(?i)succeed|complete') {
        $summary.SuccessfulRunCount++
    }
    elseif ([string]$row.Status -match '(?i)fail|cancel|error') {
        $summary.FailedRunCount++
    }

    if ($row.StartedOnUtc) {
        $started = [DateTimeOffset]$row.StartedOnUtc
        if ($null -eq $summary.FirstRecordedRunUtc -or
            $started -lt $summary.FirstRecordedRunUtc) {
            $summary.FirstRecordedRunUtc = $started
        }
        if ($null -eq $summary.LastRecordedRunUtc -or
            $started -gt $summary.LastRecordedRunUtc) {
            $summary.LastRecordedRunUtc = $started
        }
    }
}

$summaryRows = @(
    foreach ($key in ($summaryGroups.Keys | Sort-Object)) {
        $summary = $summaryGroups[$key]
        [pscustomobject]@{
            ExecutionAccount = $summary.ExecutionAccount
            AccountRecorded = (
                $summary.ExecutionAccount -ne '(not recorded)'
            )
            EnvironmentCount = $summary.Environments.Count
            Environments = Join-Set -Set $summary.Environments
            RunCount = $summary.RunCount
            SuccessfulRunCount = $summary.SuccessfulRunCount
            FailedRunCount = $summary.FailedRunCount
            FirstRecordedRunUtc = $summary.FirstRecordedRunUtc
            LastRecordedRunUtc = $summary.LastRecordedRunUtc
            RunModes = Join-Set -Set $summary.RunModes
            Machines = Join-Set -Set $summary.Machines
            MachineGroups = Join-Set -Set $summary.MachineGroups
            DesktopFlows = Join-Set -Set $summary.DesktopFlows
            InitiatingUsers = Join-Set -Set $summary.InitiatingUsers
            RunLookbackDays = $RunLookbackDays
        }
    }
)

$summaryRows |
    Sort-Object ExecutionAccount |
    Export-Csv -LiteralPath $summaryPath -NoTypeInformation -Encoding UTF8

$coverageRows |
    Sort-Object EnvironmentDisplayName |
    Export-Csv -LiteralPath $coveragePath -NoTypeInformation -Encoding UTF8

$queriedEnvironmentCount = @(
    $coverageRows | Where-Object Status -eq 'Queried'
).Count
$failedEnvironmentCount = @(
    $coverageRows | Where-Object Status -eq 'Failed'
).Count

Write-Host ''
Write-Host 'Complete.' -ForegroundColor Green
Write-Host (
    "Recorded executions: {0}" -f $detailRows.Count
) -ForegroundColor Green
Write-Host (
    "Execution accounts: {0}" -f $summaryRows.Count
) -ForegroundColor Green
Write-Host (
    "Environments queried: {0}; failed: {1}" -f
    $queriedEnvironmentCount,
    $failedEnvironmentCount
) -ForegroundColor Green
Write-Host "Detail:   $OutputPath" -ForegroundColor Green
Write-Host "Summary:  $summaryPath" -ForegroundColor Green
Write-Host "Coverage: $coveragePath" -ForegroundColor Green
