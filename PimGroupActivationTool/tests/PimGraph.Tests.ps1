#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:SrcPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'src'
    Import-Module (Join-Path $script:SrcPath 'PimModels.psm1') -Force
    Import-Module (Join-Path $script:SrcPath 'PimLogging.psm1') -Force
    Import-Module (Join-Path $script:SrcPath 'PimGraph.psm1') -Force

    # Keep unit tests off disk.
    Initialize-PimLog -Disable | Out-Null

    $script:CommercialCloud = Get-PimCloudConfiguration -Name 'Commercial'
    $script:DodCloud        = Get-PimCloudConfiguration -Name 'US Government DoD'
    $script:TenantId        = '11111111-1111-1111-1111-111111111111'
    $script:PrincipalId     = '3cce9d87-3986-4f19-8335-7ed075408ca2'
    $script:GroupId         = '14b9e371-5c2c-4ee5-a4a5-2980060d4f4e'
    $script:GroupId2        = 'd5f0ad2e-6b34-401b-b6da-0c8fc2c5a3fc'
}

AfterAll {
    Clear-PimCommandOverride
    Remove-Module PimGraph, PimLogging, PimModels -Force -ErrorAction SilentlyContinue
}

# Pester does not allow BeforeEach/AfterEach directly in the file root, so the whole
# suite lives inside a parent block that owns the per-test isolation.
Describe 'PimGraph' {

BeforeEach {
    Clear-PimCommandOverride
    Clear-PimGroupCache
}

Describe 'Invoke-PimExternalCommand' {
    It 'routes to a registered override' {
        Set-PimCommandOverride -Name 'Get-AzTenant' -Handler { param($p) 'overridden' }
        Invoke-PimExternalCommand -Name 'Get-AzTenant' | Should -Be 'overridden'
    }

    It 'passes parameters to the override' {
        Set-PimCommandOverride -Name 'Get-AzTenant' -Handler { param($p) $p['Marker'] }
        Invoke-PimExternalCommand -Name 'Get-AzTenant' -Parameters @{ Marker = 'value' } | Should -Be 'value'
    }

    It 'throws an actionable error for a missing command' {
        { Invoke-PimExternalCommand -Name 'Connect-NotARealCmdletAtAll' } | Should -Throw '*is not available*'
    }

    It 'removes an override when passed a null handler' {
        Set-PimCommandOverride -Name 'Get-AzTenant' -Handler { param($p) 'x' }
        Set-PimCommandOverride -Name 'Get-AzTenant' -Handler $null
        { Invoke-PimExternalCommand -Name 'Get-AzTenant' -Parameters @{ ErrorAction = 'Stop' } } | Should -Not -Throw '*is not available*'
    }
}

Describe 'Test-PimModuleAvailability' {
    It 'reports a module as available when the installed version meets the minimum' {
        $result = @(Test-PimModuleAvailability -RequiredModule @(
            [pscustomobject]@{ Name = 'Pester'; MinimumVersion = '1.0.0'; InstallName = 'Pester'; Purpose = 'tests' }
        ))
        $result[0].IsAvailable | Should -BeTrue
    }

    It 'reports a missing module as unavailable' {
        $result = @(Test-PimModuleAvailability -RequiredModule @(
            [pscustomobject]@{ Name = 'Definitely.Not.Installed.Module'; MinimumVersion = '1.0.0'; InstallName = 'x'; Purpose = 'y' }
        ))
        $result[0].IsAvailable      | Should -BeFalse
        $result[0].InstalledVersion | Should -BeNullOrEmpty
    }

    It 'reports an outdated module as unavailable' {
        $result = @(Test-PimModuleAvailability -RequiredModule @(
            [pscustomobject]@{ Name = 'Pester'; MinimumVersion = '99.0.0'; InstallName = 'Pester'; Purpose = 'tests' }
        ))
        $result[0].IsAvailable | Should -BeFalse
    }

    It 'declares both production prerequisites' {
        (Get-PimRequiredModule).Name | Should -Be @('Az.Accounts', 'Microsoft.Graph.Authentication')
    }
}

Describe 'Test-PimAzureContext' {
    It 'rejects a null context' {
        Test-PimAzureContext -Context $null -AzEnvironment 'AzureCloud' | Should -BeFalse
    }

    It 'rejects a context with no account' {
        $context = [pscustomobject]@{ Account = $null; Environment = [pscustomobject]@{ Name = 'AzureCloud' } }
        Test-PimAzureContext -Context $context -AzEnvironment 'AzureCloud' | Should -BeFalse
    }

    It 'rejects a context belonging to another cloud' {
        $context = [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'a@b.com' }; Environment = [pscustomobject]@{ Name = 'AzureCloud' } }
        Test-PimAzureContext -Context $context -AzEnvironment 'AzureUSGovernment' | Should -BeFalse
    }

    It 'rejects a context whose token no longer works' {
        Set-PimCommandOverride -Name 'Get-AzTenant' -Handler { param($p) throw 'Token expired' }
        $context = [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'a@b.com' }; Environment = [pscustomobject]@{ Name = 'AzureCloud' } }
        Test-PimAzureContext -Context $context -AzEnvironment 'AzureCloud' | Should -BeFalse
    }

    It 'rejects a context that returns no tenants' {
        Set-PimCommandOverride -Name 'Get-AzTenant' -Handler { param($p) @() }
        $context = [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'a@b.com' }; Environment = [pscustomobject]@{ Name = 'AzureCloud' } }
        Test-PimAzureContext -Context $context -AzEnvironment 'AzureCloud' | Should -BeFalse
    }

    It 'accepts a validated context' {
        Set-PimCommandOverride -Name 'Get-AzTenant' -Handler { param($p) @([pscustomobject]@{ TenantId = $script:TenantId }) }
        $context = [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'a@b.com' }; Environment = [pscustomobject]@{ Name = 'AzureCloud' } }
        Test-PimAzureContext -Context $context -AzEnvironment 'AzureCloud' | Should -BeTrue
    }

    It 'accepts an environment supplied as a plain string' {
        Set-PimCommandOverride -Name 'Get-AzTenant' -Handler { param($p) @([pscustomobject]@{ TenantId = $script:TenantId }) }
        $context = [pscustomobject]@{ Account = 'a@b.com'; Environment = 'AzureCloud' }
        Test-PimAzureContext -Context $context -AzEnvironment 'AzureCloud' | Should -BeTrue
    }
}

