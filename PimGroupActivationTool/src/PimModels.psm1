#Requires -Version 5.1
<#
.SYNOPSIS
    Pure data-model and helper functions for the PIM Group Activation Tool.

.DESCRIPTION
    This module intentionally contains no network calls and no UI code so that every
    function in it can be unit tested without Azure, Microsoft Graph, or WinForms.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Cloud configuration
# ---------------------------------------------------------------------------

# Single source of truth for cloud-specific endpoints. Nothing else in the
# solution may hard-code a Graph host name.
$script:BuiltInCloudConfiguration = @(
    [pscustomobject]@{
        DisplayName      = 'Commercial'
        AzEnvironment    = 'AzureCloud'
        GraphEnvironment = 'Global'
        GraphBaseUri     = 'https://graph.microsoft.com'
        IsBuiltIn        = $true
        IsSupported      = $true
        UnsupportedReason = $null
    }
    [pscustomobject]@{
        DisplayName      = 'US Government'
        AzEnvironment    = 'AzureUSGovernment'
        GraphEnvironment = 'USGov'
        GraphBaseUri     = 'https://graph.microsoft.us'
        IsBuiltIn        = $true
        IsSupported      = $true
        UnsupportedReason = $null
    }
    [pscustomobject]@{
        DisplayName      = 'US Government DoD'
        AzEnvironment    = 'AzureUSGovernment'
        GraphEnvironment = 'USGovDoD'
        GraphBaseUri     = 'https://dod-graph.microsoft.us'
        IsBuiltIn        = $true
        IsSupported      = $true
        UnsupportedReason = $null
    }
)

# Az environment name -> Graph environment name. Used when enumerating Custom
# environments so that a pairing is only offered when it is actually known good.
$script:KnownAzToGraphEnvironmentMap = @{
    'AzureCloud'          = 'Global'
    'AzureUSGovernment'   = 'USGov'
    'AzureChinaCloud'     = 'China'
    'AzureGermanCloud'    = 'Germany'
}

function Get-PimBuiltInCloudConfiguration {
    <#
    .SYNOPSIS
        Returns a copy of the built-in cloud configuration records.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    foreach ($cloud in $script:BuiltInCloudConfiguration) {
        [pscustomobject]@{
            DisplayName       = $cloud.DisplayName
            AzEnvironment     = $cloud.AzEnvironment
            GraphEnvironment  = $cloud.GraphEnvironment
            GraphBaseUri      = $cloud.GraphBaseUri
            IsBuiltIn         = $cloud.IsBuiltIn
            IsSupported       = $cloud.IsSupported
            UnsupportedReason = $cloud.UnsupportedReason
        }
    }
}

function Get-PimCloudConfiguration {
    <#
    .SYNOPSIS
        Returns the cloud configuration records available to the tool.

    .DESCRIPTION
        Without -Name, returns every available cloud. With -Name, returns the single
        matching cloud or throws.

        Custom environments are only produced when -AzEnvironmentName and
        -GraphEnvironmentName lists are supplied (normally from Get-AzEnvironment and
        Get-MgEnvironment). A custom pairing that is not known-good is returned with
        IsSupported = $false and an actionable UnsupportedReason rather than being
        silently pointed at commercial endpoints.

    .PARAMETER Name
        Display name of a single cloud to return.

    .PARAMETER AzEnvironment
        Registered Az environments, as returned by Get-AzEnvironment. Each item must
        expose a Name property and may expose a GraphUrl / MicrosoftGraphUrl property.

    .PARAMETER GraphEnvironment
        Registered Microsoft Graph environments, as returned by Get-MgEnvironment.
        Each item must expose a Name property and may expose GraphEndpoint.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [string] $Name,

        [Parameter()]
        [AllowNull()]
        [object[]] $AzEnvironment,

        [Parameter()]
        [AllowNull()]
        [object[]] $GraphEnvironment
    )

    $all = New-Object System.Collections.Generic.List[object]
    foreach ($cloud in (Get-PimBuiltInCloudConfiguration)) {
        $all.Add($cloud)
    }

    if ($AzEnvironment) {
        $builtInAzNames = @($script:BuiltInCloudConfiguration | ForEach-Object { $_.AzEnvironment })

        foreach ($az in $AzEnvironment) {
            if ($null -eq $az) { continue }

            $azName = Get-PimPropertyValue -InputObject $az -Name 'Name'
            if ([string]::IsNullOrWhiteSpace($azName)) { continue }
            if ($builtInAzNames -contains $azName) { continue }

            $all.Add((New-PimCustomCloudConfiguration -AzEnvironment $az -GraphEnvironment $GraphEnvironment))
        }
    }

    if ($PSBoundParameters.ContainsKey('Name') -and -not [string]::IsNullOrWhiteSpace($Name)) {
        $match = @($all | Where-Object { $_.DisplayName -eq $Name })
        if ($match.Count -eq 0) {
            throw "Unknown cloud '$Name'. Available clouds: $(($all | ForEach-Object { $_.DisplayName }) -join ', ')."
        }
        return $match[0]
    }

    return $all.ToArray()
}

