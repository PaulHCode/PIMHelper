<#
.SYNOPSIS
    Requests Privileged Identity Management (PIM) activation for Microsoft Entra ID groups
    across every tenant where the signed-in user has access.

.DESCRIPTION
    Launches a WinForms interface by default. Headless switches are provided so the same
    code paths can be driven from a terminal, a pipeline, or a remote session where no
    interactive desktop is available.

    The tool uses delegated authentication through the first-party Microsoft Graph
    PowerShell enterprise application, so no custom app registration is required.

.PARAMETER Cloud
    Azure cloud to sign in to. Defaults to the commercial cloud. Locally registered
    custom Azure environments are also accepted by name.

.PARAMETER ListTenants
    Headless mode. Signs in to Azure and lists every tenant the account can reach.

.PARAMETER ListGroups
    Headless mode. Lists PIM-eligible group assignments. Limit the scope with -TenantId.

.PARAMETER ListActive
    Headless mode. Lists currently active (already activated) group assignments.

.PARAMETER Activate
    Headless mode. Requests activation for the groups named by -GroupId.

.PARAMETER TenantId
    One or more tenant IDs. Required for -Activate; optional filter for the list modes.

.PARAMETER GroupId
    One or more group object IDs to activate. Required for -Activate.

.PARAMETER AccessId
    Role to activate: 'member' (default) or 'owner'.

.PARAMETER Justification
    Business justification recorded in the PIM audit log. Required for -Activate.

.PARAMETER Duration
    Activation duration. Accepts a TimeSpan or a string such as '2:00:00' or '08:00:00'.
    Defaults to 2 hours.

.PARAMETER TicketNumber
    Optional ticket number recorded with the request.

.PARAMETER TicketSystem
    Optional ticket system name recorded with the request.

.PARAMETER LogPath
    Overrides the default log file location.

.PARAMETER NoLog
    Disables file logging for this run.

.PARAMETER UseDeviceAuthentication
    Signs in with a device code instead of a browser. Use this over a remote session.

.PARAMETER SkipModuleCheck
    Skips the prerequisite module check. Use only when you know the modules are present.

.EXAMPLE
    .\Start-PimGroupActivationTool.ps1

    Launches the graphical interface.

.EXAMPLE
    .\Start-PimGroupActivationTool.ps1 -ListTenants

    Signs in and prints every reachable tenant.

.EXAMPLE
    .\Start-PimGroupActivationTool.ps1 -ListGroups -TenantId da667b97-c1f7-494e-b7ba-172131cd40d9

    Prints the PIM-eligible groups in one tenant.

.EXAMPLE
    .\Start-PimGroupActivationTool.ps1 -Activate -TenantId <tenant> -GroupId <group> -Justification 'Change 12345' -Duration 02:00:00

    Requests a two-hour member activation.

.NOTES
    Requires Az.Accounts and Microsoft.Graph.Authentication.
    The graphical interface requires a single-threaded apartment; the script relaunches
    itself with -STA automatically when needed.