Describe 'Connect-PimAzureAccount' {
    BeforeEach {
        $script:ConnectCalls = 0
    }

    It 'reuses a valid existing context without signing in again' {
        Set-PimCommandOverride -Name 'Get-AzContext' -Handler { param($p)
            [pscustomobject]@{
                Account     = [pscustomobject]@{ Id = 'user@contoso.com' }
                Environment = [pscustomobject]@{ Name = 'AzureCloud' }
                Tenant      = [pscustomobject]@{ Id = '11111111-1111-1111-1111-111111111111' }
            }
        }
        Set-PimCommandOverride -Name 'Get-AzTenant' -Handler { param($p) @([pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111' }) }
        Set-PimCommandOverride -Name 'Connect-AzAccount' -Handler { param($p) throw 'Connect-AzAccount must not be called' }

        $result = Connect-PimAzureAccount -CloudConfiguration $script:CommercialCloud
        $result.ReusedContext | Should -BeTrue
        $result.Account       | Should -Be 'user@contoso.com'
        $result.Environment   | Should -Be 'AzureCloud'
    }

    It 'signs in when there is no context' {
        $signedIn = $false
        Set-PimCommandOverride -Name 'Get-AzContext' -Handler { param($p)
            if ($script:SignedIn) {
                return [pscustomobject]@{
                    Account     = [pscustomobject]@{ Id = 'user@contoso.com' }
                    Environment = [pscustomobject]@{ Name = 'AzureCloud' }
                    Tenant      = [pscustomobject]@{ Id = '11111111-1111-1111-1111-111111111111' }
                }
            }
            return $null
        }
        Set-PimCommandOverride -Name 'Connect-AzAccount' -Handler { param($p)
            $script:SignedIn = $true
            $script:ConnectParameters = $p
            return [pscustomobject]@{}
        }
        Set-PimCommandOverride -Name 'Get-AzTenant' -Handler { param($p) @([pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111' }) }

        $script:SignedIn = $false
        $result = Connect-PimAzureAccount -CloudConfiguration $script:CommercialCloud

        $result.ReusedContext | Should -BeFalse
        $result.Account       | Should -Be 'user@contoso.com'
    }

    It 'signs in with the requested environment and process scope' {
        Set-PimCommandOverride -Name 'Get-AzContext' -Handler { param($p)
            if ($script:SignedIn) {
                return [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'u' }; Environment = [pscustomobject]@{ Name = 'AzureUSGovernment' }; Tenant = [pscustomobject]@{ Id = 't' } }
            }
            return $null
        }
        Set-PimCommandOverride -Name 'Connect-AzAccount' -Handler { param($p)
            $script:SignedIn = $true
            $script:ConnectParameters = $p
        }
        Set-PimCommandOverride -Name 'Get-AzTenant' -Handler { param($p) @([pscustomobject]@{ TenantId = 't' }) }

        $script:SignedIn = $false
        Connect-PimAzureAccount -CloudConfiguration $script:DodCloud | Out-Null

        $script:ConnectParameters['Environment'] | Should -Be 'AzureUSGovernment'
        $script:ConnectParameters['Scope']       | Should -Be 'Process'
    }

    It 'signs in again when a context belongs to a different cloud' {
        Set-PimCommandOverride -Name 'Get-AzContext' -Handler { param($p)
            if ($script:SignedIn) {
                return [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'u' }; Environment = [pscustomobject]@{ Name = 'AzureUSGovernment' }; Tenant = [pscustomobject]@{ Id = 't' } }
            }
            return [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'u' }; Environment = [pscustomobject]@{ Name = 'AzureCloud' }; Tenant = [pscustomobject]@{ Id = 't' } }
        }
        Set-PimCommandOverride -Name 'Connect-AzAccount' -Handler { param($p) $script:SignedIn = $true }
        Set-PimCommandOverride -Name 'Get-AzTenant' -Handler { param($p) @([pscustomobject]@{ TenantId = 't' }) }

        $script:SignedIn = $false
        (Connect-PimAzureAccount -CloudConfiguration $script:DodCloud).ReusedContext | Should -BeFalse
        $script:SignedIn | Should -BeTrue
    }

    It 'forces a new sign-in when -Force is used' {
        Set-PimCommandOverride -Name 'Get-AzContext' -Handler { param($p)
            [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'u' }; Environment = [pscustomobject]@{ Name = 'AzureCloud' }; Tenant = [pscustomobject]@{ Id = 't' } }
        }
        Set-PimCommandOverride -Name 'Connect-AzAccount' -Handler { param($p) $script:SignedIn = $true }
        Set-PimCommandOverride -Name 'Get-AzTenant' -Handler { param($p) @([pscustomobject]@{ TenantId = 't' }) }

        $script:SignedIn = $false
        Connect-PimAzureAccount -CloudConfiguration $script:CommercialCloud -Force | Out-Null
        $script:SignedIn | Should -BeTrue
    }

    It 'surfaces a friendly message when sign-in is cancelled' {
        Set-PimCommandOverride -Name 'Get-AzContext' -Handler { param($p) $null }
        Set-PimCommandOverride -Name 'Connect-AzAccount' -Handler { param($p) throw 'User canceled authentication: AuthenticationCanceled' }

        { Connect-PimAzureAccount -CloudConfiguration $script:CommercialCloud } | Should -Throw '*cancelled*'
    }

    It 'throws when sign-in produces no context' {
        Set-PimCommandOverride -Name 'Get-AzContext' -Handler { param($p) $null }
        Set-PimCommandOverride -Name 'Connect-AzAccount' -Handler { param($p) }

        { Connect-PimAzureAccount -CloudConfiguration $script:CommercialCloud } | Should -Throw '*did not produce a usable context*'
    }

    It 'refuses to sign in to an unsupported custom cloud' {
        $unsupported = [pscustomobject]@{
            DisplayName = 'Custom: Contoso'; AzEnvironment = 'Contoso'; GraphEnvironment = $null
            GraphBaseUri = $null; IsBuiltIn = $false; IsSupported = $false
            UnsupportedReason = 'No Microsoft Graph PowerShell environment is registered.'
        }
        { Connect-PimAzureAccount -CloudConfiguration $unsupported } | Should -Throw '*No Microsoft Graph PowerShell environment is registered*'
    }
}

Describe 'Get-PimAuthorizedTenant' {
    It 'normalizes and sorts discovered tenants' {
        Set-PimCommandOverride -Name 'Get-AzTenant' -Handler { param($p)
            @(
                [pscustomobject]@{ TenantId = '22222222-2222-2222-2222-222222222222'; Name = 'Zulu';  Domains = @('zulu.com');  TenantCategory = 'ManagedBy' }
                [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; Name = 'Alpha'; Domains = @('alpha.com'); TenantCategory = 'Home' }
            )
        }

        $tenants = Get-PimAuthorizedTenant -CloudConfiguration $script:CommercialCloud
        $tenants.Count               | Should -Be 2
        $tenants[0].TenantDisplayName | Should -Be 'Alpha'
        $tenants[0].Cloud             | Should -Be 'Commercial'
        $tenants[0].Selected          | Should -BeFalse
    }

    It 'returns an empty array rather than null when there are no tenants' {
        Set-PimCommandOverride -Name 'Get-AzTenant' -Handler { param($p) @() }
        $tenants = Get-PimAuthorizedTenant -CloudConfiguration $script:CommercialCloud
        # Piping an empty array into Should sends nothing, so assert on the value itself.
        ($tenants -is [array]) | Should -BeTrue -Because 'an empty array is still a non-null object'
        $tenants.Count | Should -Be 0
    }

    It 'skips an unreadable tenant entry but keeps the rest' {
        Set-PimCommandOverride -Name 'Get-AzTenant' -Handler { param($p)
            @(
                [pscustomobject]@{ Name = 'Broken, no id' }
                [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; Name = 'Good' }
            )
        }
        $tenants = Get-PimAuthorizedTenant
        $tenants.Count                | Should -Be 1
        $tenants[0].TenantDisplayName | Should -Be 'Good'
    }

    It 'raises a friendly error when tenant discovery fails' {
        Set-PimCommandOverride -Name 'Get-AzTenant' -Handler { param($p) throw 'Response status code does not indicate success: 403 (Forbidden)' }
        { Get-PimAuthorizedTenant } | Should -Throw '*Could not list authorized tenants*'
    }
}

Describe 'Test-PimGraphContext' {
    BeforeAll {
        $script:GoodContext = [pscustomobject]@{
            TenantId    = '11111111-1111-1111-1111-111111111111'
            Environment = 'Global'
            Account     = 'ada@contoso.com'
            Scopes      = @('PrivilegedEligibilitySchedule.Read.AzureADGroup', 'PrivilegedAssignmentSchedule.ReadWrite.AzureADGroup', 'User.Read')
        }
    }

    It 'rejects a null context' {
        Test-PimGraphContext -Context $null -TenantId $script:TenantId -GraphEnvironment 'Global' | Should -BeFalse
    }

    It 'rejects a context for a different tenant' {
        Test-PimGraphContext -Context $script:GoodContext -TenantId '99999999-9999-9999-9999-999999999999' -GraphEnvironment 'Global' | Should -BeFalse
    }

    It 'rejects a context for a different Graph environment' {
        Test-PimGraphContext -Context $script:GoodContext -TenantId $script:TenantId -GraphEnvironment 'USGovDoD' | Should -BeFalse
    }

    It 'rejects a context missing a required scope' {
        Test-PimGraphContext -Context $script:GoodContext -TenantId $script:TenantId -GraphEnvironment 'Global' -RequiredScopes @('Group.Read.All') | Should -BeFalse
    }

    It 'accepts a matching context' {
        Test-PimGraphContext -Context $script:GoodContext -TenantId $script:TenantId -GraphEnvironment 'Global' -RequiredScopes (Get-PimMinimumGraphScope) | Should -BeTrue
    }

    It 'matches the tenant ID case-insensitively' {
        $context = [pscustomobject]@{ TenantId = 'AAAAAAAA-1111-1111-1111-111111111111'; Environment = 'Global'; Scopes = @() }
        Test-PimGraphContext -Context $context -TenantId 'aaaaaaaa-1111-1111-1111-111111111111' -GraphEnvironment 'global' | Should -BeTrue
    }

    It 'says nothing about which account the context belongs to' -ForEach @(
        @{ Case = 'a different account'; Account = 'bob@contoso.com' }
        @{ Case = 'no account at all';   Account = '' }
    ) {
        # The account gate deliberately lives in Connect-PimGraphTenant, which can
        # call Graph to establish the principal when the context does not name one.
        $context = [pscustomobject]@{
            TenantId    = $script:TenantId
            Environment = 'Global'
            Account     = $Account
            Scopes      = @()
        }
        Test-PimGraphContext -Context $context -TenantId $script:TenantId -GraphEnvironment 'Global' | Should -BeTrue
    }
}

Describe 'Resolve-PimContextAccount' {
    AfterEach { Clear-PimCommandOverride }

    It 'gathers every name Graph knows the session by' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            @{
                id                = '22222222-2222-2222-2222-222222222222'
                userPrincipalName = 'ada.lovelace_contoso.com#EXT#@fabrikam.onmicrosoft.com'
                displayName       = 'Ada'
                mail              = 'ada.lovelace@contoso.com'
                otherMails        = @('e123456@corp.contoso.com')
            }
        }
        $context = [pscustomobject]@{ Account = 'ada@contoso.com' }

        $names = @(Resolve-PimContextAccount -Context $context -GraphBaseUri 'https://graph.microsoft.com')

        $names | Should -Contain 'ada@contoso.com'
        $names | Should -Contain 'ada.lovelace_contoso.com#EXT#@fabrikam.onmicrosoft.com'
        $names | Should -Contain 'ada.lovelace@contoso.com'
        $names | Should -Contain 'e123456@corp.contoso.com'
    }

    It 'asks Graph who it is when the context has no account' {
        # Connect-MgGraph -AccessToken populates Scopes but leaves Account blank.
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            @{ id = '22222222-2222-2222-2222-222222222222'; userPrincipalName = 'ada_contoso.com#EXT#@fabrikam.onmicrosoft.com'; displayName = 'Ada' }
        }
        $context = [pscustomobject]@{ Account = '' }

        @(Resolve-PimContextAccount -Context $context -GraphBaseUri 'https://graph.microsoft.com') |
            Should -Contain 'ada_contoso.com#EXT#@fabrikam.onmicrosoft.com'
    }

    It 'keeps the context account when the directory read is denied' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) throw 'Forbidden' }
        $context = [pscustomobject]@{ Account = 'ada@contoso.com' }

        @(Resolve-PimContextAccount -Context $context -GraphBaseUri 'https://graph.microsoft.com') |
            Should -Be @('ada@contoso.com')
    }

    It 'returns nothing when the principal cannot be established at all' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) throw 'Forbidden' }
        $context = [pscustomobject]@{ Account = '' }

        @(Resolve-PimContextAccount -Context $context -GraphBaseUri 'https://graph.microsoft.com').Count | Should -Be 0
    }

    It 'returns nothing for a null context when Graph is unreachable' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) throw 'Forbidden' }
        @(Resolve-PimContextAccount -Context $null -GraphBaseUri 'https://graph.microsoft.com').Count | Should -Be 0
    }
}