function New-PimCustomCloudConfiguration {
    <#
    .SYNOPSIS
        Builds a cloud configuration record for a non-built-in Az environment.

    .DESCRIPTION
        A custom environment is only marked supported when a compatible Microsoft Graph
        environment is registered AND a Graph endpoint can be resolved. Otherwise the
        record carries an actionable UnsupportedReason, because some sovereign or custom
        Graph environments require a custom app registration, which conflicts with this
        tool's no-app-registration goal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $AzEnvironment,

        [Parameter()]
        [AllowNull()]
        [object[]] $GraphEnvironment
    )

    $azName = Get-PimPropertyValue -InputObject $AzEnvironment -Name 'Name'

    $graphName = $null
    $graphBaseUri = $null
    $reason = $null

    # Prefer an explicit name match, then a known-good mapping.
    $candidateNames = New-Object System.Collections.Generic.List[string]
    $candidateNames.Add($azName)
    if ($script:KnownAzToGraphEnvironmentMap.ContainsKey($azName)) {
        $candidateNames.Add($script:KnownAzToGraphEnvironmentMap[$azName])
    }

    if ($GraphEnvironment) {
        foreach ($candidate in $candidateNames) {
            if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
            $match = @($GraphEnvironment | Where-Object {
                $null -ne $_ -and (Get-PimPropertyValue -InputObject $_ -Name 'Name') -eq $candidate
            })
            if ($match.Count -gt 0) {
                $graphName = Get-PimPropertyValue -InputObject $match[0] -Name 'Name'
                $graphBaseUri = Get-PimPropertyValue -InputObject $match[0] -Name 'GraphEndpoint'
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($graphBaseUri)) {
        foreach ($property in 'MicrosoftGraphUrl', 'GraphUrl', 'ExtendedProperties') {
            $value = Get-PimPropertyValue -InputObject $AzEnvironment -Name $property
            if ($property -eq 'ExtendedProperties') {
                if ($value -is [System.Collections.IDictionary] -and $value.Contains('MicrosoftGraphUrl')) {
                    $value = $value['MicrosoftGraphUrl']
                }
                else {
                    $value = $null
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $graphBaseUri = $value
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($graphName)) {
        $reason = "No Microsoft Graph PowerShell environment is registered for Az environment '$azName'. Register a compatible environment with Add-MgEnvironment, or use a built-in cloud."
    }
    elseif ([string]::IsNullOrWhiteSpace($graphBaseUri)) {
        $reason = "Microsoft Graph environment '$graphName' does not expose a Graph endpoint. This environment likely requires an approved custom app registration, which this tool does not use."
    }

    [pscustomobject]@{
        DisplayName       = "Custom: $azName"
        AzEnvironment     = $azName
        GraphEnvironment  = $graphName
        GraphBaseUri      = (Format-PimBaseUri -Uri $graphBaseUri)
        IsBuiltIn         = $false
        IsSupported       = [bool]([string]::IsNullOrWhiteSpace($reason))
        UnsupportedReason = $reason
    }
}

function Format-PimBaseUri {
    <#
    .SYNOPSIS
        Normalizes a base URI by trimming trailing slashes.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Uri
    )

    if ([string]::IsNullOrWhiteSpace($Uri)) { return $null }
    return $Uri.TrimEnd('/')
}

function Get-PimPropertyValue {
    <#
    .SYNOPSIS
        Safely reads a property from an object, hashtable, or PSObject.

    .DESCRIPTION
        Graph and Az return a mix of hashtables and typed objects depending on module
        version, so every property read goes through this helper. Returns $null when the
        property is absent instead of throwing under Set-StrictMode.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $InputObject[$key]
            }
        }
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }

    # Case-insensitive fallback.
    foreach ($candidate in $InputObject.PSObject.Properties) {
        if ([string]::Equals($candidate.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $candidate.Value
        }
    }

    return $null
}

function Test-PimPropertyExists {
    <#
    .SYNOPSIS
        Returns $true when an object, hashtable, or PSObject defines the named property.

    .DESCRIPTION
        Distinguishes "property is absent" from "property is present but empty or null",
        which Get-PimPropertyValue cannot express because an empty array is indistinguishable
        from $null once it leaves the pipeline.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($null -eq $InputObject) { return $false }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
        return $false
    }

    foreach ($candidate in $InputObject.PSObject.Properties) {
        if ([string]::Equals($candidate.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-PimFirstPropertyValue {
    <#
    .SYNOPSIS
        Returns the first non-empty value found among the supplied property names.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [string[]] $Name
    )

    foreach ($candidate in $Name) {
        $value = Get-PimPropertyValue -InputObject $InputObject -Name $candidate
        if ($null -ne $value -and -not ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
            return $value
        }
    }

    return $null
}

# ---------------------------------------------------------------------------
# Duration handling
# ---------------------------------------------------------------------------

function Get-PimDurationOption {
    <#
    .SYNOPSIS
        Returns the duration choices offered by the UI.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    @(
        [pscustomobject]@{ DisplayName = '30 minutes'; TimeSpan = [timespan]::FromMinutes(30) }
        [pscustomobject]@{ DisplayName = '1 hour';     TimeSpan = [timespan]::FromHours(1) }
        [pscustomobject]@{ DisplayName = '2 hours';    TimeSpan = [timespan]::FromHours(2) }
        [pscustomobject]@{ DisplayName = '4 hours';    TimeSpan = [timespan]::FromHours(4) }
        [pscustomobject]@{ DisplayName = '8 hours';    TimeSpan = [timespan]::FromHours(8) }
    )
}

function ConvertTo-Iso8601Duration {
    <#
    .SYNOPSIS
        Converts a TimeSpan to an ISO 8601 duration string that Microsoft Graph accepts.

    .EXAMPLE
        ConvertTo-Iso8601Duration -TimeSpan ([timespan]::FromMinutes(30))
        PT30M

    .EXAMPLE
        ConvertTo-Iso8601Duration -TimeSpan ([timespan]::FromHours(26))
        P1DT2H
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [timespan] $TimeSpan
    )

    process {
        if ($TimeSpan.Ticks -le 0) {
            throw 'Duration must be greater than zero.'
        }

        if ($TimeSpan.Milliseconds -ne 0) {
            throw 'Duration must not contain fractional seconds.'
        }

        $builder = [System.Text.StringBuilder]::new()
        [void]$builder.Append('P')

        if ($TimeSpan.Days -gt 0) {
            [void]$builder.AppendFormat('{0}D', $TimeSpan.Days)
        }

        if ($TimeSpan.Hours -gt 0 -or $TimeSpan.Minutes -gt 0 -or $TimeSpan.Seconds -gt 0) {
            [void]$builder.Append('T')
            if ($TimeSpan.Hours -gt 0)   { [void]$builder.AppendFormat('{0}H', $TimeSpan.Hours) }
            if ($TimeSpan.Minutes -gt 0) { [void]$builder.AppendFormat('{0}M', $TimeSpan.Minutes) }
            if ($TimeSpan.Seconds -gt 0) { [void]$builder.AppendFormat('{0}S', $TimeSpan.Seconds) }
        }

        return $builder.ToString()
    }
}

function ConvertFrom-Iso8601Duration {
    <#
    .SYNOPSIS
        Parses an ISO 8601 duration string into a TimeSpan.

    .DESCRIPTION
        Supports the day/hour/minute/second subset that PIM uses. Year and month
        components are rejected because they are not convertible to an exact TimeSpan.
    #>
    [CmdletBinding()]
    [OutputType([timespan])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string] $Duration
    )

    process {
        if ([string]::IsNullOrWhiteSpace($Duration)) {
            throw 'Duration must not be empty.'
        }

        $pattern = '^P(?:(?<days>\d+)D)?(?:T(?:(?<hours>\d+)H)?(?:(?<minutes>\d+)M)?(?:(?<seconds>\d+)S)?)?$'
        $match = [regex]::Match($Duration.Trim().ToUpperInvariant(), $pattern)
        if (-not $match.Success) {
            throw "'$Duration' is not a supported ISO 8601 duration. Expected a value such as PT30M, PT2H, or P1DT2H."
        }

        $days    = if ($match.Groups['days'].Success)    { [int]$match.Groups['days'].Value }    else { 0 }
        $hours   = if ($match.Groups['hours'].Success)   { [int]$match.Groups['hours'].Value }   else { 0 }
        $minutes = if ($match.Groups['minutes'].Success) { [int]$match.Groups['minutes'].Value } else { 0 }
        $seconds = if ($match.Groups['seconds'].Success) { [int]$match.Groups['seconds'].Value } else { 0 }

        $result = New-TimeSpan -Days $days -Hours $hours -Minutes $minutes -Seconds $seconds
        if ($result.Ticks -le 0) {
            throw "'$Duration' does not represent a positive duration."
        }

        return $result
    }
}

# ---------------------------------------------------------------------------
# Record factories
# ---------------------------------------------------------------------------

function New-PimTenantRecord {
    <#
    .SYNOPSIS
        Normalizes an Az tenant object (or raw values) into a tenant record.

    .DESCRIPTION
        Get-AzTenant returns different shapes across Az.Accounts versions, so every
        property is read defensively.
    #>
    [CmdletBinding(DefaultParameterSetName = 'FromObject')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'FromObject', ValueFromPipeline)]
        [object] $AzTenant,

        [Parameter(Mandatory, ParameterSetName = 'FromValues')]
        [string] $TenantId,

        [Parameter(ParameterSetName = 'FromValues')]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $TenantDisplayName,

        [Parameter(ParameterSetName = 'FromValues')]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $PrimaryDomain,

        [Parameter(ParameterSetName = 'FromValues')]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Category,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Cloud
    )

    process {
        if ($PSCmdlet.ParameterSetName -eq 'FromObject') {
            $id = Get-PimFirstPropertyValue -InputObject $AzTenant -Name @('TenantId', 'Id')
            if ([string]::IsNullOrWhiteSpace($id)) {
                throw 'Tenant object does not expose a TenantId or Id property.'
            }

            $displayName = Get-PimFirstPropertyValue -InputObject $AzTenant -Name @('Name', 'DisplayName', 'TenantDisplayName')

            $domain = Get-PimFirstPropertyValue -InputObject $AzTenant -Name @('DefaultDomain', 'PrimaryDomain')
            if ([string]::IsNullOrWhiteSpace($domain)) {
                $domains = Get-PimPropertyValue -InputObject $AzTenant -Name 'Domains'
                if ($domains) {
                    $domainList = @($domains)
                    if ($domainList.Count -gt 0) { $domain = [string]$domainList[0] }
                }
            }

            $tenantCategory = Get-PimFirstPropertyValue -InputObject $AzTenant -Name @('TenantCategory', 'Category')
        }
        else {
            $id = $TenantId
            $displayName = $TenantDisplayName
            $domain = $PrimaryDomain
            $tenantCategory = $Category
        }

        if ([string]::IsNullOrWhiteSpace($displayName)) {
            if (-not [string]::IsNullOrWhiteSpace($domain)) { $displayName = $domain } else { $displayName = [string]$id }
        }

        [pscustomobject]@{
            Selected          = $false
            TenantId          = [string]$id
            TenantDisplayName = [string]$displayName
            PrimaryDomain     = if ([string]::IsNullOrWhiteSpace($domain)) { $null } else { [string]$domain }
            Category          = if ([string]::IsNullOrWhiteSpace($tenantCategory)) { $null } else { [string]$tenantCategory }
            Cloud             = if ([string]::IsNullOrWhiteSpace($Cloud)) { $null } else { [string]$Cloud }
            Status            = 'Discovered'
            Error             = $null
        }
    }
}

