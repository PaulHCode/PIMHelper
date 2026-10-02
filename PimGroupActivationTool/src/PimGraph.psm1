#Requires -Version 5.1
<#
.SYNOPSIS
    Azure sign-in, tenant discovery, and Microsoft Graph PIM for Groups operations.

.DESCRIPTION
    Every external cmdlet (Az.Accounts and Microsoft.Graph.Authentication) is invoked
    through Invoke-PimExternalCommand. That single seam keeps the module importable
    without those modules installed and lets unit tests substitute deterministic
    handlers via Set-PimCommandOverride.

    Delegated authentication only. No client secrets, no custom app registration for
    the built-in clouds, and no tokens are ever persisted or logged by this module.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'PimModels.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'PimLogging.psm1') -DisableNameChecking -ErrorAction Stop

# Delegated scopes requested from the Microsoft Graph PowerShell enterprise application.
# User.Read is needed because the signed-in user's object ID differs in every tenant and
# is read from /me before eligibility can be filtered by principal.
$script:DefaultGraphScopes = @(
    'User.Read'
    'PrivilegedEligibilitySchedule.Read.AzureADGroup'
    'PrivilegedAssignmentSchedule.ReadWrite.AzureADGroup'
    'Group.Read.All'
)

# Minimum scopes required to read eligibility and submit an activation. Used when the
# full scope set cannot be consented in a tenant; group display names then fall back
# to group IDs.
$script:MinimumGraphScopes = @(
    'User.Read'
    'PrivilegedEligibilitySchedule.Read.AzureADGroup'
    'PrivilegedAssignmentSchedule.ReadWrite.AzureADGroup'
)

$script:RequiredModules = @(
    [pscustomobject]@{ Name = 'Az.Accounts';                    MinimumVersion = '2.12.1'; InstallName = 'Az.Accounts';    Purpose = 'Azure sign-in and tenant discovery' }
    # 2.25.0 and earlier can return from Connect-MgGraph without an error and
    # without a context when the Web Account Manager broker cannot prompt.
    [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication'; MinimumVersion = '2.26.0'; InstallName = 'Microsoft.Graph.Authentication'; Purpose = 'Microsoft Graph sign-in and REST calls' }
)

$script:CommandOverrides = @{}

# Cache of group display names keyed by "<tenantId>/<groupId>" so repeated loads do not
# re-query Graph for the same group.
$script:GroupCache = @{}

function Get-PimDefaultGraphScope {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return , ([string[]]$script:DefaultGraphScopes)
}

function Get-PimMinimumGraphScope {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return , ([string[]]$script:MinimumGraphScopes)
}

# ---------------------------------------------------------------------------
# External command seam
# ---------------------------------------------------------------------------

function Set-PimCommandOverride {
    <#
    .SYNOPSIS
        Replaces an external cmdlet with a scriptblock. Intended for unit tests.

    .PARAMETER Name
        Name of the external command, for example 'Get-AzTenant'.

    .PARAMETER Handler
        Scriptblock receiving a single hashtable of parameters. Pass $null to remove.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter()]
        [AllowNull()]
        [scriptblock] $Handler
    )

    if ($null -eq $Handler) {
        if ($script:CommandOverrides.ContainsKey($Name)) { $script:CommandOverrides.Remove($Name) }
    }
    else {
        $script:CommandOverrides[$Name] = $Handler
    }
}

function Clear-PimCommandOverride {
    [CmdletBinding()]
    param()
    $script:CommandOverrides = @{}
}

function Invoke-PimExternalCommand {
    <#
    .SYNOPSIS
        Invokes an Az or Microsoft Graph cmdlet, honoring any registered test override.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter()]
        [AllowNull()]
        [hashtable] $Parameters
    )

    if ($null -eq $Parameters) { $Parameters = @{} }

    if ($script:CommandOverrides.ContainsKey($Name)) {
        return & $script:CommandOverrides[$Name] $Parameters
    }

    $command = Get-Command -Name $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "The command '$Name' is not available. Install the required PowerShell modules and try again."
    }

    return & $command @Parameters
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

function Get-PimRequiredModule {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    return $script:RequiredModules
}

function Test-PimModuleAvailability {
    <#
    .SYNOPSIS
        Reports whether each required module is installed at an acceptable version.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowNull()]
        [object[]] $RequiredModule
    )

    if (-not $RequiredModule) { $RequiredModule = $script:RequiredModules }

    foreach ($required in $RequiredModule) {
        $installed = @(Get-Module -ListAvailable -Name $required.Name -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending)

        $latest = $null
        if ($installed.Count -gt 0) { $latest = $installed[0] }

        $isAvailable = $false
        if ($latest) {
            $isAvailable = ([version]$latest.Version -ge [version]$required.MinimumVersion)
        }

        [pscustomobject]@{
            Name             = $required.Name
            MinimumVersion   = $required.MinimumVersion
            InstalledVersion = if ($latest) { [string]$latest.Version } else { $null }
            IsAvailable      = $isAvailable
            InstallName      = $required.InstallName
            Purpose          = $required.Purpose
        }
    }
}

function Import-PimRequiredModule {
    <#
    .SYNOPSIS
        Imports the Az and Microsoft Graph modules the tool depends on.
    #>
    [CmdletBinding()]
    param()

    foreach ($required in $script:RequiredModules) {
        if (Get-Module -Name $required.Name) { continue }
        Import-Module -Name $required.Name -MinimumVersion $required.MinimumVersion -ErrorAction Stop -Global
    }
}

# ---------------------------------------------------------------------------
# Azure sign-in and tenant discovery
# ---------------------------------------------------------------------------

function Get-PimAzureContext {
    <#
    .SYNOPSIS
        Returns the current Az context, or $null when there is none.
    #>
    [CmdletBinding()]
    param()

    try {
        return Invoke-PimExternalCommand -Name 'Get-AzContext' -Parameters @{ ErrorAction = 'SilentlyContinue' }
    }
    catch {
        Write-PimLog -Level Debug -Operation 'Get-AzContext' -Message "No usable Az context: $($_.Exception.Message)"
        return $null
    }
}