Describe 'Test-PimGraphIdentity' {
    AfterEach { Clear-PimCommandOverride }

    It 'does not call Graph when the context account already matches' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) throw 'Graph should not be called.' }
        $context = [pscustomobject]@{ Account = 'ada_contoso.com#EXT#@fabrikam.onmicrosoft.com' }

        $identity = Test-PimGraphIdentity -Context $context -ExpectedAccount 'ada@contoso.com' -GraphBaseUri 'https://graph.microsoft.com'

        $identity.Matched    | Should -BeTrue
        $identity.Identified | Should -BeTrue
    }

    It 'does not call Graph when no account is expected' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) throw 'Graph should not be called.' }
        $context = [pscustomobject]@{ Account = '' }

        (Test-PimGraphIdentity -Context $context -ExpectedAccount '' -GraphBaseUri 'https://graph.microsoft.com').Matched |
            Should -BeTrue
    }

    It 'widens the search only when the context account does not match' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            @{ id = '2'; userPrincipalName = 'ada.lovelace_contoso.com#EXT#@fabrikam.onmicrosoft.com'; mail = 'ada.lovelace@contoso.com'; otherMails = @('e123456@corp.contoso.com') }
        }
        $context = [pscustomobject]@{ Account = 'ada.lovelace_contoso.com#EXT#@fabrikam.onmicrosoft.com' }

        (Test-PimGraphIdentity -Context $context -ExpectedAccount 'e123456@corp.contoso.com' -GraphBaseUri 'https://graph.microsoft.com').Matched |
            Should -BeTrue
    }

    It 'reports an unidentified session rather than a mismatched one' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) throw 'Forbidden' }
        $context = [pscustomobject]@{ Account = '' }

        $identity = Test-PimGraphIdentity -Context $context -ExpectedAccount 'ada@contoso.com' -GraphBaseUri 'https://graph.microsoft.com'

        $identity.Identified | Should -BeFalse
        $identity.Matched    | Should -BeFalse
    }

    It 'reports a genuine mismatch with the name to show the user' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            @{ id = '2'; userPrincipalName = 'mallory@contoso.com' }
        }
        $context = [pscustomobject]@{ Account = 'mallory@contoso.com' }

        $identity = Test-PimGraphIdentity -Context $context -ExpectedAccount 'ada@contoso.com' -GraphBaseUri 'https://graph.microsoft.com'

        $identity.Matched    | Should -BeFalse
        $identity.Identified | Should -BeTrue
        $identity.Account    | Should -Be 'mallory@contoso.com'
    }
}

Describe 'ConvertTo-PimResourceScope' {
    It 'qualifies bare scope names with the Graph resource' {
        $scopes = ConvertTo-PimResourceScope -Scope @('Group.Read.All') -GraphBaseUri 'https://graph.microsoft.com'
        $scopes[0] | Should -Be 'https://graph.microsoft.com/Group.Read.All'
    }

    It 'uses the cloud it was given rather than a hard-coded host' {
        $scopes = ConvertTo-PimResourceScope -Scope @('User.Read') -GraphBaseUri 'https://dod-graph.microsoft.us'
        $scopes[0] | Should -Be 'https://dod-graph.microsoft.us/User.Read'
    }

    It 'leaves OpenID scopes alone' {
        # These address the identity service, not a resource, and qualifying them
        # makes the whole request invalid.
        $scopes = ConvertTo-PimResourceScope -Scope @('offline_access', 'openid') -GraphBaseUri 'https://graph.microsoft.com'
        $scopes | Should -Be @('offline_access', 'openid')
    }

    It 'leaves an already qualified scope alone' {
        $scopes = ConvertTo-PimResourceScope -Scope @('https://graph.microsoft.com/User.Read') -GraphBaseUri 'https://graph.microsoft.com'
        $scopes[0] | Should -Be 'https://graph.microsoft.com/User.Read'
    }
}

Describe 'Read-PimOAuthError' {
    It 'reads the error code out of the response body' {
        $failure = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new('Bad Request'), 'OAuthError', 'ProtocolError', $null)
        $failure.ErrorDetails = [System.Management.Automation.ErrorDetails]::new(
            '{"error":"authorization_pending","error_description":"still waiting"}')

        $oauth = Read-PimOAuthError -ErrorObject $failure

        $oauth.Code        | Should -Be 'authorization_pending'
        $oauth.Description | Should -Be 'still waiting'
    }

    It 'reports no code when the request never reached the identity service' {
        # A connection failure carries no OAuth body, and the caller has to tell
        # that apart from a rejection so it keeps polling instead of giving up.
        $failure = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new('No such host is known'), 'NameResolution', 'ConnectionError', $null)

        $oauth = Read-PimOAuthError -ErrorObject $failure

        $oauth.Code | Should -BeNullOrEmpty
    }

    It 'survives a body that is not JSON' {
        $failure = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new('Gateway Timeout'), 'Proxy', 'ProtocolError', $null)
        $failure.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('<html>proxy error</html>')

        { Read-PimOAuthError -ErrorObject $failure } | Should -Not -Throw
    }
}