function New-PimEligibleGroupRecord {
    <#
    .SYNOPSIS
        Builds an eligible group record for the UI grid.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $TenantId,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $TenantDisplayName,

        [Parameter(Mandatory)]
        [string] $GroupId,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $GroupDisplayName,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $GroupDescription,

        [Parameter(Mandatory)]
        [string] $PrincipalId,

        [Parameter(Mandatory)]
        [ValidateSet('member', 'owner')]
        [string] $AccessId,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $EligibilityScheduleId,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Status = 'Eligible',

        [Parameter()]
        [AllowNull()]
        [object] $StartDateTime,

        [Parameter()]
        [AllowNull()]
        [object] $EndDateTime,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $MemberType
    )

    $displayName = $GroupDisplayName
    if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $GroupId }

    [pscustomobject]@{
        Selected              = $false
        TenantId              = $TenantId
        TenantDisplayName     = if ([string]::IsNullOrWhiteSpace($TenantDisplayName)) { $TenantId } else { $TenantDisplayName }
        GroupId               = $GroupId
        GroupDisplayName      = $displayName
        GroupDescription      = if ([string]::IsNullOrWhiteSpace($GroupDescription)) { $null } else { $GroupDescription }
        PrincipalId           = $PrincipalId
        AccessId              = $AccessId
        EligibilityScheduleId = if ([string]::IsNullOrWhiteSpace($EligibilityScheduleId)) { $null } else { $EligibilityScheduleId }
        Status                = if ([string]::IsNullOrWhiteSpace($Status)) { 'Eligible' } else { $Status }
        StartDateTime         = $StartDateTime
        EndDateTime           = $EndDateTime
        MemberType            = if ([string]::IsNullOrWhiteSpace($MemberType)) { $null } else { $MemberType }
    }
}

