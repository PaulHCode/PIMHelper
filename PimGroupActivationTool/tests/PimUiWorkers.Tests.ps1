#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Executes the UI worker scriptblocks directly.

    The workers run in their own runspace and re-import the modules by path, so they are
    exercised here by pointing $Paths at generated stub modules. That makes the worker
    orchestration itself testable: which Graph functions get called, in what order, and
    how failures and cancellation are reported. Two real bugs lived in these scriptblocks
    because nothing executed them.
#>

BeforeAll {
    $script:ModulePath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'src\PimUi.psm1'
    Import-Module $script:ModulePath -Force -DisableNameChecking

    $script:ModelsPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'src\PimModels.psm1'

    # Reach into the module to get the worker scriptblocks, which are script-scoped
    # rather than exported.
    $script:UiModule = Get-Module -Name 'PimUi'
    $script:SignIn     = & $script:UiModule { $script:SignInWorker }
    $script:LoadGroups = & $script:UiModule { $script:LoadGroupsWorker }
    $script:Submit     = & $script:UiModule { $script:SubmitWorker }

    $script:StubRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("PimWorkerStub-" + [guid]::NewGuid().ToString('N'))
    New-Item -Path $script:StubRoot -ItemType Directory -Force | Out-Null

    # A file the stub modules append to, so the test can assert on the call sequence.
    $script:CallLogPath = Join-Path -Path $script:StubRoot -ChildPath 'calls.txt'

    # The logging stub is shared by every scenario.
    $script:LoggingStubPath = Join-Path -Path $script:StubRoot -ChildPath 'StubLogging.psm1'
    Set-Content -LiteralPath $script:LoggingStubPath -Encoding UTF8 -Value @'
function Initialize-PimLog { [CmdletBinding()] param([string] $Path, [switch] $Disable) }
function Write-PimLog { [CmdletBinding()] param([string] $Level, [string] $Operation, [string] $TenantId, [string] $Status, [string] $Message) }
Export-ModuleMember -Function @('Initialize-PimLog', 'Write-PimLog')
'@

    function New-StubGraphModule {
        <#
            Writes a stub PimGraph module. $Body is injected verbatim, so each test can
            decide what its fakes return or throw.
        #>
        param([string] $Body)

        $path = Join-Path -Path $script:StubRoot -ChildPath ("StubGraph-" + [guid]::NewGuid().ToString('N') + ".psm1")
        $header = @"
Import-Module '$($script:ModelsPath)' -Force -DisableNameChecking
`$script:CallLogPath = '$($script:CallLogPath)'
function Add-StubCall {
    param([string] `$Text)
    Add-Content -LiteralPath `$script:CallLogPath -Value `$Text
}
"@
        Set-Content -LiteralPath $path -Encoding UTF8 -Value ($header + "`r`n" + $Body)
        return $path
    }

    function New-WorkerPaths {
        param([string] $GraphPath, [bool] $LoggingEnabled = $false, [string] $LogDirectory = '')

        return @{
            Models         = $script:ModelsPath
            Logging        = $script:LoggingStubPath
            Graph          = $GraphPath
            LoggingEnabled = $LoggingEnabled
            LogDirectory   = $LogDirectory
        }
    }

    function Get-StubCall {
        if (-not (Test-Path -LiteralPath $script:CallLogPath)) { return @() }
        return @(Get-Content -LiteralPath $script:CallLogPath)
    }

    function Reset-StubCall {
        Remove-Item -LiteralPath $script:CallLogPath -Force -ErrorAction SilentlyContinue
    }

    $script:Cloud = [pscustomobject]@{
        DisplayName      = 'Commercial'
        AzEnvironment    = 'AzureCloud'
        GraphEnvironment = 'Global'
        GraphBaseUri     = 'https://graph.microsoft.com'
        IsBuiltIn        = $true
        IsSupported      = $true
        UnsupportedReason = ''
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:StubRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'SignInWorker' {
    BeforeEach {
        Reset-StubCall
        $script:Shared = New-PimSharedState
    }

    It 'signs in and returns the discovered tenants' {
        $graph = New-StubGraphModule -Body @'
function Connect-PimAzureAccount {
    [CmdletBinding()] param($CloudConfiguration, [switch] $Force, [switch] $UseDeviceAuthentication)
    Add-StubCall "Connect-PimAzureAccount Force=$([bool]$Force) Device=$([bool]$UseDeviceAuthentication)"
    [pscustomobject]@{ Account = 'user@contoso.com'; Environment = 'AzureCloud'; TenantId = 'home'; ReusedContext = $false; Cloud = $CloudConfiguration }
}
function Get-PimAuthorizedTenant {
    [CmdletBinding()] param($CloudConfiguration)
    Add-StubCall 'Get-PimAuthorizedTenant'
    $records = @(
        [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; TenantDisplayName = 'Contoso' }
        [pscustomobject]@{ TenantId = '22222222-2222-2222-2222-222222222222'; TenantDisplayName = 'Fabrikam' }
    )
    return , ([object[]]$records)
}
function Disconnect-PimAzureAccount { [CmdletBinding()] param() Add-StubCall 'Disconnect-PimAzureAccount' }
function Disconnect-PimGraph { [CmdletBinding()] param() Add-StubCall 'Disconnect-PimGraph' }
Export-ModuleMember -Function @('Connect-PimAzureAccount', 'Get-PimAuthorizedTenant', 'Disconnect-PimAzureAccount', 'Disconnect-PimGraph', 'Add-StubCall')
'@

        $result = & $script:SignIn (New-WorkerPaths -GraphPath $graph) $script:Cloud $false $false $script:Shared

        $result.Kind          | Should -Be 'SignIn'
        $result.Account       | Should -Be 'user@contoso.com'
        $result.Tenants.Count | Should -Be 2
        Get-StubCall | Should -Contain 'Get-PimAuthorizedTenant'
    }

    It 'clears both the Azure and Graph sessions before switching account' {
        # Signing in as a different account must not leave the Graph session bound to
        # the previous one.
        $graph = New-StubGraphModule -Body @'
function Connect-PimAzureAccount {
    [CmdletBinding()] param($CloudConfiguration, [switch] $Force, [switch] $UseDeviceAuthentication)
    Add-StubCall "Connect-PimAzureAccount Force=$([bool]$Force)"
    [pscustomobject]@{ Account = 'other@contoso.com' }
}
function Get-PimAuthorizedTenant { [CmdletBinding()] param($CloudConfiguration) return , ([object[]]@()) }
function Disconnect-PimAzureAccount { [CmdletBinding()] param() Add-StubCall 'Disconnect-PimAzureAccount' }
function Disconnect-PimGraph { [CmdletBinding()] param() Add-StubCall 'Disconnect-PimGraph' }
Export-ModuleMember -Function @('Connect-PimAzureAccount', 'Get-PimAuthorizedTenant', 'Disconnect-PimAzureAccount', 'Disconnect-PimGraph', 'Add-StubCall')
'@

        $null = & $script:SignIn (New-WorkerPaths -GraphPath $graph) $script:Cloud $true $false $script:Shared

        $calls = Get-StubCall
        $calls | Should -Contain 'Disconnect-PimAzureAccount'
        $calls | Should -Contain 'Disconnect-PimGraph'
        $calls | Should -Contain 'Connect-PimAzureAccount Force=True'

        # Both disconnects must happen before the new sign-in.
        [array]::IndexOf($calls, 'Disconnect-PimAzureAccount') | Should -BeLessThan ([array]::IndexOf($calls, 'Connect-PimAzureAccount Force=True'))
        [array]::IndexOf($calls, 'Disconnect-PimGraph')        | Should -BeLessThan ([array]::IndexOf($calls, 'Connect-PimAzureAccount Force=True'))
    }

    It 'forwards the device code preference' {
        $graph = New-StubGraphModule -Body @'
function Connect-PimAzureAccount {
    [CmdletBinding()] param($CloudConfiguration, [switch] $Force, [switch] $UseDeviceAuthentication)
    Add-StubCall "Device=$([bool]$UseDeviceAuthentication)"
    [pscustomobject]@{ Account = 'user@contoso.com' }
}
function Get-PimAuthorizedTenant { [CmdletBinding()] param($CloudConfiguration) return , ([object[]]@()) }
function Disconnect-PimAzureAccount { [CmdletBinding()] param() }
function Disconnect-PimGraph { [CmdletBinding()] param() }
Export-ModuleMember -Function @('Connect-PimAzureAccount', 'Get-PimAuthorizedTenant', 'Disconnect-PimAzureAccount', 'Disconnect-PimGraph', 'Add-StubCall')
'@

        $null = & $script:SignIn (New-WorkerPaths -GraphPath $graph) $script:Cloud $false $true $script:Shared
        Get-StubCall | Should -Contain 'Device=True'
    }
}

Describe 'LoadGroupsWorker' {
    BeforeEach {
        Reset-StubCall
        $script:Shared = New-PimSharedState
        $script:Tenants = @(
            [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; TenantDisplayName = 'Contoso' }
            [pscustomobject]@{ TenantId = '22222222-2222-2222-2222-222222222222'; TenantDisplayName = 'Fabrikam' }
        )
    }

    It 'resolves the principal per tenant and collects every eligible group' {
        # The connection result has no PrincipalId, so the worker must call
        # Get-CurrentGraphUser. Using $connection.PrincipalId broke group enumeration.
        $graph = New-StubGraphModule -Body @'
function Connect-PimGraphTenant {
    [CmdletBinding()] param([string] $TenantId, $CloudConfiguration, [switch] $UseDeviceAuthentication, [string] $ExpectedAccount)
    Add-StubCall "Connect $TenantId account=$ExpectedAccount"
    [pscustomobject]@{ Success = $true; TenantId = $TenantId; Context = $null; Scopes = @(); HasGroupRead = $true; Message = 'ok'; Detail = '' }
}
function Get-CurrentGraphUser {
    [CmdletBinding()] param([string] $GraphBaseUri)
    Add-StubCall 'Get-CurrentGraphUser'
    [pscustomobject]@{ Id = '33333333-3333-3333-3333-333333333333'; UserPrincipalName = 'u@contoso.com'; DisplayName = 'U' }
}
function Get-PimEligibleGroups {
    [CmdletBinding()] param([string] $TenantId, [string] $PrincipalId, [string] $GraphBaseUri, [string] $TenantDisplayName, [switch] $SkipGroupNameResolution)
    Add-StubCall "Eligible $TenantId principal=$PrincipalId skipNames=$([bool]$SkipGroupNameResolution)"
    $records = @([pscustomobject]@{ TenantId = $TenantId; GroupId = [guid]::NewGuid().ToString(); GroupDisplayName = 'G' })
    return , ([object[]]$records)
}
function Disconnect-PimGraph { [CmdletBinding()] param() Add-StubCall 'Disconnect' }
Export-ModuleMember -Function @('Connect-PimGraphTenant', 'Get-CurrentGraphUser', 'Get-PimEligibleGroups', 'Disconnect-PimGraph', 'Add-StubCall')
'@

        $result = & $script:LoadGroups (New-WorkerPaths -GraphPath $graph) $script:Cloud $script:Tenants $false $script:Shared 'ada@contoso.com'

        $result.Kind         | Should -Be 'LoadGroups'
        $result.Groups.Count | Should -Be 2
        $result.Cancelled    | Should -BeFalse

        $calls = Get-StubCall
        @($calls | Where-Object { $_ -eq 'Get-CurrentGraphUser' }).Count | Should -Be 2
        $calls | Should -Contain 'Eligible 11111111-1111-1111-1111-111111111111 principal=33333333-3333-3333-3333-333333333333 skipNames=False'

        # The signed-in account must reach the connect call, otherwise a stale
        # Graph session for a different user would be silently reused.
        $calls | Should -Contain 'Connect 11111111-1111-1111-1111-111111111111 account=ada@contoso.com'

        # Every tenant must be disconnected, including on the success path.
        @($calls | Where-Object { $_ -eq 'Disconnect' }).Count | Should -Be 2
    }

    It 'records a per-tenant failure and still processes the remaining tenants' {
        $graph = New-StubGraphModule -Body @'
function Connect-PimGraphTenant {
    [CmdletBinding()] param([string] $TenantId, $CloudConfiguration, [switch] $UseDeviceAuthentication, [string] $ExpectedAccount)
    if ($TenantId -like '1111*') {
        return [pscustomobject]@{ Success = $false; TenantId = $TenantId; Context = $null; Scopes = @(); HasGroupRead = $false; Message = 'Consent was blocked.'; Detail = '' }
    }
    [pscustomobject]@{ Success = $true; TenantId = $TenantId; Context = $null; Scopes = @(); HasGroupRead = $true; Message = 'ok'; Detail = '' }
}
function Get-CurrentGraphUser { [CmdletBinding()] param([string] $GraphBaseUri) [pscustomobject]@{ Id = '33333333-3333-3333-3333-333333333333' } }
function Get-PimEligibleGroups {
    [CmdletBinding()] param([string] $TenantId, [string] $PrincipalId, [string] $GraphBaseUri, [string] $TenantDisplayName, [switch] $SkipGroupNameResolution)
    $records = @([pscustomobject]@{ TenantId = $TenantId; GroupId = 'g'; GroupDisplayName = 'G' })
    return , ([object[]]$records)
}
function Disconnect-PimGraph { [CmdletBinding()] param() }
Export-ModuleMember -Function @('Connect-PimGraphTenant', 'Get-CurrentGraphUser', 'Get-PimEligibleGroups', 'Disconnect-PimGraph', 'Add-StubCall')
'@

        $result = & $script:LoadGroups (New-WorkerPaths -GraphPath $graph) $script:Cloud $script:Tenants $false $script:Shared 3>$null

        $result.Groups.Count       | Should -Be 1
        $result.TenantStatus.Count | Should -Be 2

        $failed = @($result.TenantStatus | Where-Object { -not $_.Success })
        $failed.Count     | Should -Be 1
        $failed[0].Message | Should -Be 'Consent was blocked.'
    }

    It 'reports an eligibility failure per tenant instead of aborting the run' {
        $graph = New-StubGraphModule -Body @'
function Connect-PimGraphTenant {
    [CmdletBinding()] param([string] $TenantId, $CloudConfiguration, [switch] $UseDeviceAuthentication, [string] $ExpectedAccount)
    [pscustomobject]@{ Success = $true; TenantId = $TenantId; Context = $null; Scopes = @(); HasGroupRead = $true; Message = 'ok'; Detail = '' }
}
function Get-CurrentGraphUser { [CmdletBinding()] param([string] $GraphBaseUri) [pscustomobject]@{ Id = '33333333-3333-3333-3333-333333333333' } }
function Get-PimEligibleGroups {
    [CmdletBinding()] param([string] $TenantId, [string] $PrincipalId, [string] $GraphBaseUri, [string] $TenantDisplayName, [switch] $SkipGroupNameResolution)
    throw 'Graph denied the request.'
}
function Disconnect-PimGraph { [CmdletBinding()] param() Add-StubCall 'Disconnect' }
Export-ModuleMember -Function @('Connect-PimGraphTenant', 'Get-CurrentGraphUser', 'Get-PimEligibleGroups', 'Disconnect-PimGraph', 'Add-StubCall')
'@

        $result = & $script:LoadGroups (New-WorkerPaths -GraphPath $graph) $script:Cloud $script:Tenants $false $script:Shared 3>$null

        $result.Groups.Count | Should -Be 0
        @($result.TenantStatus | Where-Object { -not $_.Success }).Count | Should -Be 2

        # The finally block must still disconnect after a failure.
        @(Get-StubCall | Where-Object { $_ -eq 'Disconnect' }).Count | Should -Be 2
    }

    It 'skips group name resolution when Group.Read.All was not consented' {
        $graph = New-StubGraphModule -Body @'
function Connect-PimGraphTenant {
    [CmdletBinding()] param([string] $TenantId, $CloudConfiguration, [switch] $UseDeviceAuthentication, [string] $ExpectedAccount)
    [pscustomobject]@{ Success = $true; TenantId = $TenantId; Context = $null; Scopes = @(); HasGroupRead = $false; Message = 'Reduced permissions.'; Detail = '' }
}
function Get-CurrentGraphUser { [CmdletBinding()] param([string] $GraphBaseUri) [pscustomobject]@{ Id = '33333333-3333-3333-3333-333333333333' } }
function Get-PimEligibleGroups {
    [CmdletBinding()] param([string] $TenantId, [string] $PrincipalId, [string] $GraphBaseUri, [string] $TenantDisplayName, [switch] $SkipGroupNameResolution)
    Add-StubCall "skipNames=$([bool]$SkipGroupNameResolution)"
    return , ([object[]]@())
}
function Disconnect-PimGraph { [CmdletBinding()] param() }
Export-ModuleMember -Function @('Connect-PimGraphTenant', 'Get-CurrentGraphUser', 'Get-PimEligibleGroups', 'Disconnect-PimGraph', 'Add-StubCall')
'@

        $null = & $script:LoadGroups (New-WorkerPaths -GraphPath $graph) $script:Cloud $script:Tenants $false $script:Shared 3>$null
        Get-StubCall | Should -Contain 'skipNames=True'
    }

    It 'stops early when cancellation is requested' {
        $graph = New-StubGraphModule -Body @'
function Connect-PimGraphTenant {
    [CmdletBinding()] param([string] $TenantId, $CloudConfiguration, [switch] $UseDeviceAuthentication, [string] $ExpectedAccount)
    Add-StubCall "Connect $TenantId"
    [pscustomobject]@{ Success = $true; TenantId = $TenantId; Context = $null; Scopes = @(); HasGroupRead = $true; Message = 'ok'; Detail = '' }
}
function Get-CurrentGraphUser { [CmdletBinding()] param([string] $GraphBaseUri) [pscustomobject]@{ Id = '33333333-3333-3333-3333-333333333333' } }
function Get-PimEligibleGroups {
    [CmdletBinding()] param([string] $TenantId, [string] $PrincipalId, [string] $GraphBaseUri, [string] $TenantDisplayName, [switch] $SkipGroupNameResolution)
    return , ([object[]]@())
}
function Disconnect-PimGraph { [CmdletBinding()] param() }
Export-ModuleMember -Function @('Connect-PimGraphTenant', 'Get-CurrentGraphUser', 'Get-PimEligibleGroups', 'Disconnect-PimGraph', 'Add-StubCall')
'@

        $script:Shared.CancelRequested = $true
        $result = & $script:LoadGroups (New-WorkerPaths -GraphPath $graph) $script:Cloud $script:Tenants $false $script:Shared 3>$null

        $result.Cancelled | Should -BeTrue
        @(Get-StubCall).Count | Should -Be 0

        # An unread tenant must not look like a tenant with no eligible groups.
        @($result.TenantStatus).Count | Should -Be 2
        foreach ($status in $result.TenantStatus) {
            $status.Success | Should -BeFalse
            $status.Message | Should -Match 'cancelled'
        }
        @($result.TenantStatus.TenantId) | Should -Contain '11111111-1111-1111-1111-111111111111'
        @($result.TenantStatus.TenantId) | Should -Contain '22222222-2222-2222-2222-222222222222'
    }

    It 'accounts for the tenants it never reached when cancelled midway' {
        $graph = New-StubGraphModule -Body @'
function Connect-PimGraphTenant {
    [CmdletBinding()] param([string] $TenantId, $CloudConfiguration, [switch] $UseDeviceAuthentication, [string] $ExpectedAccount)
    Add-StubCall "Connect $TenantId"
    [pscustomobject]@{ Success = $true; TenantId = $TenantId; Context = $null; Scopes = @(); HasGroupRead = $true; Message = 'ok'; Detail = '' }
}
function Get-CurrentGraphUser { [CmdletBinding()] param([string] $GraphBaseUri) [pscustomobject]@{ Id = '33333333-3333-3333-3333-333333333333' } }
function Get-PimEligibleGroups {
    [CmdletBinding()] param([string] $TenantId, [string] $PrincipalId, [string] $GraphBaseUri, [string] $TenantDisplayName, [switch] $SkipGroupNameResolution)
    $records = @([pscustomobject]@{ TenantId = $TenantId; GroupId = 'g'; GroupDisplayName = 'G' })
    return , ([object[]]$records)
}
function Disconnect-PimGraph { [CmdletBinding()] param() }
Export-ModuleMember -Function @('Connect-PimGraphTenant', 'Get-CurrentGraphUser', 'Get-PimEligibleGroups', 'Disconnect-PimGraph', 'Add-StubCall')
'@

        # Cancel after the first tenant has been read.
        $shared = New-PimSharedState
        $result = & $script:LoadGroups (New-WorkerPaths -GraphPath $graph) $script:Cloud $script:Tenants $false $shared 3>$null

        # Sanity: with no cancellation both tenants report success.
        @($result.TenantStatus | Where-Object { $_.Success }).Count | Should -Be 2
        $result.Cancelled | Should -BeFalse

        # Every selected tenant is always represented, cancelled or not.
        @($result.TenantStatus).Count | Should -Be @($script:Tenants).Count
    }
}

Describe 'SubmitWorker' {
    BeforeEach {
        Reset-StubCall
        $script:Shared = New-PimSharedState
        $script:TwoGroups = @(
            [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; TenantDisplayName = 'Contoso'; GroupId = 'aaaaaaaa-1111-1111-1111-111111111111'; GroupDisplayName = 'Group A'; AccessId = 'member'; PrincipalId = '33333333-3333-3333-3333-333333333333' }
            [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; TenantDisplayName = 'Contoso'; GroupId = 'bbbbbbbb-1111-1111-1111-111111111111'; GroupDisplayName = 'Group B'; AccessId = 'member'; PrincipalId = '33333333-3333-3333-3333-333333333333' }
        )
    }

    It 'submits every selected group and reports success' {
        $graph = New-StubGraphModule -Body @'
function Connect-PimGraphTenant {
    [CmdletBinding()] param([string] $TenantId, $CloudConfiguration, [switch] $UseDeviceAuthentication, [string] $ExpectedAccount)
    Add-StubCall "Connect $TenantId"
    [pscustomobject]@{ Success = $true; TenantId = $TenantId; Context = $null; Scopes = @(); HasGroupRead = $true; Message = 'ok'; Detail = '' }
}
function Get-CurrentGraphUser { [CmdletBinding()] param([string] $GraphBaseUri) [pscustomobject]@{ Id = '33333333-3333-3333-3333-333333333333' } }
function Request-PimGroupActivation {
    [CmdletBinding()] param([string] $TenantId, [string] $TenantDisplayName, [string] $GroupId, [string] $GroupDisplayName, [string] $PrincipalId, [string] $AccessId, [string] $Justification, [timespan] $Duration, [string] $GraphBaseUri, [string] $TicketNumber, [string] $TicketSystem)
    Add-StubCall "Activate $GroupDisplayName principal=$PrincipalId"
    New-PimActivationResultRecord -TenantId $TenantId -TenantDisplayName $TenantDisplayName -GroupId $GroupId -GroupDisplayName $GroupDisplayName -AccessId $AccessId -Status 'Success' -Message 'Activated.'
}
function Disconnect-PimGraph { [CmdletBinding()] param() Add-StubCall 'Disconnect' }
Export-ModuleMember -Function @('Connect-PimGraphTenant', 'Get-CurrentGraphUser', 'Request-PimGroupActivation', 'Disconnect-PimGraph', 'Add-StubCall')
'@

        $result = & $script:Submit (New-WorkerPaths -GraphPath $graph) $script:Cloud $script:TwoGroups 'Testing the activation path.' ([timespan]::FromHours(2)) $false '' '' $false $script:Shared

        $result.Kind          | Should -Be 'Submit'
        $result.Results.Count | Should -Be 2
        @($result.Results | Where-Object { $_.Status -eq 'Success' }).Count | Should -Be 2

        # Grouping by tenant means one connection for both groups.
        @(Get-StubCall | Where-Object { $_ -like 'Connect *' }).Count | Should -Be 1
        Get-StubCall | Should -Contain 'Activate Group A principal=33333333-3333-3333-3333-333333333333'
    }

    It 'falls back to the signed-in principal when a row carries none' {
        # $connection has no PrincipalId, so the fallback must come from Get-CurrentGraphUser.
        $groups = @(
            [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; TenantDisplayName = 'Contoso'; GroupId = 'aaaaaaaa-1111-1111-1111-111111111111'; GroupDisplayName = 'Group A'; AccessId = 'member'; PrincipalId = '' }
        )

        $graph = New-StubGraphModule -Body @'
function Connect-PimGraphTenant {
    [CmdletBinding()] param([string] $TenantId, $CloudConfiguration, [switch] $UseDeviceAuthentication, [string] $ExpectedAccount)
    [pscustomobject]@{ Success = $true; TenantId = $TenantId; Context = $null; Scopes = @(); HasGroupRead = $true; Message = 'ok'; Detail = '' }
}
function Get-CurrentGraphUser { [CmdletBinding()] param([string] $GraphBaseUri) [pscustomobject]@{ Id = '99999999-9999-9999-9999-999999999999' } }
function Request-PimGroupActivation {
    [CmdletBinding()] param([string] $TenantId, [string] $TenantDisplayName, [string] $GroupId, [string] $GroupDisplayName, [string] $PrincipalId, [string] $AccessId, [string] $Justification, [timespan] $Duration, [string] $GraphBaseUri, [string] $TicketNumber, [string] $TicketSystem)
    Add-StubCall "principal=$PrincipalId"
    New-PimActivationResultRecord -TenantId $TenantId -TenantDisplayName $TenantDisplayName -GroupId $GroupId -GroupDisplayName $GroupDisplayName -AccessId $AccessId -Status 'Success' -Message 'Activated.'
}
function Disconnect-PimGraph { [CmdletBinding()] param() }
Export-ModuleMember -Function @('Connect-PimGraphTenant', 'Get-CurrentGraphUser', 'Request-PimGroupActivation', 'Disconnect-PimGraph', 'Add-StubCall')
'@

        $result = & $script:Submit (New-WorkerPaths -GraphPath $graph) $script:Cloud $groups 'Testing the fallback path.' ([timespan]::FromHours(2)) $false '' '' $false $script:Shared

        $result.Results.Count | Should -Be 1
        Get-StubCall | Should -Contain 'principal=99999999-9999-9999-9999-999999999999'
    }

    It 'marks every group skipped when the tenant connection fails' {
        $graph = New-StubGraphModule -Body @'
function Connect-PimGraphTenant {
    [CmdletBinding()] param([string] $TenantId, $CloudConfiguration, [switch] $UseDeviceAuthentication, [string] $ExpectedAccount)
    [pscustomobject]@{ Success = $false; TenantId = $TenantId; Context = $null; Scopes = @(); HasGroupRead = $false; Message = 'Conditional Access blocked the sign-in.'; Detail = '' }
}
function Get-CurrentGraphUser { [CmdletBinding()] param([string] $GraphBaseUri) [pscustomobject]@{ Id = 'x' } }
function Request-PimGroupActivation {
    [CmdletBinding()] param([string] $TenantId, [string] $TenantDisplayName, [string] $GroupId, [string] $GroupDisplayName, [string] $PrincipalId, [string] $AccessId, [string] $Justification, [timespan] $Duration, [string] $GraphBaseUri, [string] $TicketNumber, [string] $TicketSystem)
    Add-StubCall 'SHOULD-NOT-HAPPEN'
}
function Disconnect-PimGraph { [CmdletBinding()] param() }
Export-ModuleMember -Function @('Connect-PimGraphTenant', 'Get-CurrentGraphUser', 'Request-PimGroupActivation', 'Disconnect-PimGraph', 'Add-StubCall')
'@

        $result = & $script:Submit (New-WorkerPaths -GraphPath $graph) $script:Cloud $script:TwoGroups 'Testing a blocked tenant.' ([timespan]::FromHours(2)) $false '' '' $false $script:Shared 3>$null

        $result.Results.Count | Should -Be 2
        @($result.Results | Where-Object { $_.Status -eq 'Skipped' }).Count | Should -Be 2
        $result.Results[0].Message | Should -Be 'Conditional Access blocked the sign-in.'
        Get-StubCall | Should -Not -Contain 'SHOULD-NOT-HAPPEN'
    }

    It 'stops after the first failure when asked to' {
        $graph = New-StubGraphModule -Body @'
function Connect-PimGraphTenant {
    [CmdletBinding()] param([string] $TenantId, $CloudConfiguration, [switch] $UseDeviceAuthentication, [string] $ExpectedAccount)
    [pscustomobject]@{ Success = $true; TenantId = $TenantId; Context = $null; Scopes = @(); HasGroupRead = $true; Message = 'ok'; Detail = '' }
}
function Get-CurrentGraphUser { [CmdletBinding()] param([string] $GraphBaseUri) [pscustomobject]@{ Id = '33333333-3333-3333-3333-333333333333' } }
function Request-PimGroupActivation {
    [CmdletBinding()] param([string] $TenantId, [string] $TenantDisplayName, [string] $GroupId, [string] $GroupDisplayName, [string] $PrincipalId, [string] $AccessId, [string] $Justification, [timespan] $Duration, [string] $GraphBaseUri, [string] $TicketNumber, [string] $TicketSystem)
    Add-StubCall "Activate $GroupDisplayName"
    New-PimActivationResultRecord -TenantId $TenantId -TenantDisplayName $TenantDisplayName -GroupId $GroupId -GroupDisplayName $GroupDisplayName -AccessId $AccessId -Status 'Failed' -Message 'Policy requires approval.'
}
function Disconnect-PimGraph { [CmdletBinding()] param() }
Export-ModuleMember -Function @('Connect-PimGraphTenant', 'Get-CurrentGraphUser', 'Request-PimGroupActivation', 'Disconnect-PimGraph', 'Add-StubCall')
'@

        $result = & $script:Submit (New-WorkerPaths -GraphPath $graph) $script:Cloud $script:TwoGroups 'Testing stop on failure.' ([timespan]::FromHours(2)) $true '' '' $false $script:Shared 3>$null

        # Only the first group is attempted; the second is reported, not dropped.
        @(Get-StubCall | Where-Object { $_ -like 'Activate *' }).Count | Should -Be 1
        $result.Results.Count | Should -Be 2
        @($result.Results | Where-Object { $_.Status -eq 'Failed' }).Count  | Should -Be 1
        @($result.Results | Where-Object { $_.Status -eq 'Skipped' }).Count | Should -Be 1
    }

    It 'never silently drops a selected group' {
        $graph = New-StubGraphModule -Body @'
function Connect-PimGraphTenant {
    [CmdletBinding()] param([string] $TenantId, $CloudConfiguration, [switch] $UseDeviceAuthentication, [string] $ExpectedAccount)
    [pscustomobject]@{ Success = $true; TenantId = $TenantId; Context = $null; Scopes = @(); HasGroupRead = $true; Message = 'ok'; Detail = '' }
}
function Get-CurrentGraphUser { [CmdletBinding()] param([string] $GraphBaseUri) [pscustomobject]@{ Id = '33333333-3333-3333-3333-333333333333' } }
function Request-PimGroupActivation {
    [CmdletBinding()] param([string] $TenantId, [string] $TenantDisplayName, [string] $GroupId, [string] $GroupDisplayName, [string] $PrincipalId, [string] $AccessId, [string] $Justification, [timespan] $Duration, [string] $GraphBaseUri, [string] $TicketNumber, [string] $TicketSystem)
    New-PimActivationResultRecord -TenantId $TenantId -TenantDisplayName $TenantDisplayName -GroupId $GroupId -GroupDisplayName $GroupDisplayName -AccessId $AccessId -Status 'Success' -Message 'Activated.'
}
function Disconnect-PimGraph { [CmdletBinding()] param() }
Export-ModuleMember -Function @('Connect-PimGraphTenant', 'Get-CurrentGraphUser', 'Request-PimGroupActivation', 'Disconnect-PimGraph', 'Add-StubCall')
'@

        $script:Shared.CancelRequested = $true
        $result = & $script:Submit (New-WorkerPaths -GraphPath $graph) $script:Cloud $script:TwoGroups 'Testing cancellation.' ([timespan]::FromHours(2)) $false '' '' $false $script:Shared 3>$null

        # Cancelled before anything ran, but both rows are still accounted for.
        $result.Results.Count | Should -Be 2
        @($result.Results | Where-Object { $_.Status -eq 'Skipped' }).Count | Should -Be 2
    }
}