Describe 'Request-PimDeviceCode' {
    It 'rejects a tenant id that is not a GUID' {
        # The value lands in a URL, so it is validated before being sent anywhere.
        { Request-PimDeviceCode -TenantId 'contoso.com/../evil' -LoginBaseUri 'https://login.microsoftonline.com' `
            -GraphBaseUri 'https://graph.microsoft.com' -Scope @('User.Read') } | Should -Throw
    }

    It 'fails loudly when no code comes back' {
        Set-PimCommandOverride -Name 'Invoke-RestMethod' -Handler { param($p) [pscustomobject]@{ error = 'invalid_client' } }

        { Request-PimDeviceCode -TenantId '11111111-1111-1111-1111-111111111111' `
            -LoginBaseUri 'https://login.microsoftonline.com' -GraphBaseUri 'https://graph.microsoft.com' `
            -Scope @('User.Read') } | Should -Throw '*did not return a device code*'
    }

    It 'never polls faster than the service allows' {
        Set-PimCommandOverride -Name 'Invoke-RestMethod' -Handler { param($p)
            [pscustomobject]@{ device_code = 'd'; user_code = 'u'; verification_uri = 'https://example.com'; expires_in = 900; interval = 1 }
        }

        $code = Request-PimDeviceCode -TenantId '11111111-1111-1111-1111-111111111111' `
            -LoginBaseUri 'https://login.microsoftonline.com' -GraphBaseUri 'https://graph.microsoft.com' -Scope @('User.Read')

        $code.IntervalSeconds | Should -BeGreaterOrEqual 5
    }
}

Describe 'Wait-PimDeviceCodeToken' {
    It 'backs off when the service says to slow down' {
        $script:Slept = @()
        $script:Attempt = 0
        Set-PimCommandOverride -Name 'Start-Sleep' -Handler { param($p) $script:Slept += $p['Seconds'] }
        Set-PimCommandOverride -Name 'Invoke-RestMethod' -Handler { param($p)
            $script:Attempt++
            if ($script:Attempt -eq 1) {
                $failure = [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new('Bad Request'), 'OAuthError', 'ProtocolError', $null)
                $failure.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"error":"slow_down"}')
                throw $failure
            }
            [pscustomobject]@{ access_token = 'token-value' }
        }

        $code = [pscustomobject]@{ DeviceCode = 'd'; IntervalSeconds = 5; ExpiresInSeconds = 900 }
        $token = Wait-PimDeviceCodeToken -DeviceCode $code -TenantId '11111111-1111-1111-1111-111111111111' `
            -LoginBaseUri 'https://login.microsoftonline.com'

        $token | Should -Be 'token-value'
        $script:Slept[1] | Should -BeGreaterThan $script:Slept[0]
    }

    It 'keeps polling through a network blip rather than discarding the code' {
        # The user may be part way through signing in; a dropped connection is no
        # reason to make them start over with a fresh code.
        $script:Attempt = 0
        Set-PimCommandOverride -Name 'Start-Sleep' -Handler { param($p) }
        Set-PimCommandOverride -Name 'Invoke-RestMethod' -Handler { param($p)
            $script:Attempt++
            if ($script:Attempt -lt 3) { throw 'The remote name could not be resolved' }
            [pscustomobject]@{ access_token = 'token-value' }
        }

        $code = [pscustomobject]@{ DeviceCode = 'd'; IntervalSeconds = 5; ExpiresInSeconds = 900 }
        $token = Wait-PimDeviceCodeToken -DeviceCode $code -TenantId '11111111-1111-1111-1111-111111111111' `
            -LoginBaseUri 'https://login.microsoftonline.com'

        $token | Should -Be 'token-value'
        $script:Attempt | Should -Be 3
    }

    It 'stops polling once the network has clearly gone' {
        Set-PimCommandOverride -Name 'Start-Sleep' -Handler { param($p) }
        Set-PimCommandOverride -Name 'Invoke-RestMethod' -Handler { param($p) throw 'The remote name could not be resolved' }

        $code = [pscustomobject]@{ DeviceCode = 'd'; IntervalSeconds = 5; ExpiresInSeconds = 900 }

        { Wait-PimDeviceCodeToken -DeviceCode $code -TenantId '11111111-1111-1111-1111-111111111111' `
            -LoginBaseUri 'https://login.microsoftonline.com' } | Should -Throw '*consecutive network errors*'
    }

    It 'gives up when the user declines' {
        Set-PimCommandOverride -Name 'Start-Sleep' -Handler { param($p) }
        Set-PimCommandOverride -Name 'Invoke-RestMethod' -Handler { param($p)
            $failure = [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new('Bad Request'), 'OAuthError', 'ProtocolError', $null)
            $failure.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"error":"authorization_declined"}')
            throw $failure
        }

        $code = [pscustomobject]@{ DeviceCode = 'd'; IntervalSeconds = 5; ExpiresInSeconds = 900 }

        { Wait-PimDeviceCodeToken -DeviceCode $code -TenantId '11111111-1111-1111-1111-111111111111' `
            -LoginBaseUri 'https://login.microsoftonline.com' } | Should -Throw '*declined*'
    }

    It 'gives up immediately when the service returns no token' {
        # A reply the service accepted but that carries no token is not a transport
        # problem, so it must not be retried like one.
        $script:Attempts = 0
        Set-PimCommandOverride -Name 'Start-Sleep' -Handler { param($p) }
        Set-PimCommandOverride -Name 'Invoke-RestMethod' -Handler { param($p)
            $script:Attempts++
            [pscustomobject]@{ token_type = 'Bearer' }
        }

        $code = [pscustomobject]@{ DeviceCode = 'd'; IntervalSeconds = 5; ExpiresInSeconds = 900 }

        { Wait-PimDeviceCodeToken -DeviceCode $code -TenantId '11111111-1111-1111-1111-111111111111' `
            -LoginBaseUri 'https://login.microsoftonline.com' } | Should -Throw '*returned no access token*'

        $script:Attempts | Should -Be 1 -Because 'a missing token is not worth twenty retries'
    }

    It 'never polls after the caller''s deadline has passed' {
        # The sleep deliberately overruns the one second budget, so the only way to
        # avoid a late poll is to recheck the deadline after waiting.
        $script:Attempts = 0
        Set-PimCommandOverride -Name 'Start-Sleep' -Handler { param($p) [System.Threading.Thread]::Sleep(1200) }
        Set-PimCommandOverride -Name 'Invoke-RestMethod' -Handler { param($p)
            $script:Attempts++
            [pscustomobject]@{ access_token = 'late-token' }
        }

        $code = [pscustomobject]@{ DeviceCode = 'd'; IntervalSeconds = 5; ExpiresInSeconds = 900 }

        { Wait-PimDeviceCodeToken -DeviceCode $code -TenantId '11111111-1111-1111-1111-111111111111' `
            -LoginBaseUri 'https://login.microsoftonline.com' -TimeoutSeconds 1 } | Should -Throw '*No sign-in completed*'

        $script:Attempts | Should -Be 0 -Because 'the wait consumed the whole budget, so there was no time left to poll'
    }

    It 'stops waiting once the caller''s budget runs out' {
        Set-PimCommandOverride -Name 'Start-Sleep' -Handler { param($p) }

        $code = [pscustomobject]@{ DeviceCode = 'd'; IntervalSeconds = 5; ExpiresInSeconds = 0 }

        { Wait-PimDeviceCodeToken -DeviceCode $code -TenantId '11111111-1111-1111-1111-111111111111' `
            -LoginBaseUri 'https://login.microsoftonline.com' -TimeoutSeconds 0 } | Should -Throw '*No sign-in completed*'
    }
}

Describe 'Connect-PimGraphTenant' {
    BeforeAll {
        # The tool runs the device code flow itself, so these fakes stand in for the
        # identity service rather than for the SDK's own device code support.
        function Set-PimFakeDeviceCodeFlow {
            param(
                [string[]] $PollResponses = @('granted'),
                [string]   $UserCode = 'ABC123XYZ'
            )

            $script:RestCalls = @()
            $script:PollIndex = 0
            $script:SleepSeconds = @()
            # Handlers run long after this function returns, and PowerShell
            # scriptblocks are not closures, so everything they read has to live
            # in script scope rather than in these parameters.
            $script:FakePollResponses = $PollResponses
            $script:FakeUserCode = $UserCode

            Set-PimCommandOverride -Name 'Start-Sleep' -Handler { param($p) $script:SleepSeconds += $p['Seconds'] }
            Set-PimCommandOverride -Name 'Invoke-RestMethod' -Handler { param($p)
                $script:RestCalls += , $p

                if ($p['Uri'] -like '*/devicecode') {
                    return [pscustomobject]@{
                        device_code      = 'device-code-value'
                        user_code        = $script:FakeUserCode
                        verification_uri = 'https://microsoft.com/devicelogin'
                        expires_in       = 900
                        interval         = 5
                    }
                }

                $outcome = $script:FakePollResponses[[Math]::Min($script:PollIndex, $script:FakePollResponses.Count - 1)]
                $script:PollIndex++

                if ($outcome -eq 'granted') {
                    return [pscustomobject]@{ access_token = 'token-value'; expires_in = 3600 }
                }

                # The identity service signals everything else through an error body.
                $failure = [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new('Bad Request'), 'OAuthError', 'ProtocolError', $null)
                $failure.ErrorDetails = [System.Management.Automation.ErrorDetails]::new(
                    (@{ error = $outcome; error_description = "simulated $outcome" } | ConvertTo-Json -Compress))
                throw $failure
            }
        }
    }

    It 'falls back to a device code when the broker will not show a prompt' {
        # Observed live: the WAM broker can fail to prompt and Connect-MgGraph
        # returns without raising anything, leaving Get-MgContext null. A device
        # code needs no window, so retrying with one gets the user signed in
        # instead of making them discover the workaround and start over.
        $script:ConnectCalls = @()
        Set-PimFakeDeviceCodeFlow
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p) $script:ConnectCalls += , $p }
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p)
            if ($script:ConnectCalls.Count -lt 2) { return $null }
            [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; Environment = 'Global'; Account = 'ada@contoso.com'; Scopes = (Get-PimMinimumGraphScope) }
        }

        $result = Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $script:CommercialCloud -Force

        $result.Success | Should -BeTrue
        $script:ConnectCalls.Count | Should -Be 2
        $script:ConnectCalls[0].ContainsKey('AccessToken') | Should -BeFalse -Because 'the broker is tried first'
        $script:ConnectCalls[1].ContainsKey('AccessToken') | Should -BeTrue -Because 'the fallback signs in with the token we obtained'
    }

    It 'shows the user the code it is waiting on' {
        # The whole point of owning the flow: the SDK prints the code through the
        # PowerShell host, which a worker runspace does not have, so the window
        # could never display it. A warning reaches a console and the window alike.
        Set-PimFakeDeviceCodeFlow -UserCode 'QRST12345'
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p) }
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p)
            [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; Environment = 'Global'; Account = 'ada@contoso.com'; Scopes = (Get-PimMinimumGraphScope) }
        }

        $null = Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $script:CommercialCloud `
            -Force -UseDeviceAuthentication -WarningVariable warnings -WarningAction SilentlyContinue

        ($warnings -join ' ') | Should -Match 'QRST12345'
        ($warnings -join ' ') | Should -Match 'devicelogin'
    }

    It 'asks the identity service for the scopes it actually needs' {
        Set-PimFakeDeviceCodeFlow
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p) }
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p)
            [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; Environment = 'Global'; Account = 'ada@contoso.com'; Scopes = (Get-PimMinimumGraphScope) }
        }

        $null = Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $script:CommercialCloud `
            -Force -UseDeviceAuthentication -WarningAction SilentlyContinue

        $request = @($script:RestCalls | Where-Object { $_['Uri'] -like '*/devicecode' })[0]
        $request['Uri'] | Should -Be "https://login.microsoftonline.com/$($script:TenantId)/oauth2/v2.0/devicecode"
        # The token endpoint has no default resource, so bare scope names would be rejected.
        $request['Body']['scope'] | Should -Match 'https://graph\.microsoft\.com/PrivilegedAssignmentSchedule\.ReadWrite\.AzureADGroup'
    }

    It 'goes straight to a device code when one was asked for' {
        $script:ConnectCalls = @()
        Set-PimFakeDeviceCodeFlow
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p) $script:ConnectCalls += , $p }
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p)
            [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; Environment = 'Global'; Account = 'ada@contoso.com'; Scopes = (Get-PimMinimumGraphScope) }
        }

        $null = Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $script:CommercialCloud `
            -Force -UseDeviceAuthentication -WarningAction SilentlyContinue

        $script:ConnectCalls.Count | Should -Be 1 -Because 'the broker is known to be unusable'
        $script:ConnectCalls[0].ContainsKey('AccessToken') | Should -BeTrue
    }

    It 'keeps waiting while the user is still entering the code' {
        Set-PimFakeDeviceCodeFlow -PollResponses @('authorization_pending', 'authorization_pending', 'granted')
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p) }
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p)
            [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; Environment = 'Global'; Account = 'ada@contoso.com'; Scopes = (Get-PimMinimumGraphScope) }
        }

        $result = Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $script:CommercialCloud `
            -Force -UseDeviceAuthentication -WarningAction SilentlyContinue

        $result.Success | Should -BeTrue
        @($script:RestCalls | Where-Object { $_['Uri'] -like '*/token' }).Count | Should -Be 3
    }

    It 'gives up when the code lapses before anyone uses it' {
        Set-PimFakeDeviceCodeFlow -PollResponses @('expired_token')
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p) }
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p) $null }

        $result = Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $script:CommercialCloud `
            -Force -UseDeviceAuthentication -WarningAction SilentlyContinue

        $result.Success | Should -BeFalse
        $result.Detail  | Should -Match 'expired'
    }

    It 'says so when no sign-in endpoint is known for the cloud' {
        Set-PimFakeDeviceCodeFlow
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p) }
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p) $null }

        $cloud = [pscustomobject]@{
            DisplayName = 'Custom: Nowhere'; GraphEnvironment = 'Global'
            GraphBaseUri = 'https://graph.microsoft.com'; LoginBaseUri = $null
        }

        $result = Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $cloud -Force

        $result.Success | Should -BeFalse
        $result.Detail  | Should -Match 'no sign-in endpoint is known'
        @($script:RestCalls).Count | Should -Be 0 -Because 'there is nowhere to send a device code request'
    }

    It 'sends only parameters Connect-MgGraph accepts alongside an access token' {
        # AccessToken lives in its own parameter set. ContextScope looks harmless
        # next to it but is not in that set, and passing it fails binding before a
        # single request goes out - which unit tests with a faked Connect-MgGraph
        # would never notice.
        $script:ConnectCalls = @()
        Set-PimFakeDeviceCodeFlow
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p) $script:ConnectCalls += , $p }
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p)
            [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; Environment = 'Global'; Account = 'ada@contoso.com'; Scopes = (Get-PimMinimumGraphScope) }
        }

        $null = Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $script:CommercialCloud `
            -Force -UseDeviceAuthentication -WarningAction SilentlyContinue

        $real = Get-Command -Name 'Connect-MgGraph' -ErrorAction SilentlyContinue
        if (-not $real) {
            Set-ItResult -Skipped -Because 'Microsoft.Graph.Authentication is not installed here'
            return
        }

        $accessTokenSet = @($real.ParameterSets | Where-Object { $_.Parameters.Name -contains 'AccessToken' })
        $accessTokenSet.Count | Should -BeGreaterThan 0

        $allowed = $accessTokenSet[0].Parameters.Name
        foreach ($name in $script:ConnectCalls[0].Keys) {
            $allowed | Should -Contain $name -Because "Connect-MgGraph rejects '$name' when an access token is supplied"
        }
    }

    It 'reports an actionable error when the broker leaves no context' {
        Set-PimFakeDeviceCodeFlow
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p) }
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p) $null }
        Set-PimCommandOverride -Name 'Get-Module' -Handler { param($p) [pscustomobject]@{ Version = [version]'2.25.0' } }

        $result = Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $script:CommercialCloud -Force

        $result.Success | Should -BeFalse
        $result.Detail  | Should -Match 'left no sign-in context'
    }

    It 'warns but does not lock out when the names cannot be reconciled' {
        # A guest UPN is minted from the invited address, so an organisation whose
        # UPN differs from its primary mail produces two legitimate spellings.
        # Refusing here would block the cross-tenant case the tool exists for.
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p) }
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p)
            [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; Environment = 'Global'; Account = 'mallory@contoso.com'; Scopes = (Get-PimMinimumGraphScope) }
        }
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            @{ id = '22222222-2222-2222-2222-222222222222'; userPrincipalName = 'mallory@contoso.com'; displayName = 'M' }
        }

        $result = Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $script:CommercialCloud `
            -Force -ExpectedAccount 'ada@contoso.com'

        $result.Success | Should -BeTrue
        $result.Message | Should -Match 'mallory@contoso.com'
        $result.Message | Should -Match 'ada@contoso.com'
        $result.Message | Should -Match 'not the same person'
    }

    It 'reconciles an invited mail address against a different Azure UPN' {
        # Azure reports the UPN; the guest UPN folds to the invited mail address.
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p) }
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p)
            [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; Environment = 'Global'; Account = 'ada.lovelace_contoso.com#EXT#@fabrikam.onmicrosoft.com'; Scopes = (Get-PimMinimumGraphScope) }
        }
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            @{
                id                = '22222222-2222-2222-2222-222222222222'
                userPrincipalName = 'ada.lovelace_contoso.com#EXT#@fabrikam.onmicrosoft.com'
                displayName       = 'Ada Lovelace'
                mail              = 'ada.lovelace@contoso.com'
                otherMails        = @('e123456@corp.contoso.com')
            }
        }

        $result = Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $script:CommercialCloud `
            -Force -ExpectedAccount 'e123456@corp.contoso.com'

        $result.Success | Should -BeTrue
        $result.Message | Should -Not -Match 'not the same person'
    }

    It 'accepts the session when the broker signs in as the guest form of the same person' {
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p) }
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p)
            [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; Environment = 'Global'; Account = 'ada_contoso.com#EXT#@fabrikam.onmicrosoft.com'; Scopes = (Get-PimMinimumGraphScope) }
        }

        $result = Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $script:CommercialCloud `
            -Force -ExpectedAccount 'ada@contoso.com'

        $result.Success | Should -BeTrue
    }

    It 'refuses a session that will not say who it belongs to' {
        # Account is blank and /me fails, so there is no evidence of who this is.
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p) }
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p)
            [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; Environment = 'Global'; Account = ''; Scopes = (Get-PimMinimumGraphScope) }
        }
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) throw 'Forbidden' }

        $result = Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $script:CommercialCloud `
            -Force -ExpectedAccount 'ada@contoso.com'

        $result.Success | Should -BeFalse
        $result.Detail  | Should -Match 'which account the session belongs to'
    }

    It 'accepts a token-based session once Graph confirms the principal' {
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p) }
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p)
            [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; Environment = 'Global'; Account = ''; Scopes = (Get-PimMinimumGraphScope) }
        }
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            @{ id = '22222222-2222-2222-2222-222222222222'; userPrincipalName = 'ada_contoso.com#EXT#@fabrikam.onmicrosoft.com'; displayName = 'Ada' }
        }

        $result = Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $script:CommercialCloud `
            -Force -ExpectedAccount 'ada@contoso.com'

        $result.Success | Should -BeTrue
    }

    It 'does not reuse a session that belongs to a different account' {
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p)
            [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; Environment = 'Global'; Account = 'mallory@contoso.com'; Scopes = (Get-PimMinimumGraphScope) }
        }
        $script:Connected = $false
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p) $script:Connected = $true }

        $null = Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $script:CommercialCloud `
            -ExpectedAccount 'ada@contoso.com'

        $script:Connected | Should -BeTrue -Because 'the mismatched session must not be reused'
    }

    It 'asks the broker for the account Azure is already signed in as' {
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p) $script:ConnectParameters = $p }
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p)
            [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; Environment = 'Global'; Account = 'ada@contoso.com'; Scopes = (Get-PimMinimumGraphScope) }
        }

        $null = Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $script:CommercialCloud `
            -Force -ExpectedAccount 'ada@contoso.com'

        if (Test-PimConnectSupportsLoginHint) {
            $script:ConnectParameters['LoginHint'] | Should -Be 'ada@contoso.com'
        }
        else {
            $script:ConnectParameters.ContainsKey('LoginHint') | Should -BeFalse
        }
    }

    It 'does not ask Graph who it is when there is no account to check against' {
        # Headless list modes connect without an expected account. Resolving the
        # principal there would cost a network round-trip per tenant for nothing.
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p)
            [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; Environment = 'Global'; Account = ''; Scopes = (Get-PimMinimumGraphScope) }
        }
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) throw 'Graph should not be called.' }
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p) throw 'Should have reused the session.' }

        $result = Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $script:CommercialCloud

        $result.Success | Should -BeTrue
        $result.Message | Should -Match 'Reused'
    }

    It 'connects with the full scope set and the correct environment' {
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p) $script:ConnectParameters = $p }
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p)
            [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; Environment = 'USGovDoD'; Account = 'u@contoso.com'; Scopes = @('PrivilegedEligibilitySchedule.Read.AzureADGroup', 'PrivilegedAssignmentSchedule.ReadWrite.AzureADGroup', 'Group.Read.All') }
        }

        $result = Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $script:DodCloud -Force

        $result.Success      | Should -BeTrue
        $result.HasGroupRead | Should -BeTrue
        $script:ConnectParameters['Environment']  | Should -Be 'USGovDoD'
        $script:ConnectParameters['ContextScope'] | Should -Be 'Process'
        $script:ConnectParameters['TenantId']     | Should -Be $script:TenantId
        $script:ConnectParameters['NoWelcome']    | Should -BeTrue
        $script:ConnectParameters['Scopes']       | Should -Contain 'PrivilegedAssignmentSchedule.ReadWrite.AzureADGroup'
    }

    It 'never passes a client secret or credential' {
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p) $script:ConnectParameters = $p }
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p)
            [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; Environment = 'Global'; Scopes = (Get-PimMinimumGraphScope) }
        }

        Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $script:CommercialCloud -Force | Out-Null

        foreach ($forbidden in 'ClientSecret', 'ClientSecretCredential', 'Credential', 'CertificateThumbprint', 'AccessToken', 'Certificate') {
            $script:ConnectParameters.ContainsKey($forbidden) | Should -BeFalse -Because "$forbidden would break the delegated, no-app-registration design"
        }
    }

    It 'reuses an existing matching context' {
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p) throw 'Connect-MgGraph must not be called' }
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p)
            [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; Environment = 'Global'; Scopes = (Get-PimDefaultGraphScope) }
        }

        $result = Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $script:CommercialCloud
        $result.Success | Should -BeTrue
        $result.Message | Should -Match 'Reused'
    }

    It 'falls back to the minimum scopes when the full set is not consented' {
        $script:Attempts = @()
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p)
            $script:Attempts += , @($p['Scopes'])
            # Group.Read.All is the only scope in the full set but not the minimum set.
            if (@($p['Scopes']) -contains 'Group.Read.All') { throw 'AADSTS65001: The user or administrator has not consented to use the application.' }
        }
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p)
            [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; Environment = 'Global'; Scopes = (Get-PimMinimumGraphScope) }
        }

        $result = Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $script:CommercialCloud -Force

        $result.Success      | Should -BeTrue
        $result.HasGroupRead | Should -BeFalse
        $result.Message      | Should -Match 'reduced permissions'
        $script:Attempts.Count | Should -Be 2
    }

    It 'does not retry a non-consent failure' {
        $script:CallCount = 0
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p)
            $script:CallCount++
            throw 'AADSTS53003: Access has been blocked by Conditional Access policies.'
        }
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p) $null }

        $result = Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $script:CommercialCloud -Force
        $result.Success        | Should -BeFalse
        $result.Message        | Should -Match 'Conditional Access'
        $script:CallCount      | Should -Be 1
    }

    It 'returns a tenant-level failure instead of throwing' {
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p) throw "AADSTS50020: User account does not exist in tenant" }
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p) $null }

        { $script:ConnectResult = Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $script:CommercialCloud -Force } | Should -Not -Throw
        $result = $script:ConnectResult
        $result.Success  | Should -BeFalse
        $result.TenantId | Should -Be $script:TenantId
        $result.Message  | Should -Match 'does not have access to this tenant'
    }

    It 'fails when Graph connects to the wrong tenant' {
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p) }
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p)
            [pscustomobject]@{ TenantId = '99999999-9999-9999-9999-999999999999'; Environment = 'Global'; Scopes = @() }
        }

        $result = Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $script:CommercialCloud -Force
        $result.Success | Should -BeFalse
        $result.Detail  | Should -Match 'instead of tenant'
    }

    It 'fails when Graph connects to the wrong environment' {
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p) }
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p)
            [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; Environment = 'Global'; Scopes = @() }
        }

        $result = Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $script:DodCloud -Force
        $result.Success | Should -BeFalse
        $result.Detail  | Should -Match 'instead of tenant'
    }

    It 'does not retry when the fallback scopes equal the requested scopes' {
        $script:CallCount = 0
        Set-PimCommandOverride -Name 'Connect-MgGraph' -Handler { param($p) $script:CallCount++; throw 'AADSTS65001: not consented' }
        Set-PimCommandOverride -Name 'Get-MgContext' -Handler { param($p) $null }

        Connect-PimGraphTenant -TenantId $script:TenantId -CloudConfiguration $script:CommercialCloud -Force `
            -Scopes (Get-PimMinimumGraphScope) -FallbackScopes (Get-PimMinimumGraphScope) | Out-Null

        $script:CallCount | Should -Be 1
    }
}

Describe 'Compare-PimScopeSet' {
    It 'treats differently ordered sets as equal' {
        Compare-PimScopeSet -Left @('b', 'a') -Right @('a', 'b') | Should -BeTrue
    }

    It 'ignores case' {
        Compare-PimScopeSet -Left @('Group.Read.All') -Right @('group.read.all') | Should -BeTrue
    }

    It 'detects a different size' {
        Compare-PimScopeSet -Left @('a') -Right @('a', 'b') | Should -BeFalse
    }

    It 'detects different values' {
        Compare-PimScopeSet -Left @('a', 'b') -Right @('a', 'c') | Should -BeFalse
    }
}

Describe 'Invoke-PimGraphRequest' {
    It 'combines a relative path with the Graph base URI' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) @{ requestedUri = $p['Uri'] } }
        $result = Invoke-PimGraphRequest -Uri '/v1.0/me' -GraphBaseUri 'https://dod-graph.microsoft.us/'
        $result.requestedUri | Should -Be 'https://dod-graph.microsoft.us/v1.0/me'
    }

    It 'leaves an absolute URI untouched' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) @{ requestedUri = $p['Uri'] } }
        (Invoke-PimGraphRequest -Uri 'https://graph.microsoft.us/v1.0/me').requestedUri | Should -Be 'https://graph.microsoft.us/v1.0/me'
    }

    It 'requires a base URI for a relative path' {
        { Invoke-PimGraphRequest -Uri '/v1.0/me' } | Should -Throw '*GraphBaseUri is required*'
    }

    It 'refuses to send a bearer-authenticated request over plain http' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) @{ requestedUri = $p['Uri'] } }
        { Invoke-PimGraphRequest -Uri 'http://graph.contoso.example/v1.0/me' } | Should -Throw '*must use https*'
    }

    It 'refuses a base URI that is not https' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) @{ requestedUri = $p['Uri'] } }
        { Invoke-PimGraphRequest -Uri '/v1.0/me' -GraphBaseUri 'http://graph.contoso.example' } | Should -Throw '*must use https*'
    }

    It 'serializes a hashtable body to JSON' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) @{ body = $p['Body']; contentType = $p['ContentType'] } }
        $result = Invoke-PimGraphRequest -Uri 'https://graph.microsoft.com/v1.0/x' -Method POST -Body @{ action = 'selfActivate' }

        $result.contentType            | Should -Be 'application/json'
        ($result.body | ConvertFrom-Json).action | Should -Be 'selfActivate'
    }

    It 'passes a string body through unchanged' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) @{ body = $p['Body'] } }
        (Invoke-PimGraphRequest -Uri 'https://graph.microsoft.com/v1.0/x' -Method POST -Body '{"a":1}').body | Should -Be '{"a":1}'
    }

    It 'requests hashtable output so OData annotations survive' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) @{ outputType = $p['OutputType'] } }
        (Invoke-PimGraphRequest -Uri 'https://graph.microsoft.com/v1.0/x').outputType | Should -Be 'Hashtable'
    }

    It 'retries a throttled request and then succeeds' {
        $script:Attempt = 0
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            $script:Attempt++
            if ($script:Attempt -lt 3) { throw 'Response status code does not indicate success: 429 (TooManyRequests). Retry-After: 0' }
            return @{ ok = $true }
        }

        (Invoke-PimGraphRequest -Uri 'https://graph.microsoft.com/v1.0/x' -InitialRetryDelaySeconds 0).ok | Should -BeTrue
        $script:Attempt | Should -Be 3
    }

    It 'gives up after the retry budget is exhausted' {
        $script:Attempt = 0
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            $script:Attempt++
            throw 'Response status code does not indicate success: 503 (ServiceUnavailable). Retry-After: 0'
        }

        { Invoke-PimGraphRequest -Uri 'https://graph.microsoft.com/v1.0/x' -MaximumRetryCount 2 -InitialRetryDelaySeconds 0 } | Should -Throw
        $script:Attempt | Should -Be 3
    }

    It 'does not retry a non-retryable error' {
        $script:Attempt = 0
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            $script:Attempt++
            throw '{"error":{"code":"Authorization_RequestDenied","message":"Insufficient privileges"}}'
        }

        { Invoke-PimGraphRequest -Uri 'https://graph.microsoft.com/v1.0/x' -InitialRetryDelaySeconds 0 } | Should -Throw
        $script:Attempt | Should -Be 1
    }

    It 'does not retry a POST that failed with a server error' {
        # The request may already have been accepted, so repeating it risks a duplicate activation.
        $script:Attempt = 0
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            $script:Attempt++
            throw 'Request failed with status 503 ServiceUnavailable'
        }

        { Invoke-PimGraphRequest -Uri 'https://graph.microsoft.com/v1.0/x' -Method POST -Body @{ a = 1 } -MaximumRetryCount 3 -InitialRetryDelaySeconds 0 } | Should -Throw
        $script:Attempt | Should -Be 1
    }

    It 'still retries a throttled POST' {
        # A throttled request was rejected before processing, so it is safe to repeat.
        $script:Attempt = 0
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            $script:Attempt++
            if ($script:Attempt -lt 3) { throw 'Request failed with status 429 TooManyRequests Retry-After: 0' }
            @{ id = 'ok' }
        }

        $result = Invoke-PimGraphRequest -Uri 'https://graph.microsoft.com/v1.0/x' -Method POST -Body @{ a = 1 } -MaximumRetryCount 3 -InitialRetryDelaySeconds 0
        $result.id      | Should -Be 'ok'
        $script:Attempt | Should -Be 3
    }

    It 'still retries a GET that failed with a server error' {
        $script:Attempt = 0
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            $script:Attempt++
            if ($script:Attempt -lt 2) { throw 'Request failed with status 503 ServiceUnavailable' }
            @{ id = 'ok' }
        }

        $result = Invoke-PimGraphRequest -Uri 'https://graph.microsoft.com/v1.0/x' -Method GET -MaximumRetryCount 3 -InitialRetryDelaySeconds 0
        $result.id      | Should -Be 'ok'
        $script:Attempt | Should -Be 2
    }
}

Describe 'Get-PimRetryDelaySecond' {
    It 'returns null for a non-retryable error' {
        Get-PimRetryDelaySecond -ErrorObject 'Authorization_RequestDenied' | Should -BeNullOrEmpty
    }

    It 'honors a Retry-After value found in the error text' {
        Get-PimRetryDelaySecond -ErrorObject '429 TooManyRequests Retry-After: 17' | Should -Be 17
    }

    It 'backs off exponentially when no Retry-After is present' {
        Get-PimRetryDelaySecond -ErrorObject '503 ServiceUnavailable' -Attempt 1 -InitialDelaySeconds 2 | Should -Be 2
        Get-PimRetryDelaySecond -ErrorObject '503 ServiceUnavailable' -Attempt 2 -InitialDelaySeconds 2 | Should -Be 4
        Get-PimRetryDelaySecond -ErrorObject '503 ServiceUnavailable' -Attempt 3 -InitialDelaySeconds 2 | Should -Be 8
    }

    It 'caps the delay' {
        Get-PimRetryDelaySecond -ErrorObject '429 TooManyRequests Retry-After: 9999' -MaximumDelaySeconds 60 | Should -Be 60
    }

    It 'treats <Code> as retryable' -ForEach @(
        @{ Code = '429' }, @{ Code = '500' }, @{ Code = '502' }, @{ Code = '503' }, @{ Code = '504' }
    ) {
        Get-PimRetryDelaySecond -ErrorObject "Request failed with status $Code" | Should -Not -BeNullOrEmpty
    }

    It 'treats <Code> as non-retryable' -ForEach @(
        @{ Code = '400' }, @{ Code = '401' }, @{ Code = '403' }, @{ Code = '404' }
    ) {
        Get-PimRetryDelaySecond -ErrorObject "Request failed with status $Code" | Should -BeNullOrEmpty
    }
}

Describe 'Get-PimGraphCollection' {
    It 'follows @odata.nextLink across pages' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            switch ($p['Uri']) {
                'https://graph.microsoft.com/page1' { return @{ value = @(@{ id = 1 }, @{ id = 2 }); '@odata.nextLink' = 'https://graph.microsoft.com/page2' } }
                'https://graph.microsoft.com/page2' { return @{ value = @(@{ id = 3 }); '@odata.nextLink' = 'https://graph.microsoft.com/page3' } }
                default                             { return @{ value = @(@{ id = 4 }) } }
            }
        }

        $items = Get-PimGraphCollection -Uri 'https://graph.microsoft.com/page1'
        $items.Count | Should -Be 4
        @($items | ForEach-Object { $_['id'] }) | Should -Be @(1, 2, 3, 4)
    }

    It 'returns an empty array for an empty collection' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) @{ value = @() } }
        $items = Get-PimGraphCollection -Uri 'https://graph.microsoft.com/x'
        $items.Count | Should -Be 0
    }

    It 'throws rather than returning a truncated collection at the page limit' {
        $script:PageNumber = 0
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            $script:PageNumber++
            @{ value = @(@{ id = $script:PageNumber }); '@odata.nextLink' = "https://graph.microsoft.com/page$($script:PageNumber + 1)" }
        }
        { Get-PimGraphCollection -Uri 'https://graph.microsoft.com/page1' -MaximumPageCount 5 } |
            Should -Throw -ExpectedMessage '*incomplete*'
        $script:PageNumber | Should -Be 5
    }

    It 'throws when Graph returns a repeating next link' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            @{ value = @(@{ id = 1 }); '@odata.nextLink' = 'https://graph.microsoft.com/forever' }
        }
        { Get-PimGraphCollection -Uri 'https://graph.microsoft.com/forever' -MaximumPageCount 50 } |
            Should -Throw -ExpectedMessage '*repeating page link*'
    }
}

Describe 'Get-CurrentGraphUser' {
    It 'returns the signed-in user identity' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            @{ id = '3cce9d87-3986-4f19-8335-7ed075408ca2'; userPrincipalName = 'u@contoso.com'; displayName = 'Test User' }
        }

        $user = Get-CurrentGraphUser -GraphBaseUri 'https://graph.microsoft.com'
        $user.Id                | Should -Be '3cce9d87-3986-4f19-8335-7ed075408ca2'
        $user.UserPrincipalName | Should -Be 'u@contoso.com'
    }

    It 'uses the supplied sovereign Graph host' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) @{ id = 'x'; requestedUri = $p['Uri'] } }
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            $script:RequestedUri = $p['Uri']
            @{ id = '3cce9d87-3986-4f19-8335-7ed075408ca2' }
        }

        Get-CurrentGraphUser -GraphBaseUri 'https://dod-graph.microsoft.us' | Out-Null
        $script:RequestedUri | Should -BeLike 'https://dod-graph.microsoft.us/v1.0/me*'
        $script:RequestedUri | Should -Not -BeLike '*graph.microsoft.com*'
    }

    It 'throws when Graph returns no object ID' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) @{ displayName = 'No id' } }
        { Get-CurrentGraphUser -GraphBaseUri 'https://graph.microsoft.com' } | Should -Throw '*did not return an object ID*'
    }
}

Describe 'Resolve-PimGroup' {
    It 'returns the display name and description' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            @{ id = $script:GroupId; displayName = 'PIM Test Group'; description = 'For testing' }
        }

        $group = Resolve-PimGroup -GroupId $script:GroupId -GraphBaseUri 'https://graph.microsoft.com' -TenantId $script:TenantId
        $group.DisplayName | Should -Be 'PIM Test Group'
        $group.Description | Should -Be 'For testing'
        $group.Resolved    | Should -BeTrue
    }

    It 'falls back to the group ID when the directory read is denied' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) throw '{"error":{"code":"Authorization_RequestDenied"}}' }

        $group = Resolve-PimGroup -GroupId $script:GroupId -GraphBaseUri 'https://graph.microsoft.com' -TenantId $script:TenantId
        $group.DisplayName | Should -Be $script:GroupId
        $group.Resolved    | Should -BeFalse
    }

    It 'caches a resolved group so Graph is queried once' {
        $script:Calls = 0
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            $script:Calls++
            @{ id = $script:GroupId; displayName = 'Cached Group' }
        }

        Resolve-PimGroup -GroupId $script:GroupId -GraphBaseUri 'https://graph.microsoft.com' -TenantId $script:TenantId | Out-Null
        Resolve-PimGroup -GroupId $script:GroupId -GraphBaseUri 'https://graph.microsoft.com' -TenantId $script:TenantId | Out-Null
        $script:Calls | Should -Be 1
    }

    It 'keys the cache per tenant' {
        $script:Calls = 0
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            $script:Calls++
            @{ id = $script:GroupId; displayName = "Group $($script:Calls)" }
        }

        Resolve-PimGroup -GroupId $script:GroupId -GraphBaseUri 'https://graph.microsoft.com' -TenantId 'tenant-a' | Out-Null
        Resolve-PimGroup -GroupId $script:GroupId -GraphBaseUri 'https://graph.microsoft.com' -TenantId 'tenant-b' | Out-Null
        $script:Calls | Should -Be 2
    }

    It 'rejects a group ID that is not a GUID before interpolating it into a URI' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) throw 'should not be called' }
        { Resolve-PimGroup -GroupId "../../me`$select=id" -GraphBaseUri 'https://graph.microsoft.com' -TenantId $script:TenantId } |
            Should -Throw '*GroupId must be a GUID*'
    }
}