function Test-PimAzureContext {
    <#
    .SYNOPSIS
        Returns $true when the supplied Az context is usable for the requested environment.

    .DESCRIPTION
        A non-null context is not proof that its token still works, so this also calls
        Get-AzTenant to force a token refresh.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $Context,

        [Parameter(Mandatory)]
        [string] $AzEnvironment
    )

    if ($null -eq $Context) { return $false }

    $account = Get-PimPropertyValue -InputObject $Context -Name 'Account'
    if ($null -eq $account) { return $false }

    $environment = Get-PimPropertyValue -InputObject $Context -Name 'Environment'
    $environmentName = Get-PimFirstPropertyValue -InputObject $environment -Name @('Name')
    if ($null -eq $environmentName -and $environment -is [string]) { $environmentName = $environment }

    if (-not [string]::Equals([string]$environmentName, $AzEnvironment, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-PimLog -Level Debug -Operation 'Test-AzContext' -Message "Existing Az context is for environment '$environmentName' but '$AzEnvironment' is required."
        return $false
    }

    try {
        $tenants = @(Invoke-PimExternalCommand -Name 'Get-AzTenant' -Parameters @{ ErrorAction = 'Stop' })
        return ($tenants.Count -gt 0)
    }
    catch {
        Write-PimLog -Level Debug -Operation 'Test-AzContext' -Message "Existing Az context failed validation: $($_.Exception.Message)"
        return $false
    }
}

function Connect-PimAzureAccount {
    <#
    .SYNOPSIS
        Ensures there is a usable Az sign-in for the selected cloud.

    .DESCRIPTION
        Reuses an existing context when it belongs to the requested environment and its
        token still works. Otherwise signs in interactively with -Scope Process so the
        user's persisted Azure profiles are never modified.

    .PARAMETER CloudConfiguration
        A record from Get-PimCloudConfiguration.

    .PARAMETER Force
        Always sign in again, even when a usable context exists.

    .PARAMETER UseDeviceAuthentication
        Sign in with a device code instead of a browser. Needed where no browser can be
        launched, such as a remote session.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $CloudConfiguration,

        [Parameter()]
        [switch] $Force,

        [Parameter()]
        [switch] $UseDeviceAuthentication
    )

    if (-not $CloudConfiguration.IsSupported) {
        throw $CloudConfiguration.UnsupportedReason
    }

    $azEnvironment = $CloudConfiguration.AzEnvironment
    $reusedContext = $false
    $context = $null

    if (-not $Force) {
        $context = Get-PimAzureContext
        if (Test-PimAzureContext -Context $context -AzEnvironment $azEnvironment) {
            $reusedContext = $true
            Write-PimLog -Operation 'Connect-Azure' -Status 'Reused' -Message "Reusing the existing Az context for environment '$azEnvironment'."
        }
        else {
            $context = $null
        }
    }

    if (-not $reusedContext) {
        Write-PimLog -Operation 'Connect-Azure' -Message "Signing in to Azure environment '$azEnvironment'."
        $connectParameters = @{
            Environment = $azEnvironment
            Scope       = 'Process'
            ErrorAction = 'Stop'
        }
        if ($UseDeviceAuthentication) { $connectParameters['UseDeviceAuthentication'] = $true }

        try {
            $null = Invoke-PimExternalCommand -Name 'Connect-AzAccount' -Parameters $connectParameters
        }
        catch {
            $formatted = Format-PimGraphError -ErrorObject $_ -Context 'Azure sign-in failed.'
            Write-PimLog -Level Error -Operation 'Connect-Azure' -Status 'Failed' -Message $formatted.Detail
            throw $formatted.FriendlyMessage
        }

        $context = Get-PimAzureContext
        if ($null -eq $context) {
            throw 'Azure sign-in did not produce a usable context. Sign-in may have been cancelled.'
        }
    }

    $account = Get-PimPropertyValue -InputObject $context -Name 'Account'
    $accountId = Get-PimFirstPropertyValue -InputObject $account -Name @('Id', 'Name')
    if ([string]::IsNullOrWhiteSpace($accountId) -and $account -is [string]) { $accountId = $account }

    $environment = Get-PimPropertyValue -InputObject $context -Name 'Environment'
    $environmentName = Get-PimFirstPropertyValue -InputObject $environment -Name @('Name')
    if ([string]::IsNullOrWhiteSpace($environmentName) -and $environment -is [string]) { $environmentName = $environment }

    $tenantObject = Get-PimPropertyValue -InputObject $context -Name 'Tenant'
    $tenantId = Get-PimFirstPropertyValue -InputObject $tenantObject -Name @('Id', 'TenantId')

    Write-PimLog -Operation 'Connect-Azure' -Status 'Succeeded' -Message "Signed in as '$accountId' to environment '$environmentName'."

    [pscustomobject]@{
        Account       = [string]$accountId
        Environment   = [string]$environmentName
        TenantId      = [string]$tenantId
        ReusedContext = $reusedContext
        Cloud         = $CloudConfiguration.DisplayName
    }
}

function Disconnect-PimAzureAccount {
    <#
    .SYNOPSIS
        Clears only this process's Az context.

    .DESCRIPTION
        Deliberately scoped to Process so the user's persisted Azure profiles under
        their user profile are left untouched.
    #>
    [CmdletBinding()]
    param()

    foreach ($name in 'Disconnect-AzAccount', 'Clear-AzContext') {
        try {
            $parameters = @{ Scope = 'Process'; ErrorAction = 'SilentlyContinue' }
            if ($name -eq 'Clear-AzContext') { $parameters['Force'] = $true }
            $null = Invoke-PimExternalCommand -Name $name -Parameters $parameters
        }
        catch {
            Write-PimLog -Level Debug -Operation 'Disconnect-Azure' -Message "$name reported: $($_.Exception.Message)"
        }
    }

    # A cached display name was resolved under the previous account's permissions, so
    # it must not survive a sign-out.
    Clear-PimGroupCache

    Write-PimLog -Operation 'Disconnect-Azure' -Status 'Succeeded' -Message 'Cleared the process-scoped Az context.'
}