#>
[CmdletBinding(DefaultParameterSetName = 'Gui')]
param(
    [Parameter(ParameterSetName = 'Gui')]
    [Parameter(ParameterSetName = 'ListTenants')]
    [Parameter(ParameterSetName = 'ListGroups')]
    [Parameter(ParameterSetName = 'ListActive')]
    [Parameter(ParameterSetName = 'Activate')]
    [string] $Cloud = 'Commercial',

    [Parameter(Mandatory, ParameterSetName = 'ListTenants')]
    [switch] $ListTenants,

    [Parameter(Mandatory, ParameterSetName = 'ListGroups')]
    [switch] $ListGroups,

    [Parameter(Mandatory, ParameterSetName = 'ListActive')]
    [switch] $ListActive,

    [Parameter(Mandatory, ParameterSetName = 'Activate')]
    [switch] $Activate,

    [Parameter(ParameterSetName = 'ListGroups')]
    [Parameter(ParameterSetName = 'ListActive')]
    [Parameter(Mandatory, ParameterSetName = 'Activate')]
    [string[]] $TenantId,

    [Parameter(Mandatory, ParameterSetName = 'Activate')]
    [string[]] $GroupId,

    [Parameter(ParameterSetName = 'Activate')]
    [ValidateSet('member', 'owner')]
    [string] $AccessId = 'member',

    [Parameter(Mandatory, ParameterSetName = 'Activate')]
    [string] $Justification,

    [Parameter(ParameterSetName = 'Activate')]
    [timespan] $Duration = ([timespan]::FromHours(2)),

    [Parameter(ParameterSetName = 'Activate')]
    [string] $TicketNumber,

    [Parameter(ParameterSetName = 'Activate')]
    [string] $TicketSystem,

    [string] $LogPath,

    [switch] $NoLog,

    [switch] $UseDeviceAuthentication,

    [switch] $SkipModuleCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SourceRoot = Join-Path -Path $PSScriptRoot -ChildPath 'src'

# ---------------------------------------------------------------------------
# Apartment state
# ---------------------------------------------------------------------------

# WinForms requires STA. PowerShell 7 defaults to MTA on Windows, so relaunch
# once rather than failing with an obscure COM error later.
if ($PSCmdlet.ParameterSetName -eq 'Gui' -and [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    if ($env:PIM_STA_RELAUNCHED -eq '1') {
        throw 'Unable to switch to a single-threaded apartment. Start PowerShell with -STA and try again.'
    }

    Write-Verbose 'Relaunching in a single-threaded apartment for WinForms.'
    $hostExe = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrWhiteSpace($hostExe)) { $hostExe = 'pwsh' }

    $arguments = @('-NoProfile', '-STA', '-File', $PSCommandPath)
    if ($PSBoundParameters.ContainsKey('Cloud'))   { $arguments += @('-Cloud', $Cloud) }
    if ($PSBoundParameters.ContainsKey('LogPath')) { $arguments += @('-LogPath', $LogPath) }
    if ($NoLog)                                    { $arguments += '-NoLog' }
    if ($UseDeviceAuthentication)                  { $arguments += '-UseDeviceAuthentication' }
    if ($SkipModuleCheck)                          { $arguments += '-SkipModuleCheck' }

    $env:PIM_STA_RELAUNCHED = '1'
    try {
        & $hostExe @arguments
        exit $LASTEXITCODE
    }
    finally {
        Remove-Item Env:\PIM_STA_RELAUNCHED -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Module import
# ---------------------------------------------------------------------------

$isGui = $PSCmdlet.ParameterSetName -eq 'Gui'

$toolModules = @('PimModels.psm1', 'PimLogging.psm1', 'PimGraph.psm1')
if ($isGui) { $toolModules += 'PimUi.psm1' }

foreach ($moduleFile in $toolModules) {
    $modulePath = Join-Path -Path $script:SourceRoot -ChildPath $moduleFile
    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw "Required module file '$modulePath' is missing. Re-download the tool."
    }
    Import-Module -Name $modulePath -Force -DisableNameChecking -ErrorAction Stop
}

if ($NoLog) {
    Initialize-PimLog -Disable | Out-Null
}
elseif ($PSBoundParameters.ContainsKey('LogPath')) {
    Initialize-PimLog -Path $LogPath | Out-Null
}
else {
    Initialize-PimLog | Out-Null
}

$logState = Get-PimLogState
if ($logState.Enabled) { Write-Verbose "Logging to $($logState.FilePath)" }

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

function Confirm-PimPrerequisite {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch] $Interactive
    )

    $missing = @(Test-PimModuleAvailability | Where-Object { -not $_.IsAvailable })
    if ($missing.Count -eq 0) { return $true }

    $missingText = ($missing | ForEach-Object { "$($_.Name) (>= $($_.MinimumVersion))" }) -join ', '
    Write-Warning "Missing required module(s): $missingText"

    $install = $false
    if ($Interactive) {
        $answer = Read-Host 'Install the missing module(s) for the current user now? [y/N]'
        $install = $answer -match '^(y|yes)$'
    }

    if (-not $install) {
        Write-Warning "Install them with: Install-Module $(($missing | ForEach-Object { $_.InstallName }) -join ', ') -Scope CurrentUser"
        return $false
    }

    foreach ($module in $missing) {
        if ($PSCmdlet.ShouldProcess($module.InstallName, 'Install module for the current user')) {
            Write-Host "Installing $($module.InstallName)..."
            Install-Module -Name $module.InstallName -MinimumVersion $module.MinimumVersion -Scope CurrentUser -Force -AllowClobber
        }
    }

    return (@(Test-PimModuleAvailability | Where-Object { -not $_.IsAvailable }).Count -eq 0)
}