Describe 'Disconnect-PimAzureAccount' {
    It 'clears the group name cache so a name resolved under another account cannot persist' {
        $script:Calls = 0
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            $script:Calls++
            @{ id = $script:GroupId; displayName = "Group $($script:Calls)" }
        }
        Set-PimCommandOverride -Name 'Disconnect-AzAccount' -Handler { param($p) $null }
        Set-PimCommandOverride -Name 'Clear-AzContext'      -Handler { param($p) $null }

        (Resolve-PimGroup -GroupId $script:GroupId -GraphBaseUri 'https://graph.microsoft.com' -TenantId $script:TenantId).DisplayName | Should -Be 'Group 1'

        Disconnect-PimAzureAccount

        (Resolve-PimGroup -GroupId $script:GroupId -GraphBaseUri 'https://graph.microsoft.com' -TenantId $script:TenantId).DisplayName | Should -Be 'Group 2'
        $script:Calls | Should -Be 2
    }
}

Describe 'Get-PimEligibleGroups' {
    BeforeEach {
        $script:EligibilityResponse = @{
            value = @(
                @{
                    id          = "$($script:GroupId)_member_f9003cf6-8905-4c69-a9f8-fd6d04caec69"
                    principalId = $script:PrincipalId
                    groupId     = $script:GroupId
                    accessId    = 'member'
                    status      = 'Provisioned'
                    memberType  = 'direct'
                    scheduleInfo = @{
                        startDateTime = '2026-01-01T00:00:00Z'
                        expiration    = @{ type = 'afterDateTime'; endDateTime = '2027-01-01T00:00:00Z' }
                    }
                }
            )
        }
    }

    It 'rejects a principal ID that is not a GUID before interpolating it into an OData filter' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) throw 'should not be called' }
        { Get-PimEligibleGroups -TenantId $script:TenantId -PrincipalId "x' or startswith(principalId,'" -GraphBaseUri 'https://graph.microsoft.com' } |
            Should -Throw '*PrincipalId must be a GUID*'
    }

    It 'uses filterByCurrentUser first' {        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            $script:RequestedUris += $p['Uri']
            if ($p['Uri'] -like '*filterByCurrentUser*') { return $script:EligibilityResponse }
            return @{ id = $script:GroupId; displayName = 'PIM Test Group' }
        }
        $script:RequestedUris = @()

        $groups = Get-PimEligibleGroups -TenantId $script:TenantId -PrincipalId $script:PrincipalId -GraphBaseUri 'https://graph.microsoft.com' -TenantDisplayName 'Contoso'

        $script:RequestedUris[0] | Should -BeLike "*filterByCurrentUser(on='principal')*"
        $groups.Count            | Should -Be 1
        $groups[0].GroupDisplayName | Should -Be 'PIM Test Group'
        $groups[0].AccessId         | Should -Be 'member'
        $groups[0].TenantDisplayName | Should -Be 'Contoso'
        $groups[0].Selected          | Should -BeFalse
        $groups[0].EndDateTime       | Should -Be '2027-01-01T00:00:00Z'
    }

    It 'falls back to the principalId filter when filterByCurrentUser is unavailable' {
        $script:RequestedUris = @()
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            $script:RequestedUris += $p['Uri']
            if ($p['Uri'] -like '*filterByCurrentUser*') { throw '{"error":{"code":"Request_BadRequest","message":"not supported"}}' }
            if ($p['Uri'] -like '*eligibilitySchedules*')  { return $script:EligibilityResponse }
            return @{ id = $script:GroupId; displayName = 'PIM Test Group' }
        }

        $groups = Get-PimEligibleGroups -TenantId $script:TenantId -PrincipalId $script:PrincipalId -GraphBaseUri 'https://graph.microsoft.com'

        $script:RequestedUris[1] | Should -BeLike "*`$filter=principalId eq '$($script:PrincipalId)'*"
        $groups.Count            | Should -Be 1
    }

    It 'uses the sovereign Graph host for every call' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            $script:RequestedUris += $p['Uri']
            if ($p['Uri'] -like '*filterByCurrentUser*') { return $script:EligibilityResponse }
            return @{ id = $script:GroupId; displayName = 'PIM Test Group' }
        }
        $script:RequestedUris = @()

        Get-PimEligibleGroups -TenantId $script:TenantId -PrincipalId $script:PrincipalId -GraphBaseUri 'https://dod-graph.microsoft.us' | Out-Null

        foreach ($uri in $script:RequestedUris) {
            $uri | Should -BeLike 'https://dod-graph.microsoft.us/*'
        }
    }

    It 'prefers an expanded group object over a separate lookup' {
        $script:EligibilityResponse.value[0]['group'] = @{ id = $script:GroupId; displayName = 'Expanded Name'; description = 'Expanded description' }
        $script:LookupCalls = 0
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            if ($p['Uri'] -like '*filterByCurrentUser*') { return $script:EligibilityResponse }
            $script:LookupCalls++
            return @{ id = $script:GroupId; displayName = 'Should not be used' }
        }

        $groups = Get-PimEligibleGroups -TenantId $script:TenantId -PrincipalId $script:PrincipalId -GraphBaseUri 'https://graph.microsoft.com'
        $groups[0].GroupDisplayName | Should -Be 'Expanded Name'
        $groups[0].GroupDescription | Should -Be 'Expanded description'
        $script:LookupCalls         | Should -Be 0
    }

    It 'returns an empty array when the user has no eligible groups' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) @{ value = @() } }
        $groups = Get-PimEligibleGroups -TenantId $script:TenantId -PrincipalId $script:PrincipalId -GraphBaseUri 'https://graph.microsoft.com'
        $groups.Count | Should -Be 0
    }

    It 'returns both member and owner eligibilities, sorted' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            if ($p['Uri'] -like '*filterByCurrentUser*') {
                return @{ value = @(
                    @{ id = 's2'; principalId = $script:PrincipalId; groupId = $script:GroupId2; accessId = 'owner';  status = 'Provisioned' }
                    @{ id = 's1'; principalId = $script:PrincipalId; groupId = $script:GroupId;  accessId = 'member'; status = 'Provisioned' }
                ) }
            }
            if ($p['Uri'] -like "*$($script:GroupId2)*") { return @{ displayName = 'Zeta Group' } }
            return @{ displayName = 'Alpha Group' }
        }

        $groups = Get-PimEligibleGroups -TenantId $script:TenantId -PrincipalId $script:PrincipalId -GraphBaseUri 'https://graph.microsoft.com'
        $groups.Count               | Should -Be 2
        $groups[0].GroupDisplayName | Should -Be 'Alpha Group'
        $groups[0].AccessId         | Should -Be 'member'
        $groups[1].AccessId         | Should -Be 'owner'
    }

    It 'ignores an eligibility that belongs to another principal' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            if ($p['Uri'] -like '*filterByCurrentUser*') {
                return @{ value = @(@{ id = 's1'; principalId = '99999999-9999-9999-9999-999999999999'; groupId = $script:GroupId; accessId = 'member' }) }
            }
            return @{ displayName = 'x' }
        }

        (Get-PimEligibleGroups -TenantId $script:TenantId -PrincipalId $script:PrincipalId -GraphBaseUri 'https://graph.microsoft.com').Count | Should -Be 0
    }

    It 'skips an eligibility with an unsupported access type' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            if ($p['Uri'] -like '*filterByCurrentUser*') {
                return @{ value = @(@{ id = 's1'; principalId = $script:PrincipalId; groupId = $script:GroupId; accessId = 'somethingNew' }) }
            }
            return @{ displayName = 'x' }
        }

        (Get-PimEligibleGroups -TenantId $script:TenantId -PrincipalId $script:PrincipalId -GraphBaseUri 'https://graph.microsoft.com').Count | Should -Be 0
    }

    It 'skips an eligibility with no group ID' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            if ($p['Uri'] -like '*filterByCurrentUser*') {
                return @{ value = @(@{ id = 's1'; principalId = $script:PrincipalId; accessId = 'member' }) }
            }
            return @{ displayName = 'x' }
        }

        (Get-PimEligibleGroups -TenantId $script:TenantId -PrincipalId $script:PrincipalId -GraphBaseUri 'https://graph.microsoft.com').Count | Should -Be 0
    }

    It 'shows the group ID when name resolution is skipped' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            if ($p['Uri'] -like '*filterByCurrentUser*') { return $script:EligibilityResponse }
            throw 'Group lookup must not happen'
        }

        $groups = Get-PimEligibleGroups -TenantId $script:TenantId -PrincipalId $script:PrincipalId -GraphBaseUri 'https://graph.microsoft.com' -SkipGroupNameResolution
        $groups[0].GroupDisplayName | Should -Be $script:GroupId
    }

    It 'raises a friendly error when both query forms fail' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) throw '{"error":{"code":"Authorization_RequestDenied","message":"Insufficient privileges"}}' }
        { Get-PimEligibleGroups -TenantId $script:TenantId -PrincipalId $script:PrincipalId -GraphBaseUri 'https://graph.microsoft.com' } |
            Should -Throw '*Could not read eligible groups*'
    }
}