function Get-PimAuthorizedTenant {
    <#
    .SYNOPSIS
        Returns tenant records for every tenant the signed-in account is authorized in.

    .DESCRIPTION
        Includes B2B tenants where the account is an accepted guest. Always returns an
        array, never $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $CloudConfiguration
    )

    $cloudName = $null
    if ($CloudConfiguration) { $cloudName = $CloudConfiguration.DisplayName }

    $tenants = @()
    try {
        $tenants = @(Invoke-PimExternalCommand -Name 'Get-AzTenant' -Parameters @{ ErrorAction = 'Stop' })
    }
    catch {
        $formatted = Format-PimGraphError -ErrorObject $_ -Context 'Could not list authorized tenants.'
        Write-PimLog -Level Error -Operation 'Get-Tenants' -Status 'Failed' -Message $formatted.Detail
        throw $formatted.FriendlyMessage
    }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($tenant in $tenants) {
        if ($null -eq $tenant) { continue }
        try {
            $records.Add((New-PimTenantRecord -AzTenant $tenant -Cloud $cloudName))
        }
        catch {
            Write-PimLog -Level Warning -Operation 'Get-Tenants' -Message "Skipped an unreadable tenant entry: $($_.Exception.Message)"
        }
    }

    $sorted = @($records | Sort-Object -Property TenantDisplayName)
    Write-PimLog -Operation 'Get-Tenants' -Status 'Succeeded' -Message "Discovered $($sorted.Count) authorized tenant(s)."
    return , ([object[]]$sorted)
}

# ---------------------------------------------------------------------------
# Microsoft Graph authentication
# ---------------------------------------------------------------------------

function Get-PimGraphContext {
    [CmdletBinding()]
    param()

    try {
        return Invoke-PimExternalCommand -Name 'Get-MgContext' -Parameters @{ ErrorAction = 'SilentlyContinue' }
    }
    catch {
        return $null
    }
}

function Get-PimGraphAuthenticationVersion {
    <#
    .SYNOPSIS
        Returns the loaded Microsoft.Graph.Authentication version, or 'unknown'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        $module = Invoke-PimExternalCommand -Name 'Get-Module' -Parameters @{
            Name        = 'Microsoft.Graph.Authentication'
            ErrorAction = 'SilentlyContinue'
        }
        if ($module) {
            $version = Get-PimPropertyValue -InputObject @($module)[0] -Name 'Version'
            if ($version) { return [string]$version }
        }
    }
    catch {
        # Reporting the version is best effort; never let it mask the real error.
    }

    return 'unknown'
}