function New-PimActivationResultRecord {
    <#
    .SYNOPSIS
        Builds an activation result record for the results grid and the CSV export.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $TenantId,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $TenantDisplayName,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $GroupId,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $GroupDisplayName,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $AccessId,

        [Parameter(Mandatory)]
        [ValidateSet('Success', 'Failed', 'Skipped', 'Pending')]
        [string] $Status,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Message,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $RequestId,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Detail
    )

    [pscustomobject]@{
        Timestamp         = [datetime]::UtcNow
        TenantId          = $TenantId
        TenantDisplayName = if ([string]::IsNullOrWhiteSpace($TenantDisplayName)) { $TenantId } else { $TenantDisplayName }
        GroupId           = $GroupId
        GroupDisplayName  = if ([string]::IsNullOrWhiteSpace($GroupDisplayName)) { $GroupId } else { $GroupDisplayName }
        AccessId          = $AccessId
        Status            = $Status
        Message           = (Remove-PimSensitiveData -Text $Message)
        RequestId         = if ([string]::IsNullOrWhiteSpace($RequestId)) { $null } else { $RequestId }
        Detail            = (Remove-PimSensitiveData -Text $Detail)
    }
}

# ---------------------------------------------------------------------------
# Request payload
# ---------------------------------------------------------------------------