Describe 'Request-PimGroupActivation' {
    BeforeEach {
        $script:ActivationArgs = @{
            TenantId          = $script:TenantId
            TenantDisplayName = 'Contoso'
            PrincipalId       = $script:PrincipalId
            GroupId           = $script:GroupId
            GroupDisplayName  = 'PIM Test Group'
            AccessId          = 'member'
            Justification     = 'Investigating incident 123'
            Duration          = [timespan]::FromHours(2)
            GraphBaseUri      = 'https://graph.microsoft.com'
        }
    }

    It 'posts to the assignmentScheduleRequests endpoint and reports success' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            $script:PostUri    = $p['Uri']
            $script:PostMethod = $p['Method']
            $script:PostBody   = $p['Body'] | ConvertFrom-Json
            return @{ id = 'request-123'; status = 'Provisioned' }
        }

        $result = Request-PimGroupActivation @script:ActivationArgs

        $script:PostMethod | Should -Be 'POST'
        $script:PostUri    | Should -Be 'https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/assignmentScheduleRequests'
        $script:PostBody.action   | Should -Be 'selfActivate'
        $script:PostBody.groupId  | Should -Be $script:GroupId
        $script:PostBody.scheduleInfo.expiration.duration | Should -Be 'PT2H'

        $result.Status    | Should -Be 'Success'
        $result.RequestId | Should -Be 'request-123'
        $result.Message   | Should -Match 'Provisioned'
    }

    It 'uses the sovereign Graph host' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) $script:PostUri = $p['Uri']; @{ id = 'r' } }
        $args = $script:ActivationArgs.Clone()
        $args['GraphBaseUri'] = 'https://graph.microsoft.us'

        Request-PimGroupActivation @args | Out-Null
        $script:PostUri | Should -BeLike 'https://graph.microsoft.us/*'
    }

    It 'includes ticket information when supplied' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) $script:PostBody = $p['Body'] | ConvertFrom-Json; @{ id = 'r' } }
        $args = $script:ActivationArgs.Clone()
        $args['TicketNumber'] = 'INC42'
        $args['TicketSystem'] = 'ServiceNow'

        Request-PimGroupActivation @args | Out-Null
        $script:PostBody.ticketInfo.ticketNumber | Should -Be 'INC42'
    }

    It 'returns a failure record instead of throwing when Graph rejects the request' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            throw '{"error":{"code":"RoleAssignmentRequestPolicyValidationFailed","message":"The duration specified exceeds the maximum allowed"}}'
        }

        { $script:ActivationResult = Request-PimGroupActivation @script:ActivationArgs } | Should -Not -Throw
        $result = $script:ActivationResult
        $result.Status  | Should -Be 'Failed'
        $result.Message | Should -Match 'duration exceeds the activation policy'
        $result.Detail  | Should -Match 'RoleAssignmentRequestPolicyValidationFailed'
    }

    It 'reports a policy ticket requirement in an actionable way' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            throw '{"error":{"code":"RoleAssignmentRequestTicketInfoRequired","message":"Ticket information is required"}}'
        }
        (Request-PimGroupActivation @script:ActivationArgs).Message | Should -Match 'ticket information'
    }

    It 'returns a failure record for an invalid payload without calling Graph' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) throw 'Graph must not be called' }
        $args = $script:ActivationArgs.Clone()
        $args['GroupId'] = 'not-a-guid'

        $result = Request-PimGroupActivation @args
        $result.Status  | Should -Be 'Failed'
        $result.Message | Should -Match 'GroupId must be a GUID'
    }

    It 'honors -WhatIf and does not call Graph' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) throw 'Graph must not be called' }
        $result = Request-PimGroupActivation @script:ActivationArgs -WhatIf
        $result.Status | Should -Be 'Skipped'
    }

    It 'redacts a token that appears in a Graph failure' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            throw 'Request failed. Authorization: Bearer AbCdEf0123456789AbCdEf0123456789 was rejected'
        }
        $result = Request-PimGroupActivation @script:ActivationArgs
        $result.Detail  | Should -Not -Match 'AbCdEf0123456789AbCdEf0123456789'
        $result.Message | Should -Not -Match 'AbCdEf0123456789AbCdEf0123456789'
    }
}