function Test-PimGraphContext {
    <#
    .SYNOPSIS
        Returns $true when the current Graph context targets the expected tenant,
        environment, account, and scopes.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $Context,

        [Parameter(Mandatory)]
        [string] $TenantId,

        [Parameter(Mandatory)]
        [string] $GraphEnvironment,

        [Parameter()]
        [AllowNull()]
        [string[]] $RequiredScopes,

        [Parameter()]
        [AllowNull()]
        [string] $ExpectedAccount
    )

    if ($null -eq $Context) { return $false }

    $contextTenant = Get-PimPropertyValue -InputObject $Context -Name 'TenantId'
    if (-not [string]::Equals([string]$contextTenant, $TenantId, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $contextEnvironment = Get-PimPropertyValue -InputObject $Context -Name 'Environment'
    if (-not [string]::Equals([string]$contextEnvironment, $GraphEnvironment, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    # A stale context can belong to a different signed-in user after an account
    # switch, which would silently enumerate somebody else's eligible groups.
    if (-not [string]::IsNullOrWhiteSpace($ExpectedAccount)) {
        $contextAccount = Get-PimPropertyValue -InputObject $Context -Name 'Account'
        if (-not [string]::Equals([string]$contextAccount, $ExpectedAccount, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }

    if ($RequiredScopes) {
        $granted = @(Get-PimPropertyValue -InputObject $Context -Name 'Scopes')
        foreach ($scope in $RequiredScopes) {
            if ($granted -notcontains $scope) { return $false }
        }
    }

    return $true
}

function Connect-PimGraphTenant {
    <#
    .SYNOPSIS
        Signs in to Microsoft Graph for one tenant using delegated authentication.

    .DESCRIPTION
        Az PowerShell and Microsoft Graph PowerShell keep separate authentication
        contexts, so this must be called per tenant before any tenant-specific Graph
        call. When the full scope set cannot be consented, the connection is retried
        with the minimum scope set and the result reports reduced functionality.

    .OUTPUTS
        pscustomobject with Success, TenantId, Environment, Account, Scopes,
        HasGroupRead, Message, and Detail. Tenant-level failures are returned rather
        than thrown so one bad tenant cannot abort a multi-tenant load.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $TenantId,

        [Parameter(Mandatory)]
        [object] $CloudConfiguration,

        [Parameter()]
        [AllowNull()]
        [string[]] $Scopes,

        [Parameter()]
        [AllowNull()]
        [string[]] $FallbackScopes,

        [Parameter()]
        [switch] $Force,

        [Parameter()]
        [switch] $UseDeviceAuthentication,

        [Parameter()]
        [AllowNull()]
        [string] $ExpectedAccount
    )

    if (-not $Scopes)         { $Scopes = $script:DefaultGraphScopes }
    if (-not $FallbackScopes) { $FallbackScopes = $script:MinimumGraphScopes }

    $graphEnvironment = $CloudConfiguration.GraphEnvironment

    if (-not $Force) {
        $existing = Get-PimGraphContext
        if (Test-PimGraphContext -Context $existing -TenantId $TenantId -GraphEnvironment $graphEnvironment -RequiredScopes $FallbackScopes -ExpectedAccount $ExpectedAccount) {
            $grantedScopes = @(Get-PimPropertyValue -InputObject $existing -Name 'Scopes')
            Write-PimLog -Operation 'Connect-Graph' -TenantId $TenantId -Status 'Reused' -Message 'Reusing the existing Microsoft Graph context.'
            return (New-PimGraphConnectionResult -Success $true -TenantId $TenantId -Context $existing -Scopes $grantedScopes -Message 'Reused the existing Microsoft Graph session.')
        }
    }

    $attempts = @(
        [pscustomobject]@{ Scopes = $Scopes;         IsFallback = $false }
        [pscustomobject]@{ Scopes = $FallbackScopes; IsFallback = $true }
    )

    $lastError = $null

    foreach ($attempt in $attempts) {
        if ($attempt.IsFallback -and (Compare-PimScopeSet -Left $attempt.Scopes -Right $Scopes)) {
            break  # Fallback is identical to the first attempt; nothing to retry.
        }

        Write-PimLog -Operation 'Connect-Graph' -TenantId $TenantId -Message "Connecting to Microsoft Graph environment '$graphEnvironment' with $($attempt.Scopes.Count) scope(s)."

        try {
            $connectParameters = @{
                TenantId     = $TenantId
                Scopes       = [string[]]$attempt.Scopes
                Environment  = $graphEnvironment
                ContextScope = 'Process'
                NoWelcome    = $true
                ErrorAction  = 'Stop'
            }
            if ($UseDeviceAuthentication) { $connectParameters['UseDeviceCode'] = $true }

            $null = Invoke-PimExternalCommand -Name 'Connect-MgGraph' -Parameters $connectParameters

            $context = Get-PimGraphContext
            if ($null -eq $context) {
                # Connect-MgGraph can return without raising an error and still
                # leave no context. On Windows this is almost always the Web
                # Account Manager broker failing when it has no usable parent
                # window, which older module versions swallow silently.
                throw ('Microsoft Graph reported no error but left no sign-in context. ' +
                       'This usually means the Web Account Manager broker could not display a sign-in prompt. ' +
                       'Retry with device code authentication, and make sure Microsoft.Graph.Authentication is up to date ' +
                       "(installed: $(Get-PimGraphAuthenticationVersion)).")
            }

            if (-not (Test-PimGraphContext -Context $context -TenantId $TenantId -GraphEnvironment $graphEnvironment)) {
                $actualTenant = Get-PimPropertyValue -InputObject $context -Name 'TenantId'
                $actualEnvironment = Get-PimPropertyValue -InputObject $context -Name 'Environment'
                throw "Microsoft Graph connected to tenant '$actualTenant' in environment '$actualEnvironment' instead of tenant '$TenantId' in environment '$graphEnvironment'."
            }

            $grantedScopes = @(Get-PimPropertyValue -InputObject $context -Name 'Scopes')
            $message = 'Connected to Microsoft Graph.'
            if ($attempt.IsFallback) {
                $message = 'Connected with reduced permissions. Group display names may show as IDs.'
            }

            Write-PimLog -Operation 'Connect-Graph' -TenantId $TenantId -Status 'Succeeded' -Message $message
            return (New-PimGraphConnectionResult -Success $true -TenantId $TenantId -Context $context -Scopes $grantedScopes -Message $message)
        }
        catch {
            $lastError = $_
            $formatted = Format-PimGraphError -ErrorObject $_
            Write-PimLog -Level Warning -Operation 'Connect-Graph' -TenantId $TenantId -Status 'Failed' -Message $formatted.Detail

            # Only a consent/permission problem is worth retrying with fewer scopes.
            $isConsentProblem = [regex]::IsMatch($formatted.Detail, '(?i)AADSTS65001|consent|Authorization_RequestDenied|invalid_?scope|AADSTS70011')
            if (-not $attempt.IsFallback -and $isConsentProblem) { continue }
            break
        }
    }

    $formatted = Format-PimGraphError -ErrorObject $lastError -Context "Could not sign in to tenant $TenantId."
    return (New-PimGraphConnectionResult -Success $false -TenantId $TenantId -Message $formatted.FriendlyMessage -Detail $formatted.Detail)
}

function Compare-PimScopeSet {
    <#
    .SYNOPSIS
        Returns $true when two scope collections contain the same values.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [AllowNull()]
        [string[]] $Left,

        [Parameter()]
        [AllowNull()]
        [string[]] $Right
    )

    $leftSet = @($Left | Where-Object { $_ } | Sort-Object -Unique)
    $rightSet = @($Right | Where-Object { $_ } | Sort-Object -Unique)

    if ($leftSet.Count -ne $rightSet.Count) { return $false }
    for ($i = 0; $i -lt $leftSet.Count; $i++) {
        if (-not [string]::Equals($leftSet[$i], $rightSet[$i], [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function New-PimGraphConnectionResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [bool] $Success,

        [Parameter(Mandatory)]
        [string] $TenantId,

        [Parameter()]
        [AllowNull()]
        [object] $Context,

        [Parameter()]
        [AllowNull()]
        [string[]] $Scopes,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Message,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Detail
    )

    $account = $null
    $environment = $null
    if ($Context) {
        $account = Get-PimFirstPropertyValue -InputObject $Context -Name @('Account', 'ClientId')
        $environment = Get-PimPropertyValue -InputObject $Context -Name 'Environment'
    }

    $scopeList = @()
    if ($Scopes) { $scopeList = @($Scopes) }

    [pscustomobject]@{
        Success      = $Success
        TenantId     = $TenantId
        Environment  = [string]$environment
        Account      = [string]$account
        Scopes       = $scopeList
        HasGroupRead = [bool](@($scopeList | Where-Object { $_ -match '(?i)^(Group\.Read\.All|Group\.ReadWrite\.All|Directory\.Read\.All|Directory\.ReadWrite\.All|GroupMember\.Read\.All)$' }).Count -gt 0)
        Message      = (Remove-PimSensitiveData -Text $Message)
        Detail       = (Remove-PimSensitiveData -Text $Detail)
    }
}

function Disconnect-PimGraph {
    [CmdletBinding()]
    param()

    try {
        $null = Invoke-PimExternalCommand -Name 'Disconnect-MgGraph' -Parameters @{ ErrorAction = 'SilentlyContinue' }
        Write-PimLog -Operation 'Disconnect-Graph' -Status 'Succeeded' -Message 'Cleared the Microsoft Graph context.'
    }
    catch {
        Write-PimLog -Level Debug -Operation 'Disconnect-Graph' -Message "Disconnect-MgGraph reported: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Graph request plumbing
# ---------------------------------------------------------------------------

function Invoke-PimGraphRequest {
    <#
    .SYNOPSIS
        Issues a Microsoft Graph request with retry on throttling and transient errors.

    .PARAMETER Uri
        Absolute URI, or a path that is combined with -GraphBaseUri.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Uri,

        [Parameter()]
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
        [string] $Method = 'GET',

        [Parameter()]
        [AllowNull()]
        [object] $Body,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $GraphBaseUri,

        [Parameter()]
        [int] $MaximumRetryCount = 3,

        [Parameter()]
        [int] $InitialRetryDelaySeconds = 2
    )

    $requestUri = $Uri
    if ($requestUri -notmatch '^(?i)https://') {
        if ($requestUri -match '^[A-Za-z][A-Za-z0-9+.\-]*://') {
            throw "Graph requests must use https. Received '$(Get-PimSafeUri -Uri $requestUri)'."
        }
        if ([string]::IsNullOrWhiteSpace($GraphBaseUri)) {
            throw 'GraphBaseUri is required when Uri is a relative path.'
        }
        $requestUri = (Format-PimBaseUri -Uri $GraphBaseUri) + '/' + $requestUri.TrimStart('/')
    }

    $attempt = 0
    while ($true) {
        $parameters = @{
            Method      = $Method
            Uri         = $requestUri
            OutputType  = 'Hashtable'
            ErrorAction = 'Stop'
        }

        if ($null -ne $Body) {
            if ($Body -is [string]) {
                $parameters['Body'] = $Body
            }
            else {
                $parameters['Body'] = ($Body | ConvertTo-Json -Depth 10)
            }
            $parameters['ContentType'] = 'application/json'
        }

        try {
            return Invoke-PimExternalCommand -Name 'Invoke-MgGraphRequest' -Parameters $parameters
        }
        catch {
            $attempt++
            $retryAfter = Get-PimRetryDelaySecond -ErrorObject $_ -Attempt $attempt -InitialDelaySeconds $InitialRetryDelaySeconds

            if ($attempt -gt $MaximumRetryCount -or $null -eq $retryAfter) {
                throw
            }

            # A POST that times out or returns 5xx may already have been accepted, so
            # retrying it could create a duplicate activation request. Only throttling
            # is safe to repeat, because a throttled request was never processed.
            if ($Method -notin 'GET', 'HEAD', 'PUT', 'DELETE') {
                $errorText = ConvertTo-PimErrorText -ErrorObject $_
                if (-not [regex]::IsMatch($errorText, '(?i)\b429\b|TooManyRequests|throttl')) {
                    Write-PimLog -Level Warning -Operation 'Graph-Request' -Message "$Method $(Get-PimSafeUri -Uri $requestUri) failed and will not be retried, because the request may already have been processed."
                    throw
                }
            }

            Write-PimLog -Level Warning -Operation 'Graph-Request' -Message "$Method $(Get-PimSafeUri -Uri $requestUri) failed with a retryable error. Retry $attempt of $MaximumRetryCount in $retryAfter second(s)."
            Start-Sleep -Seconds $retryAfter
        }
    }
}

function Get-PimSafeUri {
    <#
    .SYNOPSIS
        Returns a URI suitable for logging, with the query string removed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Uri
    )

    if ([string]::IsNullOrWhiteSpace($Uri)) { return $Uri }
    $index = $Uri.IndexOf('?')
    if ($index -lt 0) { return $Uri }
    return $Uri.Substring(0, $index)
}

function Get-PimRetryDelaySecond {
    <#
    .SYNOPSIS
        Returns the number of seconds to wait before retrying, or $null when the error
        is not retryable.
    #>
    [CmdletBinding()]
    [OutputType([Nullable[int]])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $ErrorObject,

        [Parameter()]
        [int] $Attempt = 1,

        [Parameter()]
        [int] $InitialDelaySeconds = 2,

        [Parameter()]
        [int] $MaximumDelaySeconds = 60
    )

    $text = Remove-PimSensitiveData -Text (ConvertTo-PimErrorText -ErrorObject $ErrorObject)

    $isRetryable = [regex]::IsMatch($text, '(?i)\b(429|500|502|503|504)\b') -or
                   [regex]::IsMatch($text, '(?i)TooManyRequests|throttl|ServiceUnavailable|GatewayTimeout|BadGateway|InternalServerError|temporarily unavailable|timed? ?out')

    if (-not $isRetryable) { return $null }

    # Honor a server-provided Retry-After header when one is reachable.
    $retryAfterSeconds = $null
    $exception = Get-PimPropertyValue -InputObject $ErrorObject -Name 'Exception'
    if ($null -eq $exception -and $ErrorObject -is [System.Exception]) { $exception = $ErrorObject }

    $response = Get-PimPropertyValue -InputObject $exception -Name 'Response'
    if ($response) {
        $headers = Get-PimPropertyValue -InputObject $response -Name 'Headers'
        if ($headers) {
            try {
                $retryAfterHeader = $headers.RetryAfter
                if ($retryAfterHeader -and $retryAfterHeader.Delta) {
                    $retryAfterSeconds = [int]$retryAfterHeader.Delta.TotalSeconds
                }
            }
            catch {
                $retryAfterSeconds = $null
            }
        }
    }

    if ($null -eq $retryAfterSeconds) {
        $headerMatch = [regex]::Match($text, '(?i)Retry-After\D{0,3}(?<seconds>\d{1,4})')
        if ($headerMatch.Success) { $retryAfterSeconds = [int]$headerMatch.Groups['seconds'].Value }
    }

    if ($null -eq $retryAfterSeconds -or $retryAfterSeconds -le 0) {
        $retryAfterSeconds = [int]([math]::Pow(2, [math]::Max(0, $Attempt - 1)) * $InitialDelaySeconds)
    }

    if ($retryAfterSeconds -gt $MaximumDelaySeconds) { $retryAfterSeconds = $MaximumDelaySeconds }
    return $retryAfterSeconds
}

function Get-PimGraphCollection {
    <#
    .SYNOPSIS
        Reads every page of a Graph collection, following @odata.nextLink.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Uri,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $GraphBaseUri,

        [Parameter()]
        [int] $MaximumPageCount = 100
    )

    $items = New-Object System.Collections.Generic.List[object]
    $nextUri = $Uri
    $page = 0
    $seenUris = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    while (-not [string]::IsNullOrWhiteSpace($nextUri)) {
        $page++
        if ($page -gt $MaximumPageCount) {
            # Returning a partial list here would be indistinguishable from a complete
            # one, and a user would silently miss groups they are eligible for.
            $message = "Stopped after $MaximumPageCount pages for $(Get-PimSafeUri -Uri $Uri). The result would be incomplete."
            Write-PimLog -Level Error -Operation 'Graph-Paging' -Status 'Failed' -Message $message
            throw $message
        }

        if (-not $seenUris.Add([string]$nextUri)) {
            $message = "Microsoft Graph returned a repeating page link for $(Get-PimSafeUri -Uri $Uri)."
            Write-PimLog -Level Error -Operation 'Graph-Paging' -Status 'Failed' -Message $message
            throw $message
        }

        $response = Invoke-PimGraphRequest -Uri $nextUri -Method GET -GraphBaseUri $GraphBaseUri

        # A collection response always carries a 'value' property, even when it is empty.
        # Checking for the property (rather than a non-null value) keeps an empty page from
        # being misread as a single-object response.
        if (Test-PimPropertyExists -InputObject $response -Name 'value') {
            $value = Get-PimPropertyValue -InputObject $response -Name 'value'
            if ($null -ne $value) {
                foreach ($item in @($value)) { $items.Add($item) }
            }
        }
        elseif ($null -ne $response) {
            $items.Add($response)
        }

        $nextUri = Get-PimPropertyValue -InputObject $response -Name '@odata.nextLink'
    }

    return , ([object[]]$items.ToArray())
}

function Get-CurrentGraphUser {
    <#
    .SYNOPSIS
        Returns the signed-in user's object ID, UPN, and display name in the current tenant.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $GraphBaseUri
    )

    $uri = "$(Format-PimBaseUri -Uri $GraphBaseUri)/v1.0/me?`$select=id,userPrincipalName,displayName"
    $response = Invoke-PimGraphRequest -Uri $uri -Method GET

    $id = Get-PimPropertyValue -InputObject $response -Name 'id'
    if ([string]::IsNullOrWhiteSpace($id)) {
        throw 'Microsoft Graph did not return an object ID for the signed-in user.'
    }

    [pscustomobject]@{
        Id                = [string]$id
        UserPrincipalName = [string](Get-PimPropertyValue -InputObject $response -Name 'userPrincipalName')
        DisplayName       = [string](Get-PimPropertyValue -InputObject $response -Name 'displayName')
    }
}

# ---------------------------------------------------------------------------
# PIM for Groups
# ---------------------------------------------------------------------------

function Clear-PimGroupCache {
    [CmdletBinding()]
    param()
    $script:GroupCache = @{}
}

function Resolve-PimGroup {
    <#
    .SYNOPSIS
        Best-effort lookup of a group's display name and description.

    .DESCRIPTION
        Returns a record with DisplayName and Description. When the directory read is
        denied (common for guests without Group.Read.All consent), the group ID is
        returned as the display name instead of failing the whole load.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $GroupId,

        [Parameter(Mandatory)]
        [string] $GraphBaseUri,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $TenantId
    )

    $cacheKey = "$TenantId/$GroupId"
    if ($script:GroupCache.ContainsKey($cacheKey)) {
        return $script:GroupCache[$cacheKey]
    }

    # The ID comes from a Graph response rather than user input, but it is about to be
    # interpolated into a URI path, so validate it anyway.
    Assert-PimGuid -Value $GroupId -ParameterName 'GroupId'

    $result = [pscustomobject]@{
        Id          = $GroupId
        DisplayName = $GroupId
        Description = $null
        Resolved    = $false
    }

    try {
        $uri = "$(Format-PimBaseUri -Uri $GraphBaseUri)/v1.0/groups/$GroupId`?`$select=id,displayName,description"
        $response = Invoke-PimGraphRequest -Uri $uri -Method GET -MaximumRetryCount 1

        $displayName = Get-PimPropertyValue -InputObject $response -Name 'displayName'
        if (-not [string]::IsNullOrWhiteSpace($displayName)) {
            $result.DisplayName = [string]$displayName
            $result.Resolved = $true
        }
        $result.Description = [string](Get-PimPropertyValue -InputObject $response -Name 'description')
    }
    catch {
        Write-PimLog -Level Debug -Operation 'Resolve-Group' -TenantId $TenantId -GroupId $GroupId -Message "Could not resolve the group display name: $($_.Exception.Message)"
    }

    $script:GroupCache[$cacheKey] = $result
    return $result
}

function Get-PimAvailableCloudConfiguration {
    <#
    .SYNOPSIS
        Returns the built-in clouds plus any custom Az environment registered locally.

    .DESCRIPTION
        Enumerating Get-AzEnvironment and Get-MgEnvironment lets the UI offer the "Custom"
        clouds from the spec without hard-coding endpoints. Environments whose Graph
        endpoint cannot be resolved are still returned so the UI can explain why they are
        unusable, unless -SupportedOnly is specified.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [switch] $SupportedOnly
    )

    $azEnvironments = @()
    try {
        $azEnvironments = @(Invoke-PimExternalCommand -Name 'Get-AzEnvironment' -Parameters @{ ErrorAction = 'Stop' })
    }
    catch {
        Write-PimLog -Level Debug -Operation 'Get-Clouds' -Message "Could not enumerate Az environments: $($_.Exception.Message)"
    }

    $graphEnvironments = @()
    try {
        $graphEnvironments = @(Invoke-PimExternalCommand -Name 'Get-MgEnvironment' -Parameters @{ ErrorAction = 'Stop' })
    }
    catch {
        Write-PimLog -Level Debug -Operation 'Get-Clouds' -Message "Could not enumerate Microsoft Graph environments: $($_.Exception.Message)"
    }

    $all = @(Get-PimCloudConfiguration -AzEnvironment $azEnvironments -GraphEnvironment $graphEnvironments)

    if ($SupportedOnly) {
        $all = @($all | Where-Object { $_.IsSupported })
    }

    return , ([object[]]$all)
}

function Get-PimEligibleGroups {
    <#
    .SYNOPSIS
        Returns the signed-in user's eligible PIM for Groups assignments in one tenant.

    .DESCRIPTION
        Prefers the filterByCurrentUser(on='principal') function because it does not
        require the caller to know their own object ID, and falls back to the
        principalId filter when that function is unavailable.

    .PARAMETER PrincipalId
        The signed-in user's object ID in this tenant. Used for the fallback query and
        for building activation requests.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $TenantId,

        [Parameter(Mandatory)]
        [string] $PrincipalId,

        [Parameter(Mandatory)]
        [string] $GraphBaseUri,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $TenantDisplayName,

        [Parameter()]
        [switch] $SkipGroupNameResolution
    )

    $baseUri = Format-PimBaseUri -Uri $GraphBaseUri
    $schedules = $null

    # PrincipalId is interpolated into an OData filter below, so validate it even
    # though it originates from a Graph /me response.
    Assert-PimGuid -Value $PrincipalId -ParameterName 'PrincipalId'

    $queries = @(
        "$baseUri/v1.0/identityGovernance/privilegedAccess/group/eligibilitySchedules/filterByCurrentUser(on='principal')"
        "$baseUri/v1.0/identityGovernance/privilegedAccess/group/eligibilitySchedules?`$filter=principalId eq '$PrincipalId'"
    )

    $lastError = $null
    foreach ($query in $queries) {
        try {
            # No @() wrapper: Get-PimGraphCollection emits its array as a single pipeline
            # item, and @() would nest it one level deeper instead of flattening it.
            $schedules = Get-PimGraphCollection -Uri $query
            $lastError = $null
            break
        }
        catch {
            $lastError = $_
            Write-PimLog -Level Debug -Operation 'Get-Eligible' -TenantId $TenantId -Message "Eligibility query failed, trying the next form: $($_.Exception.Message)"
        }
    }

    if ($null -ne $lastError) {
        $formatted = Format-PimGraphError -ErrorObject $lastError -Context 'Could not read eligible groups.'
        Write-PimLog -Level Error -Operation 'Get-Eligible' -TenantId $TenantId -Status 'Failed' -Message $formatted.Detail
        throw $formatted.FriendlyMessage
    }

    $records = New-Object System.Collections.Generic.List[object]

    foreach ($schedule in @($schedules)) {
        if ($null -eq $schedule) { continue }

        $groupId = [string](Get-PimPropertyValue -InputObject $schedule -Name 'groupId')
        $accessId = [string](Get-PimPropertyValue -InputObject $schedule -Name 'accessId')
        $schedulePrincipalId = [string](Get-PimPropertyValue -InputObject $schedule -Name 'principalId')

        if ([string]::IsNullOrWhiteSpace($groupId)) { continue }
        if ([string]::IsNullOrWhiteSpace($accessId)) { $accessId = 'member' }
        if ([string]::IsNullOrWhiteSpace($schedulePrincipalId)) { $schedulePrincipalId = $PrincipalId }

        # filterByCurrentUser already scopes to the caller, but the fallback query is
        # filtered server-side; guard against anything unexpected slipping through.
        if (-not [string]::Equals($schedulePrincipalId, $PrincipalId, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        if ($accessId -notin @('member', 'owner')) {
            Write-PimLog -Level Warning -Operation 'Get-Eligible' -TenantId $TenantId -GroupId $groupId -Message "Skipping an eligibility with unsupported accessId '$accessId'."
            continue
        }

        $groupDisplayName = $null
        $groupDescription = $null

        # The expanded group object is present on some responses; prefer it.
        $expandedGroup = Get-PimPropertyValue -InputObject $schedule -Name 'group'
        if ($expandedGroup) {
            $groupDisplayName = [string](Get-PimPropertyValue -InputObject $expandedGroup -Name 'displayName')
            $groupDescription = [string](Get-PimPropertyValue -InputObject $expandedGroup -Name 'description')
        }

        if ([string]::IsNullOrWhiteSpace($groupDisplayName) -and -not $SkipGroupNameResolution) {
            $resolved = Resolve-PimGroup -GroupId $groupId -GraphBaseUri $baseUri -TenantId $TenantId
            $groupDisplayName = $resolved.DisplayName
            $groupDescription = $resolved.Description
        }

        $scheduleInfo = Get-PimPropertyValue -InputObject $schedule -Name 'scheduleInfo'
        $startDateTime = $null
        $endDateTime = $null
        if ($scheduleInfo) {
            $startDateTime = Get-PimPropertyValue -InputObject $scheduleInfo -Name 'startDateTime'
            $expiration = Get-PimPropertyValue -InputObject $scheduleInfo -Name 'expiration'
            if ($expiration) {
                $endDateTime = Get-PimPropertyValue -InputObject $expiration -Name 'endDateTime'
            }
        }

        $records.Add((New-PimEligibleGroupRecord `
            -TenantId $TenantId `
            -TenantDisplayName $TenantDisplayName `
            -GroupId $groupId `
            -GroupDisplayName $groupDisplayName `
            -GroupDescription $groupDescription `
            -PrincipalId $schedulePrincipalId `
            -AccessId $accessId `
            -EligibilityScheduleId ([string](Get-PimPropertyValue -InputObject $schedule -Name 'id')) `
            -Status ([string](Get-PimPropertyValue -InputObject $schedule -Name 'status')) `
            -StartDateTime $startDateTime `
            -EndDateTime $endDateTime `
            -MemberType ([string](Get-PimPropertyValue -InputObject $schedule -Name 'memberType'))))
    }

    $sorted = @($records | Sort-Object -Property GroupDisplayName, AccessId)
    Write-PimLog -Operation 'Get-Eligible' -TenantId $TenantId -Status 'Succeeded' -Message "Found $($sorted.Count) eligible group assignment(s)."
    return , ([object[]]$sorted)
}

function Request-PimGroupActivation {
    <#
    .SYNOPSIS
        Submits one PIM for Groups self-activation request.

    .DESCRIPTION
        Returns an activation result record. Failures are returned, not thrown, so a
        batch submission can continue and report every outcome.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $TenantId,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $TenantDisplayName,

        [Parameter(Mandatory)]
        [string] $PrincipalId,

        [Parameter(Mandatory)]
        [string] $GroupId,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $GroupDisplayName,

        [Parameter(Mandatory)]
        [ValidateSet('member', 'owner')]
        [string] $AccessId,

        [Parameter(Mandatory)]
        [string] $Justification,

        [Parameter(Mandatory)]
        [timespan] $Duration,

        [Parameter(Mandatory)]
        [string] $GraphBaseUri,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $TicketNumber,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $TicketSystem
    )

    $target = "group '$(if ([string]::IsNullOrWhiteSpace($GroupDisplayName)) { $GroupId } else { $GroupDisplayName })' in tenant $TenantId"
    if (-not $PSCmdlet.ShouldProcess($target, 'Submit PIM activation request')) {
        return (New-PimActivationResultRecord -TenantId $TenantId -TenantDisplayName $TenantDisplayName `
            -GroupId $GroupId -GroupDisplayName $GroupDisplayName -AccessId $AccessId `
            -Status 'Skipped' -Message 'Skipped because of -WhatIf.')
    }

    try {
        $body = New-PimActivationRequestBody `
            -PrincipalId $PrincipalId `
            -GroupId $GroupId `
            -AccessId $AccessId `
            -Justification $Justification `
            -Duration $Duration `
            -TicketNumber $TicketNumber `
            -TicketSystem $TicketSystem
    }
    catch {
        $formatted = Format-PimGraphError -ErrorObject $_
        Write-PimLog -Level Error -Operation 'Activate' -TenantId $TenantId -GroupId $GroupId -GroupDisplayName $GroupDisplayName -AccessId $AccessId -Status 'Failed' -Message $formatted.Detail
        return (New-PimActivationResultRecord -TenantId $TenantId -TenantDisplayName $TenantDisplayName `
            -GroupId $GroupId -GroupDisplayName $GroupDisplayName -AccessId $AccessId `
            -Status 'Failed' -Message $formatted.FriendlyMessage -Detail $formatted.Detail)
    }

    $uri = "$(Format-PimBaseUri -Uri $GraphBaseUri)/v1.0/identityGovernance/privilegedAccess/group/assignmentScheduleRequests"

    try {
        Write-PimLog -Operation 'Activate' -TenantId $TenantId -GroupId $GroupId -GroupDisplayName $GroupDisplayName -AccessId $AccessId -Status 'Submitting' -Message "Requesting activation for $($body.scheduleInfo.expiration.duration)."

        $response = Invoke-PimGraphRequest -Uri $uri -Method POST -Body $body

        $requestId = [string](Get-PimPropertyValue -InputObject $response -Name 'id')
        $status = [string](Get-PimPropertyValue -InputObject $response -Name 'status')

        $message = 'Activation request submitted.'
        if (-not [string]::IsNullOrWhiteSpace($status)) {
            $message = "Activation request submitted. Status: $status."
        }

        Write-PimLog -Operation 'Activate' -TenantId $TenantId -GroupId $GroupId -GroupDisplayName $GroupDisplayName -AccessId $AccessId -Status 'Success' -Message "$message RequestId: $requestId."

        return (New-PimActivationResultRecord -TenantId $TenantId -TenantDisplayName $TenantDisplayName `
            -GroupId $GroupId -GroupDisplayName $GroupDisplayName -AccessId $AccessId `
            -Status 'Success' -Message $message -RequestId $requestId)
    }
    catch {
        $formatted = Format-PimGraphError -ErrorObject $_
        Write-PimLog -Level Error -Operation 'Activate' -TenantId $TenantId -GroupId $GroupId -GroupDisplayName $GroupDisplayName -AccessId $AccessId -Status 'Failed' -Message $formatted.Detail
        return (New-PimActivationResultRecord -TenantId $TenantId -TenantDisplayName $TenantDisplayName `
            -GroupId $GroupId -GroupDisplayName $GroupDisplayName -AccessId $AccessId `
            -Status 'Failed' -Message $formatted.FriendlyMessage -Detail $formatted.Detail)
    }
}

function Get-PimActiveGroupAssignment {
    <#
    .SYNOPSIS
        Returns the signed-in user's currently active PIM for Groups assignments.

    .DESCRIPTION
        Used to show which eligible groups are already active so the user does not
        resubmit an activation that will be rejected.

        Pass -IgnoreFailure when the caller only wants a best-effort decoration of an
        existing list. Without it, a failure is thrown so the caller can tell "nothing
        is active" apart from "the query did not run".
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $GraphBaseUri,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $TenantId,

        [Parameter()]
        [switch] $IgnoreFailure
    )

    $baseUri = Format-PimBaseUri -Uri $GraphBaseUri
    $uri = "$baseUri/v1.0/identityGovernance/privilegedAccess/group/assignmentSchedules/filterByCurrentUser(on='principal')"

    try {
        $schedules = Get-PimGraphCollection -Uri $uri
    }
    catch {
        $formatted = Format-PimGraphError -ErrorObject $_ -Context 'Could not read active assignments.'
        Write-PimLog -Level Warning -Operation 'Get-Active' -TenantId $TenantId -Status 'Failed' -Message $formatted.Detail
        if ($IgnoreFailure) { return , ([object[]]@()) }
        throw $formatted.FriendlyMessage
    }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($schedule in $schedules) {
        if ($null -eq $schedule) { continue }

        $assignmentType = [string](Get-PimPropertyValue -InputObject $schedule -Name 'assignmentType')
        # 'activated' means it came from an eligibility; 'assigned' is a direct active assignment.
        $records.Add([pscustomobject]@{
            GroupId        = [string](Get-PimPropertyValue -InputObject $schedule -Name 'groupId')
            AccessId       = [string](Get-PimPropertyValue -InputObject $schedule -Name 'accessId')
            AssignmentType = $assignmentType
            Status         = [string](Get-PimPropertyValue -InputObject $schedule -Name 'status')
            MemberType     = [string](Get-PimPropertyValue -InputObject $schedule -Name 'memberType')
        })
    }

    return , ([object[]]$records.ToArray())
}

Export-ModuleMember -Function @(
    'Get-PimDefaultGraphScope'
    'Get-PimMinimumGraphScope'
    'Set-PimCommandOverride'
    'Clear-PimCommandOverride'
    'Invoke-PimExternalCommand'
    'Get-PimRequiredModule'
    'Test-PimModuleAvailability'
    'Import-PimRequiredModule'
    'Get-PimAzureContext'
    'Test-PimAzureContext'
    'Connect-PimAzureAccount'
    'Disconnect-PimAzureAccount'
    'Get-PimAuthorizedTenant'
    'Get-PimGraphContext'
    'Get-PimGraphAuthenticationVersion'
    'Test-PimGraphContext'
    'Connect-PimGraphTenant'
    'Compare-PimScopeSet'
    'New-PimGraphConnectionResult'
    'Disconnect-PimGraph'
    'Invoke-PimGraphRequest'
    'Get-PimSafeUri'
    'Get-PimRetryDelaySecond'
    'Get-PimGraphCollection'
    'Get-CurrentGraphUser'
    'Clear-PimGroupCache'
    'Resolve-PimGroup'
    'Get-PimAvailableCloudConfiguration'
    'Get-PimEligibleGroups'
    'Request-PimGroupActivation'
    'Get-PimActiveGroupAssignment'
)