function New-PimActivationRequestBody {
    <#
    .SYNOPSIS
        Builds the body for POST /identityGovernance/privilegedAccess/group/assignmentScheduleRequests.

    .PARAMETER TicketNumber
        Optional ticket number required by some activation policies.

    .PARAMETER TicketSystem
        Optional ticket system name required by some activation policies.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $PrincipalId,

        [Parameter(Mandatory)]
        [string] $GroupId,

        [Parameter(Mandatory)]
        [ValidateSet('member', 'owner')]
        [string] $AccessId,

        [Parameter(Mandatory)]
        [string] $Justification,

        [Parameter(Mandatory)]
        [timespan] $Duration,

        [Parameter()]
        [AllowNull()]
        [Nullable[datetime]] $StartDateTime,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $TicketNumber,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $TicketSystem,

        [Parameter()]
        [ValidateSet('selfActivate', 'selfDeactivate')]
        [string] $Action = 'selfActivate'
    )

    Assert-PimGuid -Value $PrincipalId -ParameterName 'PrincipalId'
    Assert-PimGuid -Value $GroupId -ParameterName 'GroupId'

    if ([string]::IsNullOrWhiteSpace($Justification)) {
        throw 'Justification is required.'
    }

    $start = if ($null -eq $StartDateTime) { [datetime]::UtcNow } else { $StartDateTime.ToUniversalTime() }

    $body = @{
        action        = $Action
        principalId   = $PrincipalId
        groupId       = $GroupId
        accessId      = $AccessId
        justification = $Justification.Trim()
        scheduleInfo  = @{
            startDateTime = $start.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
            expiration    = @{
                type     = 'afterDuration'
                duration = (ConvertTo-Iso8601Duration -TimeSpan $Duration)
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($TicketNumber) -or -not [string]::IsNullOrWhiteSpace($TicketSystem)) {
        $ticketInfo = @{}
        if (-not [string]::IsNullOrWhiteSpace($TicketNumber)) { $ticketInfo['ticketNumber'] = $TicketNumber.Trim() }
        if (-not [string]::IsNullOrWhiteSpace($TicketSystem)) { $ticketInfo['ticketSystem'] = $TicketSystem.Trim() }
        $body['ticketInfo'] = $ticketInfo
    }

    return $body
}

function Assert-PimGuid {
    <#
    .SYNOPSIS
        Throws when a value is not a GUID.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Value,

        [Parameter(Mandatory)]
        [string] $ParameterName
    )

    $parsed = [guid]::Empty
    if ([string]::IsNullOrWhiteSpace($Value) -or -not [guid]::TryParse($Value, [ref]$parsed)) {
        throw "$ParameterName must be a GUID. Received '$Value'."
    }
    if ($parsed -eq [guid]::Empty) {
        throw "$ParameterName must not be an empty GUID."
    }
}