Describe 'Get-PimActiveGroupAssignment' {
    It 'returns active assignments' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            @{ value = @(@{ groupId = $script:GroupId; accessId = 'member'; assignmentType = 'activated'; status = 'Provisioned'; memberType = 'direct' }) }
        }

        $active = Get-PimActiveGroupAssignment -GraphBaseUri 'https://graph.microsoft.com' -TenantId $script:TenantId
        $active.Count             | Should -Be 1
        $active[0].AssignmentType | Should -Be 'activated'
    }

    It 'stamps every record with the tenant it came from' {
        # -ListActive merges every tenant into one table, so a record that does not
        # carry its tenant is indistinguishable from an identical one elsewhere.
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            @{ value = @(@{ groupId = $script:GroupId; accessId = 'member'; assignmentType = 'activated'; status = 'Provisioned'; memberType = 'direct' }) }
        }

        $active = Get-PimActiveGroupAssignment -GraphBaseUri 'https://graph.microsoft.com' `
            -TenantId $script:TenantId -TenantDisplayName 'Contoso'

        $active[0].TenantId          | Should -Be $script:TenantId
        $active[0].TenantDisplayName | Should -Be 'Contoso'
    }

    It 'throws by default when the query is not permitted' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) throw '{"error":{"code":"Authorization_RequestDenied"}}' }
        { Get-PimActiveGroupAssignment -GraphBaseUri 'https://graph.microsoft.com' } |
            Should -Throw -ExpectedMessage '*active assignments*'
    }

    It 'returns an empty array when the caller opts out of failures' {
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p) throw '{"error":{"code":"Authorization_RequestDenied"}}' }
        $active = Get-PimActiveGroupAssignment -GraphBaseUri 'https://graph.microsoft.com' -IgnoreFailure
        $active.Count | Should -Be 0
    }
}

Describe 'Get-PimSafeUri' {
    It 'strips the query string so filters are not logged' {
        Get-PimSafeUri -Uri "https://graph.microsoft.com/v1.0/x?`$filter=principalId eq 'abc'" | Should -Be 'https://graph.microsoft.com/v1.0/x'
    }

    It 'leaves a URI without a query alone' {
        Get-PimSafeUri -Uri 'https://graph.microsoft.com/v1.0/me' | Should -Be 'https://graph.microsoft.com/v1.0/me'
    }
}