if (-not $SkipModuleCheck) {
    if (-not (Confirm-PimPrerequisite -Interactive:(-not $isGui))) {
        if ($isGui) {
            Add-Type -AssemblyName System.Windows.Forms
            [void][System.Windows.Forms.MessageBox]::Show(
                "This tool needs Az.Accounts and Microsoft.Graph.Authentication.`r`n`r`nInstall them with:`r`nInstall-Module Az.Accounts, Microsoft.Graph.Authentication -Scope CurrentUser",
                'Missing prerequisites',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
        exit 2
    }
}

Import-PimRequiredModule

# ---------------------------------------------------------------------------
# Cloud selection
# ---------------------------------------------------------------------------

$cloudConfiguration = $null
$availableClouds = Get-PimAvailableCloudConfiguration
foreach ($candidate in $availableClouds) {
    if ($candidate.DisplayName -eq $Cloud -or $candidate.AzEnvironment -eq $Cloud) {
        $cloudConfiguration = $candidate
        break
    }
}

if ($null -eq $cloudConfiguration) {
    $cloudConfiguration = Get-PimCloudConfiguration -Name $Cloud
}

if (-not $cloudConfiguration.IsSupported) {
    throw $cloudConfiguration.UnsupportedReason
}

# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------

if ($isGui) {
    $logState = Get-PimLogState
    Show-PimMainForm -CloudName $cloudConfiguration.DisplayName -LogDirectory $logState.Directory

    # Not `exit 0`. If the user closed the window while an interactive sign-in
    # prompt was still up, that worker is a foreground thread that ignores Stop()
    # until the broker gives up, and a normal exit waits for it. The window would
    # vanish while pwsh.exe stayed resident, still holding the auth listener. The
    # UI is gone and there is nothing left to finish, so end the process outright.
    [Environment]::Exit(0)
}

# ---------------------------------------------------------------------------
# Headless helpers
# ---------------------------------------------------------------------------

# Captured from the Azure sign-in so a stale Graph context belonging to a
# different user is never reused.
$script:PimSignedInAccount = $null

function Connect-PimHeadlessTenant {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Tenant
    )

    $connection = Connect-PimGraphTenant -TenantId $Tenant -CloudConfiguration $cloudConfiguration -UseDeviceAuthentication:$UseDeviceAuthentication -ExpectedAccount $script:PimSignedInAccount
    if (-not $connection.Success) {
        throw $connection.Message
    }

    if ($connection.PSObject.Properties['HasGroupRead'] -and -not $connection.HasGroupRead) {
        Write-Warning "Group.Read.All was not granted in tenant $Tenant. Group display names will fall back to object IDs."
    }

    return $connection
}

function Get-PimHeadlessTenantList {
    [CmdletBinding()]
    param()

    $signIn = Connect-PimAzureAccount -CloudConfiguration $cloudConfiguration -UseDeviceAuthentication:$UseDeviceAuthentication
    $script:PimSignedInAccount = $signIn.Account
    Write-Host "Signed in as $($signIn.Account) ($($cloudConfiguration.DisplayName))." -ForegroundColor Green

    $tenants = Get-PimAuthorizedTenant -CloudConfiguration $cloudConfiguration
    if ($TenantId) {
        $wanted = [System.Collections.Generic.HashSet[string]]::new([string[]]$TenantId, [System.StringComparer]::OrdinalIgnoreCase)
        $tenants = @($tenants | Where-Object { $wanted.Contains($_.TenantId) })
    }

    return , ([object[]]$tenants)
}

# ---------------------------------------------------------------------------
# Headless modes
# ---------------------------------------------------------------------------

if ($ListTenants) {
    $tenants = Get-PimHeadlessTenantList
    Write-Host "Found $($tenants.Count) tenant(s)." -ForegroundColor Cyan
    $tenants | Select-Object TenantDisplayName, PrimaryDomain, TenantId, Category | Format-Table -AutoSize | Out-Host
    $tenants
    exit 0
}

if ($ListGroups) {
    $tenants = Get-PimHeadlessTenantList
    if ($tenants.Count -eq 0) {
        Write-Warning 'No tenants matched. Nothing to enumerate.'
        exit 1
    }

    $allGroups = [System.Collections.Generic.List[object]]::new()
    foreach ($tenant in $tenants) {
        Write-Host "Querying $($tenant.TenantDisplayName) ($($tenant.TenantId))..." -ForegroundColor Cyan
        try {
            $connection = Connect-PimHeadlessTenant -Tenant $tenant.TenantId
            $skipNames = ($connection.PSObject.Properties['HasGroupRead'] -and -not $connection.HasGroupRead)

            $me = Get-CurrentGraphUser -GraphBaseUri $cloudConfiguration.GraphBaseUri
            $groups = Get-PimEligibleGroups -TenantId $tenant.TenantId -PrincipalId $me.Id `
                -GraphBaseUri $cloudConfiguration.GraphBaseUri -TenantDisplayName $tenant.TenantDisplayName `
                -SkipGroupNameResolution:$skipNames

            foreach ($group in $groups) { $allGroups.Add($group) }
            Write-Host "  $($groups.Count) eligible assignment(s)." -ForegroundColor Green
        }
        catch {
            # One unreachable tenant must not abort the sweep.
            Write-Warning "  $($tenant.TenantDisplayName): $(Remove-PimSensitiveData -Text (ConvertTo-PimErrorText -ErrorObject $_))"
        }
    }

    $allGroups | Select-Object TenantDisplayName, GroupDisplayName, AccessId, Status, GroupId, TenantId |
        Format-Table -AutoSize | Out-Host
    $allGroups
    exit 0
}

if ($ListActive) {
    $tenants = Get-PimHeadlessTenantList
    $allActive = [System.Collections.Generic.List[object]]::new()

    foreach ($tenant in $tenants) {
        Write-Host "Querying $($tenant.TenantDisplayName) ($($tenant.TenantId))..." -ForegroundColor Cyan
        try {
            $null = Connect-PimHeadlessTenant -Tenant $tenant.TenantId
            $active = Get-PimActiveGroupAssignment -GraphBaseUri $cloudConfiguration.GraphBaseUri -TenantId $tenant.TenantId -TenantDisplayName $tenant.TenantDisplayName
            foreach ($item in $active) { $allActive.Add($item) }
            Write-Host "  $($active.Count) active assignment(s)." -ForegroundColor Green
        }
        catch {
            Write-Warning "  $($tenant.TenantDisplayName): $(Remove-PimSensitiveData -Text (ConvertTo-PimErrorText -ErrorObject $_))"
        }
    }

    $allActive | Select-Object TenantDisplayName, GroupId, AccessId, AssignmentType, Status, MemberType, TenantId |
        Format-Table -AutoSize | Out-Host
    $allActive
    exit 0
}

if ($Activate) {
    if (-not (Test-PimJustification -Justification $Justification)) {
        throw 'The justification is too short. Provide at least 10 characters describing why access is needed.'
    }

    if ($TenantId.Count -ne 1) {
        throw 'Specify exactly one -TenantId when activating. Run the tool once per tenant.'
    }

    $tenant = $TenantId[0]
    Assert-PimGuid -Value $tenant -ParameterName 'TenantId'
    foreach ($id in $GroupId) { Assert-PimGuid -Value $id -ParameterName 'GroupId' }

    $signIn = Connect-PimAzureAccount -CloudConfiguration $cloudConfiguration -UseDeviceAuthentication:$UseDeviceAuthentication
    $script:PimSignedInAccount = $signIn.Account
    $null = Connect-PimHeadlessTenant -Tenant $tenant
    $me = Get-CurrentGraphUser -GraphBaseUri $cloudConfiguration.GraphBaseUri
    Write-Host "Activating as $($me.UserPrincipalName) in tenant $tenant." -ForegroundColor Cyan

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $GroupId) {
        $result = Request-PimGroupActivation -TenantId $tenant -PrincipalId $me.Id -GroupId $id `
            -AccessId $AccessId -Justification $Justification -Duration $Duration `
            -GraphBaseUri $cloudConfiguration.GraphBaseUri -TicketNumber $TicketNumber -TicketSystem $TicketSystem
        $results.Add($result)

        $colour = if ($result.Status -eq 'Success') { 'Green' } else { 'Red' }
        Write-Host "  [$($result.Status)] $($result.GroupDisplayName): $($result.Message)" -ForegroundColor $colour
    }

    $results | Select-Object GroupDisplayName, AccessId, Status, Message, RequestId | Format-Table -AutoSize | Out-Host
    $results

    $failureCount = @($results | Where-Object { $_.Status -eq 'Failed' }).Count
    exit ([int]($failureCount -gt 0))
}