# ---------------------------------------------------------------------------
# Error formatting and redaction
# ---------------------------------------------------------------------------

# Patterns for values that must never reach a log file, the UI, or the console.
$script:SensitivePatterns = @(
    # JWTs (header.payload.signature) and any long bearer-looking blob.
    [regex]::new('eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}', 'Compiled'),
    [regex]::new('(?i)\b(bearer|authorization:\s*bearer)\s+[A-Za-z0-9\-._~+/]{20,}=*', 'Compiled'),
    [regex]::new('(?i)("?(access_token|refresh_token|id_token|client_secret|password|code_verifier)"?\s*[:=]\s*"?)([^"\s,&}]+)', 'Compiled')
)

function Remove-PimSensitiveData {
    <#
    .SYNOPSIS
        Redacts tokens and secrets from text before it is logged or displayed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(ValueFromPipeline)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Text
    )

    process {
        if ([string]::IsNullOrEmpty($Text)) { return $Text }

        $result = $Text
        $result = $script:SensitivePatterns[0].Replace($result, '[REDACTED]')
        $result = $script:SensitivePatterns[1].Replace($result, '$1 [REDACTED]')
        $result = $script:SensitivePatterns[2].Replace($result, '${1}[REDACTED]')
        return $result
    }
}

# Ordered list of matchers that turn a raw Graph/MSAL failure into something a
# non-PowerShell user can act on.
$script:FriendlyErrorRules = @(
    @{ Pattern = '(?i)AADSTS65001|consent_required|interaction_required.*consent'; Message = 'The tenant has not consented to the Microsoft Graph PowerShell permissions this tool needs. Ask a Global Administrator or Privileged Role Administrator in that tenant to grant admin consent.' }
    @{ Pattern = '(?i)AADSTS50076|AADSTS50079|AADSTS50158|strong authentication|multi-?factor'; Message = 'Multi-factor authentication or an additional Conditional Access requirement must be satisfied in this tenant. Re-run sign-in and complete the prompt.' }
    @{ Pattern = '(?i)AADSTS53003|blocked by Conditional Access|AADSTS50105'; Message = 'Conditional Access or a tenant policy blocked this sign-in. Contact the tenant administrator.' }
    @{ Pattern = '(?i)AADSTS50020|AADSTS700016|user account .* does not exist in tenant|does not exist in tenant'; Message = 'Your account does not have access to this tenant. Confirm the B2B guest invitation was accepted.' }
    @{ Pattern = '(?i)AADSTS50058|AADSTS50001|AADSTS90002'; Message = 'Sign-in could not be completed for this tenant. Verify the tenant ID and that the Microsoft Graph PowerShell application is available there.' }
    @{ Pattern = '(?i)\bAuthenticationCanceled\b|user_?cancel|canceled by the user|was canceled'; Message = 'Sign-in was cancelled.' }
    @{ Pattern = '(?i)RoleAssignmentRequestPolicyValidationFailed|exceeds.*maximum|maximum.*duration|duration.*(exceed|not allowed|longer)'; Message = 'The requested duration exceeds the activation policy for this group. Choose a shorter duration.' }
    @{ Pattern = '(?i)ticket.*(required|information)|RoleAssignmentRequestTicketInfo'; Message = 'This group''s activation policy requires ticket information. Provide a ticket number and ticket system, then resubmit.' }
    @{ Pattern = '(?i)justification.*(required|missing)'; Message = 'This group''s activation policy requires a justification. Provide one and resubmit.' }
    @{ Pattern = '(?i)RoleAssignmentExists|RoleAssignmentRequestPolicyValidationFailed.*already|already active|PendingRoleAssignmentRequest|existing.*request'; Message = 'An active or pending activation already exists for this group.' }
    @{ Pattern = '(?i)RoleNotEligible|not eligible|NoEligibleAssignment'; Message = 'You are not eligible for this group, or the eligibility has expired.' }
    @{ Pattern = '(?i)\b429\b|TooManyRequests|throttl'; Message = 'Microsoft Graph throttled the request. Wait a moment and try again.' }
    @{ Pattern = '(?i)\b(401|Unauthorized|InvalidAuthenticationToken)\b'; Message = 'The Microsoft Graph session is not valid for this tenant. Sign in again.' }
    @{ Pattern = '(?i)\b(403|Forbidden|Authorization_RequestDenied|AccessDenied)\b'; Message = 'Microsoft Graph denied the request. The required permissions are likely missing or not consented in this tenant.' }
    @{ Pattern = '(?i)\b(404|NotFound|ResourceNotFound|Request_ResourceNotFound)\b'; Message = 'The requested object was not found in this tenant.' }
    @{ Pattern = '(?i)\b(5\d\d|ServiceUnavailable|InternalServerError|UnknownError)\b'; Message = 'Microsoft Graph returned a temporary service error. Try again shortly.' }
    @{ Pattern = '(?i)No such host is known|The remote name could not be resolved|Unable to connect to the remote server|SSL connection'; Message = 'The Graph endpoint could not be reached. Check network connectivity and proxy settings.' }
)