Describe 'Device code sign-in against the real SDK' {
    AfterEach {
        Clear-PimCommandOverride
        # A user-supplied token is process scoped, and every other test fakes
        # Get-MgContext, but leaving a synthetic context behind would still be a
        # trap for anyone who later writes one that does not.
        if (Get-Command -Name 'Disconnect-MgGraph' -ErrorAction SilentlyContinue) {
            try { $null = Disconnect-MgGraph -ErrorAction Stop } catch { }
        }
    }

    It 'hands a token to the installed Connect-MgGraph and gets a usable context back' {
        # Every other test in this file replaces Connect-MgGraph, so none of them
        # can tell whether the real one would accept what the tool sends it or
        # what it leaves behind afterwards. That gap is the entire back half of
        # sign-in. Here the SDK is real and only the two HTTP calls are faked, so
        # the splat, the token handoff and the context the tool then reads are all
        # exercised as shipped. The token is unsigned and never leaves the process.
        if (-not (Get-Command -Name 'Connect-MgGraph' -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Microsoft.Graph.Authentication is not installed here'
            return
        }

        $tenantId = 'da667b97-c1f7-494e-b7ba-172131cd40d9'
        $account = 'ada_contoso.com#EXT#@fabrikam.onmicrosoft.com'
        $scopes = Get-PimMinimumGraphScope

        $segment = {
            param($Object)
            $json = $Object | ConvertTo-Json -Compress -Depth 5
            [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $header = & $segment @{ typ = 'JWT'; alg = 'none' }
        $payload = & $segment @{
            aud   = 'https://graph.microsoft.com'
            iss   = "https://sts.windows.net/$tenantId/"
            tid   = $tenantId
            upn   = $account
            scp   = ($scopes -join ' ')
            ver   = '1.0'
            iat   = $now
            nbf   = $now
            exp   = $now + 3600
        }
        $script:FakeJwt = "$header.$payload."

        Set-PimCommandOverride -Name 'Start-Sleep' -Handler { param($p) }
        Set-PimCommandOverride -Name 'Invoke-RestMethod' -Handler { param($p)
            if ($p['Uri'] -like '*/devicecode') {
                return [pscustomobject]@{
                    device_code      = 'device-code-value'
                    user_code        = 'ABC123XYZ'
                    verification_uri = 'https://microsoft.com/devicelogin'
                    expires_in       = 900
                    interval         = 5
                }
            }

            return [pscustomobject]@{ access_token = $script:FakeJwt; expires_in = 3600 }
        }

        $context = Connect-PimGraphWithDeviceCode -TenantId $tenantId `
            -CloudConfiguration (Get-PimCloudConfiguration -Name 'Commercial') `
            -Scope $scopes -WarningAction SilentlyContinue

        # Reaching here at all means the splat bound and the tool found a context.
        $context | Should -Not -BeNullOrEmpty
        $context.TenantId | Should -Be $tenantId
        $context.Account  | Should -Be $account

        # The tool decides whether it may read groups by reading these back off the
        # context, so it matters that the SDK really does surface them.
        foreach ($scope in $scopes) {
            $context.Scopes | Should -Contain $scope
        }
    }
}

} # Describe 'PimGraph'