function Format-PimGraphError {
    <#
    .SYNOPSIS
        Converts a Graph or MSAL failure into a friendly message plus a redacted raw detail.

    .OUTPUTS
        pscustomobject with FriendlyMessage, Detail, Code, and StatusCode.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(ValueFromPipeline)]
        [AllowNull()]
        [object] $ErrorObject,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Context
    )

    process {
        $raw = ConvertTo-PimErrorText -ErrorObject $ErrorObject
        $raw = Remove-PimSensitiveData -Text $raw

        $code = $null
        $statusCode = $null

        if ($ErrorObject) {
            $exception = Get-PimPropertyValue -InputObject $ErrorObject -Name 'Exception'
            if ($null -eq $exception -and $ErrorObject -is [System.Exception]) { $exception = $ErrorObject }

            $response = Get-PimPropertyValue -InputObject $exception -Name 'Response'
            if ($response) {
                $parsedStatus = Get-PimFirstPropertyValue -InputObject $response -Name @('StatusCode')
                if ($null -ne $parsedStatus) { $statusCode = [string]$parsedStatus }
            }
        }

        # Pull the Graph "code" value out of the JSON error envelope when present.
        $codeMatch = [regex]::Match($raw, '(?i)"code"\s*:\s*"(?<code>[^"]+)"')
        if ($codeMatch.Success) { $code = $codeMatch.Groups['code'].Value }

        if (-not $statusCode) {
            $statusMatch = [regex]::Match($raw, '(?i)\b(?:status(?:code)?|HTTP)\D{0,3}(?<status>[45]\d\d)\b')
            if ($statusMatch.Success) { $statusCode = $statusMatch.Groups['status'].Value }
        }

        $friendly = $null
        $haystack = $raw
        if ($code) { $haystack = "$code $haystack" }
        if ($statusCode) { $haystack = "$statusCode $haystack" }

        foreach ($rule in $script:FriendlyErrorRules) {
            if ([regex]::IsMatch($haystack, $rule.Pattern)) {
                $friendly = $rule.Message
                break
            }
        }

        if (-not $friendly) {
            # Fall back to the Graph error message, which is usually readable.
            $messageMatch = [regex]::Match($raw, '(?i)"message"\s*:\s*"(?<message>(?:[^"\\]|\\.)*)"')
            if ($messageMatch.Success) {
                $friendly = $messageMatch.Groups['message'].Value -replace '\\"', '"' -replace '\\n', ' '
            }
            else {
                $friendly = $raw
            }
        }

        if ([string]::IsNullOrWhiteSpace($friendly)) { $friendly = 'An unknown error occurred.' }

        $friendly = $friendly.Trim()
        if ($friendly.Length -gt 400) { $friendly = $friendly.Substring(0, 397) + '...' }

        if (-not [string]::IsNullOrWhiteSpace($Context)) {
            $friendly = "$Context $friendly"
        }

        [pscustomobject]@{
            FriendlyMessage = $friendly
            Detail          = $raw
            Code            = $code
            StatusCode      = $statusCode
        }
    }
}

function ConvertTo-PimErrorText {
    <#
    .SYNOPSIS
        Flattens an ErrorRecord, Exception, or arbitrary object into readable text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $ErrorObject
    )

    if ($null -eq $ErrorObject) { return '' }
    if ($ErrorObject -is [string]) { return $ErrorObject }

    $parts = New-Object System.Collections.Generic.List[string]

    if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) {
        if ($ErrorObject.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($ErrorObject.ErrorDetails.Message)) {
            $parts.Add($ErrorObject.ErrorDetails.Message)
        }
        if ($ErrorObject.Exception) {
            $parts.Add((ConvertTo-PimExceptionText -Exception $ErrorObject.Exception))
        }
        if ($parts.Count -eq 0) {
            $parts.Add([string]$ErrorObject)
        }
        return (($parts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' | ')
    }

    if ($ErrorObject -is [System.Exception]) {
        return (ConvertTo-PimExceptionText -Exception $ErrorObject)
    }

    try {
        return ($ErrorObject | ConvertTo-Json -Depth 6 -Compress)
    }
    catch {
        return [string]$ErrorObject
    }
}

function ConvertTo-PimExceptionText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Exception] $Exception
    )

    $parts = New-Object System.Collections.Generic.List[string]
    $current = $Exception
    $depth = 0

    while ($null -ne $current -and $depth -lt 5) {
        if (-not [string]::IsNullOrWhiteSpace($current.Message)) {
            $parts.Add($current.Message)
        }
        $current = $current.InnerException
        $depth++
    }

    return ($parts -join ' -> ')
}

# ---------------------------------------------------------------------------
# Validation helpers used by the UI state machine
# ---------------------------------------------------------------------------

function Test-PimJustification {
    <#
    .SYNOPSIS
        Returns $true when the justification satisfies the tool's minimum requirements.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Justification,

        [Parameter()]
        [int] $MinimumLength = 3
    )

    if ([string]::IsNullOrWhiteSpace($Justification)) { return $false }
    return ($Justification.Trim().Length -ge $MinimumLength)
}

function Get-PimSubmissionReadiness {
    <#
    .SYNOPSIS
        Centralized rule for whether "Submit Activation Requests" may be enabled.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [int] $SelectedGroupCount = 0,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Justification,

        [Parameter()]
        [AllowNull()]
        [Nullable[timespan]] $Duration,

        [Parameter()]
        [bool] $IsBusy = $false
    )

    $reasons = New-Object System.Collections.Generic.List[string]

    if ($IsBusy) { $reasons.Add('An operation is already running.') }
    if ($SelectedGroupCount -le 0) { $reasons.Add('Select at least one group.') }
    if (-not (Test-PimJustification -Justification $Justification)) { $reasons.Add('Enter a justification.') }
    if ($null -eq $Duration -or $Duration.Ticks -le 0) { $reasons.Add('Choose a duration.') }

    [pscustomobject]@{
        CanSubmit = ($reasons.Count -eq 0)
        Reasons   = $reasons.ToArray()
    }
}

Export-ModuleMember -Function @(
    'Get-PimBuiltInCloudConfiguration'
    'Get-PimCloudConfiguration'
    'New-PimCustomCloudConfiguration'
    'Format-PimBaseUri'
    'Get-PimPropertyValue'
    'Test-PimPropertyExists'
    'Get-PimFirstPropertyValue'
    'Get-PimDurationOption'
    'ConvertTo-Iso8601Duration'
    'ConvertFrom-Iso8601Duration'
    'New-PimTenantRecord'
    'New-PimEligibleGroupRecord'
    'New-PimActivationResultRecord'
    'New-PimActivationRequestBody'
    'Assert-PimGuid'
    'Remove-PimSensitiveData'
    'Format-PimGraphError'
    'ConvertTo-PimErrorText'
    'ConvertTo-PimExceptionText'
    'Test-PimJustification'
    'Get-PimSubmissionReadiness'
)
