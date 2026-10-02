#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:ModulePath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'src\PimModels.psm1'
    Import-Module $script:ModulePath -Force
}

AfterAll {
    Remove-Module PimModels -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-Iso8601Duration' {
    It 'converts <Minutes> minutes to <Expected>' -ForEach @(
        @{ Minutes = 30;   Expected = 'PT30M' }
        @{ Minutes = 60;   Expected = 'PT1H' }
        @{ Minutes = 120;  Expected = 'PT2H' }
        @{ Minutes = 240;  Expected = 'PT4H' }
        @{ Minutes = 480;  Expected = 'PT8H' }
        @{ Minutes = 90;   Expected = 'PT1H30M' }
        @{ Minutes = 1440; Expected = 'P1D' }
        @{ Minutes = 1560; Expected = 'P1DT2H' }
    ) {
        ConvertTo-Iso8601Duration -TimeSpan ([timespan]::FromMinutes($Minutes)) | Should -Be $Expected
    }

    It 'includes seconds when present' {
        ConvertTo-Iso8601Duration -TimeSpan ([timespan]::FromSeconds(45)) | Should -Be 'PT45S'
    }

    It 'rejects a zero duration' {
        { ConvertTo-Iso8601Duration -TimeSpan ([timespan]::Zero) } | Should -Throw '*greater than zero*'
    }

    It 'rejects a negative duration' {
        { ConvertTo-Iso8601Duration -TimeSpan ([timespan]::FromHours(-1)) } | Should -Throw '*greater than zero*'
    }

    It 'rejects fractional seconds' {
        { ConvertTo-Iso8601Duration -TimeSpan ([timespan]::FromMilliseconds(1500)) } | Should -Throw '*fractional seconds*'
    }

    It 'accepts pipeline input' {
        [timespan]::FromHours(2) | ConvertTo-Iso8601Duration | Should -Be 'PT2H'
    }
}

Describe 'ConvertFrom-Iso8601Duration' {
    It 'round-trips every UI duration option' {
        foreach ($option in Get-PimDurationOption) {
            $iso = ConvertTo-Iso8601Duration -TimeSpan $option.TimeSpan
            ConvertFrom-Iso8601Duration -Duration $iso | Should -Be $option.TimeSpan
        }
    }

    It 'parses <Duration> as <TotalMinutes> minutes' -ForEach @(
        @{ Duration = 'PT30M';   TotalMinutes = 30 }
        @{ Duration = 'PT2H';    TotalMinutes = 120 }
        @{ Duration = 'P1DT2H';  TotalMinutes = 1560 }
        @{ Duration = 'pt1h30m'; TotalMinutes = 90 }
    ) {
        (ConvertFrom-Iso8601Duration -Duration $Duration).TotalMinutes | Should -Be $TotalMinutes
    }

    It 'rejects malformed input' {
        { ConvertFrom-Iso8601Duration -Duration '2 hours' } | Should -Throw '*not a supported ISO 8601 duration*'
    }

    It 'rejects a year/month duration that cannot map to an exact TimeSpan' {
        { ConvertFrom-Iso8601Duration -Duration 'P1Y' } | Should -Throw '*not a supported ISO 8601 duration*'
    }

    It 'rejects an empty duration' {
        { ConvertFrom-Iso8601Duration -Duration '   ' } | Should -Throw '*must not be empty*'
    }

    It 'rejects a zero-length duration' {
        { ConvertFrom-Iso8601Duration -Duration 'PT0S' } | Should -Throw '*positive duration*'
    }
}

Describe 'Get-PimDurationOption' {
    It 'offers the five documented durations in ascending order' {
        $options = @(Get-PimDurationOption)
        $options.Count | Should -Be 5
        $options.DisplayName | Should -Be @('30 minutes', '1 hour', '2 hours', '4 hours', '8 hours')

        $previous = [timespan]::Zero
        foreach ($option in $options) {
            $option.TimeSpan | Should -BeGreaterThan $previous
            $previous = $option.TimeSpan
        }
    }
}

Describe 'Get-PimCloudConfiguration' {
    It 'returns the three built-in clouds by default' {
        $clouds = @(Get-PimCloudConfiguration)
        $clouds.Count | Should -Be 3
        $clouds.DisplayName | Should -Be @('Commercial', 'US Government', 'US Government DoD')
    }

    It 'maps <DisplayName> to <AzEnvironment>/<GraphEnvironment>/<GraphBaseUri>' -ForEach @(
        @{ DisplayName = 'Commercial';        AzEnvironment = 'AzureCloud';        GraphEnvironment = 'Global';   GraphBaseUri = 'https://graph.microsoft.com' }
        @{ DisplayName = 'US Government';     AzEnvironment = 'AzureUSGovernment'; GraphEnvironment = 'USGov';    GraphBaseUri = 'https://graph.microsoft.us' }
        @{ DisplayName = 'US Government DoD'; AzEnvironment = 'AzureUSGovernment'; GraphEnvironment = 'USGovDoD'; GraphBaseUri = 'https://dod-graph.microsoft.us' }
    ) {
        $cloud = Get-PimCloudConfiguration -Name $DisplayName
        $cloud.AzEnvironment    | Should -Be $AzEnvironment
        $cloud.GraphEnvironment | Should -Be $GraphEnvironment
        $cloud.GraphBaseUri     | Should -Be $GraphBaseUri
        $cloud.IsSupported      | Should -BeTrue
        $cloud.IsBuiltIn        | Should -BeTrue
    }

    It 'never points a non-commercial cloud at the commercial Graph host' {
        $sovereign = @(Get-PimCloudConfiguration) | Where-Object { $_.DisplayName -ne 'Commercial' }
        foreach ($cloud in $sovereign) {
            $cloud.GraphBaseUri | Should -Not -Be 'https://graph.microsoft.com'
        }
    }

    It 'throws for an unknown cloud name' {
        { Get-PimCloudConfiguration -Name 'Atlantis' } | Should -Throw '*Unknown cloud*'
    }

    It 'returns copies so callers cannot mutate the shared configuration' {
        $first = Get-PimCloudConfiguration -Name 'Commercial'
        $first.GraphBaseUri = 'https://evil.example.com'
        (Get-PimCloudConfiguration -Name 'Commercial').GraphBaseUri | Should -Be 'https://graph.microsoft.com'
    }

    It 'does not duplicate a built-in Az environment as a custom cloud' {
        $clouds = @(Get-PimCloudConfiguration -AzEnvironment @(
            [pscustomobject]@{ Name = 'AzureCloud' }
            [pscustomobject]@{ Name = 'AzureUSGovernment' }
        ) -GraphEnvironment @([pscustomobject]@{ Name = 'Global'; GraphEndpoint = 'https://graph.microsoft.com' }))

        $clouds.Count | Should -Be 3
    }

    It 'surfaces a supported custom cloud when a matching Graph environment exists' {
        $clouds = @(Get-PimCloudConfiguration `
            -AzEnvironment @([pscustomobject]@{ Name = 'AzureChinaCloud' }) `
            -GraphEnvironment @([pscustomobject]@{ Name = 'China'; GraphEndpoint = 'https://microsoftgraph.chinacloudapi.cn' }))

        $custom = $clouds | Where-Object { -not $_.IsBuiltIn }
        $custom.DisplayName      | Should -Be 'Custom: AzureChinaCloud'
        $custom.GraphEnvironment | Should -Be 'China'
        $custom.GraphBaseUri     | Should -Be 'https://microsoftgraph.chinacloudapi.cn'
        $custom.IsSupported      | Should -BeTrue
    }

    It 'marks a custom cloud unsupported when no Graph environment is registered' {
        $clouds = @(Get-PimCloudConfiguration -AzEnvironment @([pscustomobject]@{ Name = 'ContosoSovereign' }) -GraphEnvironment @())

        $custom = $clouds | Where-Object { -not $_.IsBuiltIn }
        $custom.IsSupported       | Should -BeFalse
        $custom.UnsupportedReason | Should -Match 'No Microsoft Graph PowerShell environment is registered'
    }

    It 'marks a custom cloud unsupported when the Graph environment has no endpoint' {
        $clouds = @(Get-PimCloudConfiguration `
            -AzEnvironment @([pscustomobject]@{ Name = 'ContosoSovereign' }) `
            -GraphEnvironment @([pscustomobject]@{ Name = 'ContosoSovereign'; GraphEndpoint = $null }))

        $custom = $clouds | Where-Object { -not $_.IsBuiltIn }
        $custom.IsSupported       | Should -BeFalse
        $custom.UnsupportedReason | Should -Match 'custom app registration'
    }

    It 'trims a trailing slash from a custom Graph endpoint' {
        $clouds = @(Get-PimCloudConfiguration `
            -AzEnvironment @([pscustomobject]@{ Name = 'ContosoSovereign' }) `
            -GraphEnvironment @([pscustomobject]@{ Name = 'ContosoSovereign'; GraphEndpoint = 'https://graph.contoso.example/' }))

        ($clouds | Where-Object { -not $_.IsBuiltIn }).GraphBaseUri | Should -Be 'https://graph.contoso.example'
    }

    It 'gives built-in and custom records an identical property set' {
        # Callers select a cloud by walking this list, so a shape difference between
        # built-in and custom records breaks the picker under StrictMode.
        $clouds = @(Get-PimCloudConfiguration `
            -AzEnvironment @([pscustomobject]@{ Name = 'ContosoSovereign' }) `
            -GraphEnvironment @([pscustomobject]@{ Name = 'ContosoSovereign'; GraphEndpoint = 'https://graph.contoso.example' }))

        $expected = @('AzEnvironment', 'DisplayName', 'GraphBaseUri', 'GraphEnvironment', 'IsBuiltIn', 'IsSupported', 'LoginBaseUri', 'UnsupportedReason')
        foreach ($cloud in $clouds) {
            $actual = @($cloud.PSObject.Properties.Name | Sort-Object)
            ($actual -join ',') | Should -Be ($expected -join ',') -Because "cloud '$($cloud.DisplayName)' must match the shared shape"
        }
    }

    It 'never exposes a Name property, so callers must match on DisplayName' {
        foreach ($cloud in (Get-PimCloudConfiguration)) {
            $cloud.PSObject.Properties['Name'] | Should -BeNullOrEmpty
        }
    }

    It 'marks a custom environment unsupported when its Graph endpoint is not https' {
        # One bad local registration must degrade a single entry, not abort the list.
        $clouds = @(Get-PimCloudConfiguration `
            -AzEnvironment @([pscustomobject]@{ Name = 'ContosoSovereign' }) `
            -GraphEnvironment @([pscustomobject]@{ Name = 'ContosoSovereign'; GraphEndpoint = 'http://graph.contoso.example' }))

        $clouds.Count | Should -BeGreaterThan 3
        $custom = $clouds | Where-Object { -not $_.IsBuiltIn }
        $custom.IsSupported       | Should -BeFalse
        $custom.UnsupportedReason | Should -Match 'https'
        $custom.GraphBaseUri      | Should -BeNullOrEmpty
    }
}

Describe 'Format-PimBaseUri' {
    It 'trims trailing slashes' {
        Format-PimBaseUri -Uri 'https://graph.microsoft.com/' | Should -Be 'https://graph.microsoft.com'
    }

    It 'returns null for empty input' {
        Format-PimBaseUri -Uri '' | Should -BeNullOrEmpty
    }

    It 'leaves a relative path alone' {
        Format-PimBaseUri -Uri 'v1.0/me' | Should -Be 'v1.0/me'
    }

    It 'rejects a plain-http endpoint so bearer tokens are never sent in the clear' {
        { Format-PimBaseUri -Uri 'http://graph.contoso.example' } | Should -Throw -ExpectedMessage '*must use https*'
    }

    It 'rejects a non-http scheme' {
        { Format-PimBaseUri -Uri 'ftp://graph.contoso.example' } | Should -Throw -ExpectedMessage '*must use https*'
    }
}

Describe 'ConvertTo-PimSafeLogValue' {
    It 'passes an ordinary value through unchanged' {
        ConvertTo-PimSafeLogValue -Value 'Contoso Admins' | Should -Be 'Contoso Admins'
    }

    It 'returns null and empty untouched' {
        ConvertTo-PimSafeLogValue -Value $null | Should -BeNullOrEmpty
        ConvertTo-PimSafeLogValue -Value ''   | Should -Be ''
    }

    It 'collapses <Description> so one value cannot forge a second record' -ForEach @(
        @{ Description = 'CRLF';            Value = "a`r`nb";  Expected = 'a b' }
        @{ Description = 'a bare linefeed'; Value = "a`nb";    Expected = 'a b' }
        @{ Description = 'a tab';           Value = "a`tb";    Expected = 'a b' }
        @{ Description = 'a run of breaks'; Value = "a`r`n`r`nb"; Expected = 'a b' }
    ) {
        ConvertTo-PimSafeLogValue -Value $Value | Should -Be $Expected
    }

    It 'rewrites double quotes so a quoted field cannot be closed early' {
        ConvertTo-PimSafeLogValue -Value 'Admins" status=Success' | Should -Be "Admins' status=Success"
    }

    It 'defuses a forged log record in a group display name' {
        $hostile = "Helpdesk`r`n[2024-01-01 00:00:00.000Z] [INFO] op=Activate status=Success"
        $safe = ConvertTo-PimSafeLogValue -Value $hostile
        $safe | Should -Not -Match "`r"
        $safe | Should -Not -Match "`n"
        @($safe -split "`r`n|`n").Count | Should -Be 1
    }
}

Describe 'ConvertTo-PimSafeCsvValue' {
    It 'passes an ordinary value through unchanged' {
        ConvertTo-PimSafeCsvValue -Value 'Contoso Admins' | Should -Be 'Contoso Admins'
    }

    It 'neutralizes a value that Excel would evaluate as a formula' -ForEach @(
        @{ Value = "=cmd|'/c calc'!A1" }
        @{ Value = '+1+1' }
        @{ Value = '-1+1' }
        @{ Value = '@SUM(A1:A9)' }
        @{ Value = "`tleading tab" }
    ) {
        $result = ConvertTo-PimSafeCsvValue -Value $Value
        $result[0] | Should -Be "'"
        $result | Should -Be ("'" + $Value)
    }

    It 'collapses embedded newlines so one value cannot fake extra rows' {
        ConvertTo-PimSafeCsvValue -Value "Contoso`r`nAdmins" | Should -Be 'Contoso Admins'
    }

    It 'returns null and empty values unchanged' {
        ConvertTo-PimSafeCsvValue -Value $null  | Should -BeNullOrEmpty
        ConvertTo-PimSafeCsvValue -Value ''     | Should -Be ''
    }

    It 'does not double-prefix a value that is already escaped' {
        # A leading apostrophe is not a formula character, so it passes through once.
        ConvertTo-PimSafeCsvValue -Value "'=1+1" | Should -Be "'=1+1"
    }

    It 'accepts pipeline input' {
        $results = @('=1+1', 'normal') | ConvertTo-PimSafeCsvValue
        $results[0] | Should -Be "'=1+1"
        $results[1] | Should -Be 'normal'
    }
}

Describe 'Get-PimPropertyValue' {
    It 'reads from a hashtable case-insensitively' {
        Get-PimPropertyValue -InputObject @{ groupId = 'abc' } -Name 'GROUPID' | Should -Be 'abc'
    }

    It 'reads from a pscustomobject case-insensitively' {
        Get-PimPropertyValue -InputObject ([pscustomobject]@{ GroupId = 'abc' }) -Name 'groupid' | Should -Be 'abc'
    }

    It 'returns null for a missing property instead of throwing under strict mode' {
        Get-PimPropertyValue -InputObject ([pscustomobject]@{ A = 1 }) -Name 'Missing' | Should -BeNullOrEmpty
    }

    It 'returns null for a null input object' {
        Get-PimPropertyValue -InputObject $null -Name 'Anything' | Should -BeNullOrEmpty
    }

    It 'reads an OData annotation key containing a dot' {
        Get-PimPropertyValue -InputObject @{ '@odata.nextLink' = 'https://next' } -Name '@odata.nextLink' | Should -Be 'https://next'
    }
}

Describe 'Test-PimPropertyExists' {
    It 'distinguishes an empty collection property from a missing one' {
        $response = @{ value = @() }
        Test-PimPropertyExists -InputObject $response -Name 'value'       | Should -BeTrue
        Test-PimPropertyExists -InputObject $response -Name '@odata.nextLink' | Should -BeFalse
    }

    It 'matches hashtable keys case-insensitively' {
        Test-PimPropertyExists -InputObject @{ DisplayName = 'x' } -Name 'displayname' | Should -BeTrue
    }

    It 'matches PSObject properties case-insensitively' {
        $object = [pscustomobject]@{ DisplayName = 'x' }
        Test-PimPropertyExists -InputObject $object -Name 'displayname' | Should -BeTrue
        Test-PimPropertyExists -InputObject $object -Name 'missing'     | Should -BeFalse
    }

    It 'returns false for a null input object' {
        Test-PimPropertyExists -InputObject $null -Name 'value' | Should -BeFalse
    }

    It 'returns true even when the property value is null' {
        Test-PimPropertyExists -InputObject @{ value = $null } -Name 'value' | Should -BeTrue
    }
}

Describe 'Get-PimFirstPropertyValue' {
    It 'returns the first non-empty candidate' {
        $object = [pscustomobject]@{ Id = ''; TenantId = 'tid' }
        Get-PimFirstPropertyValue -InputObject $object -Name @('Id', 'TenantId') | Should -Be 'tid'
    }

    It 'returns null when every candidate is missing' {
        Get-PimFirstPropertyValue -InputObject ([pscustomobject]@{ A = 1 }) -Name @('X', 'Y') | Should -BeNullOrEmpty
    }
}

Describe 'New-PimTenantRecord' {
    It 'normalizes a modern Az tenant object' {
        $record = New-PimTenantRecord -AzTenant ([pscustomobject]@{
            Id            = '11111111-1111-1111-1111-111111111111'
            TenantId      = '11111111-1111-1111-1111-111111111111'
            Name          = 'Contoso'
            Domains       = @('contoso.onmicrosoft.com', 'contoso.com')
            TenantCategory = 'Home'
        }) -Cloud 'Commercial'

        $record.TenantId          | Should -Be '11111111-1111-1111-1111-111111111111'
        $record.TenantDisplayName | Should -Be 'Contoso'
        $record.PrimaryDomain     | Should -Be 'contoso.onmicrosoft.com'
        $record.Category          | Should -Be 'Home'
        $record.Cloud             | Should -Be 'Commercial'
        $record.Selected          | Should -BeFalse
        $record.Status            | Should -Be 'Discovered'
    }

    It 'prefers DefaultDomain when the tenant exposes one' {
        $record = New-PimTenantRecord -AzTenant ([pscustomobject]@{
            TenantId      = '22222222-2222-2222-2222-222222222222'
            Name          = 'Fabrikam'
            DefaultDomain = 'fabrikam.com'
            Domains       = @('other.com')
        })
        $record.PrimaryDomain | Should -Be 'fabrikam.com'
    }

    It 'falls back to the domain when there is no tenant name' {
        $record = New-PimTenantRecord -AzTenant ([pscustomobject]@{
            TenantId = '33333333-3333-3333-3333-333333333333'
            Domains  = @('guest.onmicrosoft.com')
        })
        $record.TenantDisplayName | Should -Be 'guest.onmicrosoft.com'
    }

    It 'falls back to the tenant ID when there is no name or domain' {
        $record = New-PimTenantRecord -AzTenant ([pscustomobject]@{ TenantId = '44444444-4444-4444-4444-444444444444' })
        $record.TenantDisplayName | Should -Be '44444444-4444-4444-4444-444444444444'
        $record.PrimaryDomain     | Should -BeNullOrEmpty
    }

    It 'accepts a hashtable tenant' {
        $record = New-PimTenantRecord -AzTenant @{ TenantId = '55555555-5555-5555-5555-555555555555'; Name = 'Hash' }
        $record.TenantDisplayName | Should -Be 'Hash'
    }

    It 'throws when the object has no tenant identifier' {
        { New-PimTenantRecord -AzTenant ([pscustomobject]@{ Name = 'Nope' }) } | Should -Throw '*TenantId or Id*'
    }

    It 'builds a record from explicit values' {
        $record = New-PimTenantRecord -TenantId '66666666-6666-6666-6666-666666666666' -TenantDisplayName 'Direct' -PrimaryDomain 'd.com' -Category 'ManagedBy'
        $record.TenantDisplayName | Should -Be 'Direct'
        $record.Category          | Should -Be 'ManagedBy'
    }

    It 'processes pipeline input' {
        $records = @(
            [pscustomobject]@{ TenantId = '77777777-7777-7777-7777-777777777777'; Name = 'A' }
            [pscustomobject]@{ TenantId = '88888888-8888-8888-8888-888888888888'; Name = 'B' }
        ) | New-PimTenantRecord
        $records.Count | Should -Be 2
    }
}

Describe 'New-PimEligibleGroupRecord' {
    It 'builds a complete record' {
        $record = New-PimEligibleGroupRecord `
            -TenantId '11111111-1111-1111-1111-111111111111' `
            -TenantDisplayName 'Contoso' `
            -GroupId '22222222-2222-2222-2222-222222222222' `
            -GroupDisplayName 'PIM Test Group' `
            -GroupDescription 'desc' `
            -PrincipalId '33333333-3333-3333-3333-333333333333' `
            -AccessId 'member' `
            -EligibilityScheduleId 'sched-1'

        $record.Selected         | Should -BeFalse
        $record.GroupDisplayName | Should -Be 'PIM Test Group'
        $record.AccessId         | Should -Be 'member'
        $record.Status           | Should -Be 'Eligible'
    }

    It 'falls back to the group ID when no display name is available' {
        $record = New-PimEligibleGroupRecord -TenantId 't' -GroupId 'g-123' -PrincipalId 'p' -AccessId 'owner'
        $record.GroupDisplayName  | Should -Be 'g-123'
        $record.TenantDisplayName | Should -Be 't'
    }

    It 'rejects an unsupported access type' {
        { New-PimEligibleGroupRecord -TenantId 't' -GroupId 'g' -PrincipalId 'p' -AccessId 'admin' } | Should -Throw
    }
}

Describe 'New-PimActivationResultRecord' {
    It 'redacts a bearer token from the message and detail' {
        $record = New-PimActivationResultRecord -TenantId 't' -Status 'Failed' `
            -Message 'Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTYifQ.abcdefghijklmno' `
            -Detail 'raw {"access_token":"super-secret-value"}'

        $record.Message | Should -Not -Match 'eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9'
        $record.Message | Should -Match 'REDACTED'
        $record.Detail  | Should -Not -Match 'super-secret-value'
    }

    It 'rejects an unknown status' {
        { New-PimActivationResultRecord -TenantId 't' -Status 'Maybe' } | Should -Throw
    }

    It 'defaults the display names to identifiers' {
        $record = New-PimActivationResultRecord -TenantId 'tid' -GroupId 'gid' -Status 'Success'
        $record.TenantDisplayName | Should -Be 'tid'
        $record.GroupDisplayName  | Should -Be 'gid'
    }
}

Describe 'New-PimActivationRequestBody' {
    BeforeAll {
        $script:PrincipalId = '3cce9d87-3986-4f19-8335-7ed075408ca2'
        $script:GroupId     = '14b9e371-5c2c-4ee5-a4a5-2980060d4f4e'
    }

    It 'produces the documented payload shape' {
        $body = New-PimActivationRequestBody -PrincipalId $script:PrincipalId -GroupId $script:GroupId `
            -AccessId 'member' -Justification 'Deploying a fix' -Duration ([timespan]::FromHours(2)) `
            -StartDateTime ([datetime]::new(2026, 1, 2, 3, 4, 5, [System.DateTimeKind]::Utc))

        $body.action                              | Should -Be 'selfActivate'
        $body.principalId                         | Should -Be $script:PrincipalId
        $body.groupId                             | Should -Be $script:GroupId
        $body.accessId                            | Should -Be 'member'
        $body.justification                       | Should -Be 'Deploying a fix'
        $body.scheduleInfo.expiration.type        | Should -Be 'afterDuration'
        $body.scheduleInfo.expiration.duration    | Should -Be 'PT2H'
        $body.scheduleInfo.startDateTime          | Should -Be '2026-01-02T03:04:05.0000000Z'
        $body.ContainsKey('ticketInfo')           | Should -BeFalse
    }

    It 'serializes to JSON that Graph accepts' {
        $json = New-PimActivationRequestBody -PrincipalId $script:PrincipalId -GroupId $script:GroupId `
            -AccessId 'owner' -Justification 'Testing' -Duration ([timespan]::FromMinutes(30)) | ConvertTo-Json -Depth 10
        $parsed = $json | ConvertFrom-Json

        $parsed.accessId                         | Should -Be 'owner'
        $parsed.scheduleInfo.expiration.duration | Should -Be 'PT30M'
    }

    It 'converts a local start time to UTC' {
        $local = [datetime]::new(2026, 6, 1, 12, 0, 0, [System.DateTimeKind]::Local)
        $body = New-PimActivationRequestBody -PrincipalId $script:PrincipalId -GroupId $script:GroupId `
            -AccessId 'member' -Justification 'j' -Duration ([timespan]::FromHours(1)) -StartDateTime $local

        $body.scheduleInfo.startDateTime | Should -Match 'Z$'
        [datetime]::Parse($body.scheduleInfo.startDateTime, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() |
            Should -Be $local.ToUniversalTime()
    }

    It 'defaults the start time to now in UTC' {
        $before = [datetime]::UtcNow.AddSeconds(-5)
        $body = New-PimActivationRequestBody -PrincipalId $script:PrincipalId -GroupId $script:GroupId `
            -AccessId 'member' -Justification 'j' -Duration ([timespan]::FromHours(1))
        $after = [datetime]::UtcNow.AddSeconds(5)

        $start = [datetime]::Parse($body.scheduleInfo.startDateTime, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        $start | Should -BeGreaterThan $before
        $start | Should -BeLessThan $after
    }

    It 'includes ticket information when provided' {
        $body = New-PimActivationRequestBody -PrincipalId $script:PrincipalId -GroupId $script:GroupId `
            -AccessId 'member' -Justification 'j' -Duration ([timespan]::FromHours(1)) `
            -TicketNumber ' INC123 ' -TicketSystem ' ServiceNow '

        $body.ticketInfo.ticketNumber | Should -Be 'INC123'
        $body.ticketInfo.ticketSystem | Should -Be 'ServiceNow'
    }

    It 'includes ticket information when only the number is provided' {
        $body = New-PimActivationRequestBody -PrincipalId $script:PrincipalId -GroupId $script:GroupId `
            -AccessId 'member' -Justification 'j' -Duration ([timespan]::FromHours(1)) -TicketNumber 'INC9'

        $body.ticketInfo.ticketNumber          | Should -Be 'INC9'
        $body.ticketInfo.ContainsKey('ticketSystem') | Should -BeFalse
    }

    It 'trims the justification' {
        $body = New-PimActivationRequestBody -PrincipalId $script:PrincipalId -GroupId $script:GroupId `
            -AccessId 'member' -Justification "  needed for work  " -Duration ([timespan]::FromHours(1))
        $body.justification | Should -Be 'needed for work'
    }

    It 'rejects a whitespace justification' {
        { New-PimActivationRequestBody -PrincipalId $script:PrincipalId -GroupId $script:GroupId `
            -AccessId 'member' -Justification '   ' -Duration ([timespan]::FromHours(1)) } | Should -Throw '*Justification is required*'
    }

    It 'rejects a non-GUID principal ID' {
        { New-PimActivationRequestBody -PrincipalId 'not-a-guid' -GroupId $script:GroupId `
            -AccessId 'member' -Justification 'j' -Duration ([timespan]::FromHours(1)) } | Should -Throw '*PrincipalId must be a GUID*'
    }

    It 'rejects a non-GUID group ID' {
        { New-PimActivationRequestBody -PrincipalId $script:PrincipalId -GroupId 'nope' `
            -AccessId 'member' -Justification 'j' -Duration ([timespan]::FromHours(1)) } | Should -Throw '*GroupId must be a GUID*'
    }

    It 'rejects an empty GUID' {
        { New-PimActivationRequestBody -PrincipalId ([guid]::Empty) -GroupId $script:GroupId `
            -AccessId 'member' -Justification 'j' -Duration ([timespan]::FromHours(1)) } | Should -Throw '*empty GUID*'
    }

    It 'rejects an unsupported access type' {
        { New-PimActivationRequestBody -PrincipalId $script:PrincipalId -GroupId $script:GroupId `
            -AccessId 'administrator' -Justification 'j' -Duration ([timespan]::FromHours(1)) } | Should -Throw
    }

    It 'rejects a zero duration' {
        { New-PimActivationRequestBody -PrincipalId $script:PrincipalId -GroupId $script:GroupId `
            -AccessId 'member' -Justification 'j' -Duration ([timespan]::Zero) } | Should -Throw '*greater than zero*'
    }

    It 'supports selfDeactivate' {
        $body = New-PimActivationRequestBody -PrincipalId $script:PrincipalId -GroupId $script:GroupId `
            -AccessId 'member' -Justification 'j' -Duration ([timespan]::FromHours(1)) -Action 'selfDeactivate'
        $body.action | Should -Be 'selfDeactivate'
    }
}

Describe 'Remove-PimSensitiveData' {
    It 'redacts a JWT' {
        $jwt = 'eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsIng1dCI6ImFiYyJ9.eyJhdWQiOiJodHRwczovL2dyYXBoLm1pY3Jvc29mdC5jb20ifQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c'
        $result = Remove-PimSensitiveData -Text "Request failed. token=$jwt end"
        $result | Should -Not -Match 'SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV'
        $result | Should -Match 'REDACTED'
    }

    It 'redacts an Authorization bearer header' {
        $result = Remove-PimSensitiveData -Text 'Authorization: Bearer AbCdEf0123456789AbCdEf0123456789=='
        $result | Should -Not -Match 'AbCdEf0123456789AbCdEf0123456789'
        $result | Should -Match 'REDACTED'
    }

    It 'redacts <Name> in a JSON payload' -ForEach @(
        @{ Name = 'access_token' }
        @{ Name = 'refresh_token' }
        @{ Name = 'id_token' }
        @{ Name = 'client_secret' }
        @{ Name = 'password' }
    ) {
        $result = Remove-PimSensitiveData -Text ('{{"{0}":"TopSecretValue123"}}' -f $Name)
        $result | Should -Not -Match 'TopSecretValue123'
        $result | Should -Match 'REDACTED'
    }

    It 'leaves ordinary operational text untouched' {
        $text = "Activation for group 'PIM Test Group' in tenant da667b97-c1f7-494e-b7ba-172131cd40d9 succeeded."
        Remove-PimSensitiveData -Text $text | Should -Be $text
    }

    It 'handles null and empty input' {
        Remove-PimSensitiveData -Text $null  | Should -BeNullOrEmpty
        Remove-PimSensitiveData -Text ''     | Should -Be ''
    }
}

Describe 'Format-PimGraphError' {
    It 'maps AADSTS65001 to a consent message' {
        $result = Format-PimGraphError -ErrorObject 'AADSTS65001: The user or administrator has not consented to use the application.'
        $result.FriendlyMessage | Should -Match 'has not consented'
    }

    It 'maps an MFA requirement' {
        (Format-PimGraphError -ErrorObject 'AADSTS50076: Due to a configuration change, you must use multi-factor authentication').FriendlyMessage |
            Should -Match 'Multi-factor authentication'
    }

    It 'maps a Conditional Access block' {
        (Format-PimGraphError -ErrorObject 'AADSTS53003: Access has been blocked by Conditional Access policies.').FriendlyMessage |
            Should -Match 'Conditional Access'
    }

    It 'maps a missing B2B guest account' {
        (Format-PimGraphError -ErrorObject "AADSTS50020: User account 'x@y.com' from identity provider does not exist in tenant").FriendlyMessage |
            Should -Match 'does not have access to this tenant'
    }

    It 'maps a duration policy violation' {
        (Format-PimGraphError -ErrorObject '{"error":{"code":"RoleAssignmentRequestPolicyValidationFailed","message":"The duration specified exceeds the maximum allowed"}}').FriendlyMessage |
            Should -Match 'duration exceeds the activation policy'
    }

    It 'maps a ticket requirement' {
        (Format-PimGraphError -ErrorObject '{"error":{"code":"RoleAssignmentRequestTicketInfoRequired","message":"Ticket information is required"}}').FriendlyMessage |
            Should -Match 'ticket information'
    }

    # PIM reports every unmet activation-policy rule under one umbrella code, so
    # the specific cause is only in the message. Reading the code alone would tell
    # a user who is missing a ticket number to shorten their duration instead.
    It 'reads past the umbrella policy code to <Expected>' -ForEach @(
        @{ Expected = 'ticket information';      GraphMessage = 'Ticket information is required by the policy.' }
        @{ Expected = 'requires a justification'; GraphMessage = 'A justification is required by the assignment policy.' }
        @{ Expected = 'already exists';           GraphMessage = 'The role assignment already exists for this principal.' }
        @{ Expected = 'requires approval';        GraphMessage = 'The request requires approval before it can be activated.' }
        @{ Expected = 'duration exceeds';         GraphMessage = 'The duration specified exceeds the maximum allowed.' }
    ) {
        $raw = '{"error":{"code":"RoleAssignmentRequestPolicyValidationFailed","message":"' + $GraphMessage + '"}}'
        (Format-PimGraphError -ErrorObject $raw).FriendlyMessage | Should -Match $Expected
    }

    It 'surfaces the policy message verbatim when no specific rule recognises it' {
        $raw = '{"error":{"code":"RoleAssignmentRequestPolicyValidationFailed","message":"Rule MfaRule was not satisfied."}}'
        $friendly = (Format-PimGraphError -ErrorObject $raw).FriendlyMessage

        $friendly | Should -Match 'activation policy rejected'
        $friendly | Should -Match 'MfaRule was not satisfied'
        $friendly | Should -Not -Match 'shorter duration'
    }

    It 'maps throttling' {
        (Format-PimGraphError -ErrorObject 'Response status code does not indicate success: 429 (TooManyRequests)').FriendlyMessage |
            Should -Match 'throttled'
    }

    It 'maps a 403 to a permissions message' {
        (Format-PimGraphError -ErrorObject '{"error":{"code":"Authorization_RequestDenied","message":"Insufficient privileges"}}').FriendlyMessage |
            Should -Match 'denied the request'
    }

    It 'maps a cancelled sign-in' {
        (Format-PimGraphError -ErrorObject 'User canceled authentication: AuthenticationCanceled').FriendlyMessage |
            Should -Match 'cancelled'
    }

    It 'maps a DNS failure' {
        (Format-PimGraphError -ErrorObject 'No such host is known. (dod-graph.microsoft.us:443)').FriendlyMessage |
            Should -Match 'could not be reached'
    }

    It 'extracts the Graph error code' {
        (Format-PimGraphError -ErrorObject '{"error":{"code":"Request_ResourceNotFound","message":"Resource not found"}}').Code |
            Should -Be 'Request_ResourceNotFound'
    }

    It 'falls back to the Graph message for an unrecognized error' {
        $result = Format-PimGraphError -ErrorObject '{"error":{"code":"SomethingBrandNew","message":"A very specific new problem occurred."}}'
        $result.FriendlyMessage | Should -Match 'A very specific new problem occurred'
    }

    It 'prefixes the supplied context' {
        (Format-PimGraphError -ErrorObject 'AADSTS65001: not consented' -Context 'Tenant load failed.').FriendlyMessage |
            Should -Match '^Tenant load failed\.'
    }

    It 'redacts tokens from the detail' {
        $result = Format-PimGraphError -ErrorObject 'failed with Authorization: Bearer AbCdEf0123456789AbCdEf0123456789'
        $result.Detail | Should -Not -Match 'AbCdEf0123456789AbCdEf0123456789'
    }

    It 'caps the friendly message length' {
        (Format-PimGraphError -ErrorObject ('x' * 2000)).FriendlyMessage.Length | Should -BeLessOrEqual 400
    }

    It 'handles a null error object' {
        (Format-PimGraphError -ErrorObject $null).FriendlyMessage | Should -Be 'An unknown error occurred.'
    }

    It 'flattens an exception chain' {
        $inner = [System.InvalidOperationException]::new('inner cause')
        $outer = [System.Exception]::new('outer failure', $inner)
        $result = Format-PimGraphError -ErrorObject $outer
        $result.Detail | Should -Match 'outer failure'
        $result.Detail | Should -Match 'inner cause'
    }

    It 'handles a real ErrorRecord' {
        $record = $null
        try { throw 'AADSTS65001: not consented' } catch { $record = $_ }
        (Format-PimGraphError -ErrorObject $record).FriendlyMessage | Should -Match 'has not consented'
    }
}

Describe 'ConvertTo-PimHomeAccountName' {
    It 'leaves a plain user principal name alone' {
        ConvertTo-PimHomeAccountName -Account 'ada@contoso.com' | Should -Be 'ada@contoso.com'
    }

    It 'folds a B2B guest name back to the home account' {
        ConvertTo-PimHomeAccountName -Account 'ada_contoso.com#EXT#@fabrikam.onmicrosoft.com' |
            Should -Be 'ada@contoso.com'
    }

    It 'splits on the last underscore so an underscore in the local part survives' {
        ConvertTo-PimHomeAccountName -Account 'ada_lovelace_contoso.com#EXT#@fabrikam.onmicrosoft.com' |
            Should -Be 'ada_lovelace@contoso.com'
    }

    It 'trims surrounding whitespace' {
        ConvertTo-PimHomeAccountName -Account '  ada@contoso.com  ' | Should -Be 'ada@contoso.com'
    }

    It 'returns an empty string for <name>' -ForEach @(
        @{ Name = 'null';       Value = $null }
        @{ Name = 'empty';      Value = '' }
        @{ Name = 'whitespace'; Value = '   ' }
    ) {
        ConvertTo-PimHomeAccountName -Account $Value | Should -Be ''
    }

    It 'returns the original when the marker has no usable prefix' {
        # Nothing to rebuild from, so guessing would be worse than passing it through.
        ConvertTo-PimHomeAccountName -Account '#EXT#@fabrikam.onmicrosoft.com' |
            Should -Be '#EXT#@fabrikam.onmicrosoft.com'
        ConvertTo-PimHomeAccountName -Account 'nounderscore#EXT#@fabrikam.onmicrosoft.com' |
            Should -Be 'nounderscore#EXT#@fabrikam.onmicrosoft.com'
    }
}

Describe 'Test-PimAccountMatch' {
    It 'matches an identical name regardless of case' {
        Test-PimAccountMatch -Expected 'Ada@Contoso.com' -Actual 'ada@contoso.com' | Should -BeTrue
    }

    It 'matches the home account against its B2B guest spelling' {
        # This is the tool's whole purpose: Azure reports the home UPN while Graph
        # reports the external UPN for the very same person.
        Test-PimAccountMatch -Expected 'ada@contoso.com' -Actual 'ada_contoso.com#EXT#@fabrikam.onmicrosoft.com' |
            Should -BeTrue
    }

    It 'matches in the other direction too' {
        Test-PimAccountMatch -Expected 'ada_contoso.com#EXT#@fabrikam.onmicrosoft.com' -Actual 'ada@contoso.com' |
            Should -BeTrue
    }

    It 'matches the same guest across two different tenants' {
        Test-PimAccountMatch -Expected 'ada_contoso.com#EXT#@fabrikam.onmicrosoft.com' `
            -Actual 'ada_contoso.com#EXT#@northwind.onmicrosoft.com' | Should -BeTrue
    }

    It 'rejects a genuinely different person' {
        Test-PimAccountMatch -Expected 'ada@contoso.com' -Actual 'grace@contoso.com' | Should -BeFalse
    }

    It 'rejects a different person invited from another tenant' {
        Test-PimAccountMatch -Expected 'ada@contoso.com' -Actual 'ada_northwind.com#EXT#@fabrikam.onmicrosoft.com' |
            Should -BeFalse
    }

    It 'cannot be satisfied by an unknown account when one is expected' -ForEach @(
        @{ Case = 'null';       Actual = $null }
        @{ Case = 'empty';      Actual = '' }
        @{ Case = 'whitespace'; Actual = '   ' }
    ) {
        # A Graph context built from a caller-supplied token has a blank account
        # and could belong to anyone, so it must not pass as the expected person.
        Test-PimAccountMatch -Expected 'ada@contoso.com' -Actual $Actual | Should -BeFalse
    }

    It 'has nothing to enforce when no account is expected' -ForEach @(
        @{ Case = 'null';       Expected = $null }
        @{ Case = 'empty';      Expected = '' }
        @{ Case = 'whitespace'; Expected = '   ' }
    ) {
        Test-PimAccountMatch -Expected $Expected -Actual 'ada@contoso.com' | Should -BeTrue
    }
}

Describe 'Test-PimJustification' {
    It 'rejects <Description>' -ForEach @(
        @{ Description = 'null';       Value = $null }
        @{ Description = 'empty';      Value = '' }
        @{ Description = 'whitespace'; Value = "  `t " }
        @{ Description = 'too short';  Value = 'ab' }
        @{ Description = 'shorter than the documented 10-character minimum'; Value = 'needed' }
    ) {
        Test-PimJustification -Justification $Value | Should -BeFalse
    }

    It 'uses the same minimum the error messages promise' {
        # The headless error text says "at least 10 characters"; the default must agree.
        Test-PimJustification -Justification ('x' * 9)  | Should -BeFalse
        Test-PimJustification -Justification ('x' * 10) | Should -BeTrue
    }

    It 'accepts a real justification' {
        Test-PimJustification -Justification 'Investigating incident 123' | Should -BeTrue
    }

    It 'honors a custom minimum length' {
        Test-PimJustification -Justification 'short' -MinimumLength 20 | Should -BeFalse
    }
}

Describe 'Get-PimSubmissionReadiness' {
    It 'allows submission when everything is satisfied' {
        $readiness = Get-PimSubmissionReadiness -SelectedGroupCount 2 -Justification 'Working an incident' -Duration ([timespan]::FromHours(2))
        $readiness.CanSubmit | Should -BeTrue
        $readiness.Reasons.Count | Should -Be 0
    }

    It 'blocks submission with no selected groups' {
        $readiness = Get-PimSubmissionReadiness -SelectedGroupCount 0 -Justification 'Working an incident' -Duration ([timespan]::FromHours(2))
        $readiness.CanSubmit | Should -BeFalse
        $readiness.Reasons   | Should -Contain 'Select at least one group.'
    }

    It 'blocks submission with no justification' {
        $readiness = Get-PimSubmissionReadiness -SelectedGroupCount 1 -Justification '' -Duration ([timespan]::FromHours(2))
        $readiness.CanSubmit | Should -BeFalse
        $readiness.Reasons   | Should -Contain 'Enter a justification of at least 10 characters.'
    }

    It 'blocks submission with no duration' {
        $readiness = Get-PimSubmissionReadiness -SelectedGroupCount 1 -Justification 'Working an incident' -Duration $null
        $readiness.CanSubmit | Should -BeFalse
        $readiness.Reasons   | Should -Contain 'Choose a duration.'
    }

    It 'blocks submission while busy' {
        $readiness = Get-PimSubmissionReadiness -SelectedGroupCount 1 -Justification 'Working an incident' -Duration ([timespan]::FromHours(2)) -IsBusy $true
        $readiness.CanSubmit | Should -BeFalse
        $readiness.Reasons   | Should -Contain 'An operation is already running.'
    }

    It 'reports every blocking reason at once' {
        (Get-PimSubmissionReadiness -SelectedGroupCount 0 -Justification '' -Duration $null).Reasons.Count | Should -Be 3
    }
}

Describe 'Format-PimBaseUri' {
    It 'trims trailing slashes' {
        Format-PimBaseUri -Uri 'https://graph.microsoft.com/' | Should -Be 'https://graph.microsoft.com'
    }

    It 'leaves a clean URI alone' {
        Format-PimBaseUri -Uri 'https://graph.microsoft.us' | Should -Be 'https://graph.microsoft.us'
    }

    It 'returns null for empty input' {
        Format-PimBaseUri -Uri '' | Should -BeNullOrEmpty
    }
}

Describe 'Get-PimUiState' {
    It 'returns the seven lifecycle states in order' {
        $states = Get-PimUiState
        $states.Count | Should -Be 7
        $states[0]    | Should -Be 'SignedOut'
        $states[-1]   | Should -Be 'Completed'
    }

    It 'returns an array even though it is built inline' {
        ((Get-PimUiState) -is [array]) | Should -BeTrue
    }
}

Describe 'Test-PimUiStateTransition' {
    It 'allows the documented happy path' -ForEach @(
        @{ From = 'SignedOut';          To = 'DiscoveringTenants' }
        @{ From = 'DiscoveringTenants'; To = 'TenantsReady' }
        @{ From = 'TenantsReady';       To = 'LoadingGroups' }
        @{ From = 'LoadingGroups';      To = 'GroupsReady' }
        @{ From = 'GroupsReady';        To = 'Submitting' }
        @{ From = 'Submitting';         To = 'Completed' }
        @{ From = 'Completed';          To = 'Submitting' }
    ) {
        Test-PimUiStateTransition -From $From -To $To | Should -BeTrue
    }

    It 'allows the documented failure paths' -ForEach @(
        @{ From = 'DiscoveringTenants'; To = 'SignedOut' }
        @{ From = 'LoadingGroups';      To = 'TenantsReady' }
        @{ From = 'Submitting';         To = 'GroupsReady' }
    ) {
        Test-PimUiStateTransition -From $From -To $To | Should -BeTrue
    }

    It 'rejects skipping sign-in' {
        Test-PimUiStateTransition -From 'SignedOut' -To 'GroupsReady' | Should -BeFalse
        Test-PimUiStateTransition -From 'SignedOut' -To 'Submitting'  | Should -BeFalse
    }

    It 'rejects submitting before groups are loaded' {
        Test-PimUiStateTransition -From 'TenantsReady' -To 'Submitting' | Should -BeFalse
    }

    It 'always allows returning to SignedOut from a settled state' -ForEach @(
        @{ From = 'TenantsReady' }
        @{ From = 'GroupsReady' }
        @{ From = 'Completed' }
    ) {
        Test-PimUiStateTransition -From $From -To 'SignedOut' | Should -BeTrue
    }

    It 'rejects an unknown state' {
        { Test-PimUiStateTransition -From 'NotAState' -To 'SignedOut' } | Should -Throw
    }
}

Describe 'Get-PimUiControlState' {
    It 'only allows cloud selection and sign-in when signed out' {
        $s = Get-PimUiControlState -State 'SignedOut'

        $s.CloudSelectionEnabled  | Should -BeTrue
        $s.SignInEnabled          | Should -BeTrue
        $s.TenantGridEnabled      | Should -BeFalse
        $s.LoadGroupsEnabled      | Should -BeFalse
        $s.GroupGridEnabled       | Should -BeFalse
        $s.RequestSettingsEnabled | Should -BeFalse
        $s.SubmitEnabled          | Should -BeFalse
        $s.CancelEnabled          | Should -BeFalse
        $s.IsBusy                 | Should -BeFalse
    }

    It 'allows only cancel while discovering tenants' {
        $s = Get-PimUiControlState -State 'DiscoveringTenants'

        $s.IsBusy            | Should -BeTrue
        $s.ProgressVisible   | Should -BeTrue
        $s.CancelEnabled     | Should -BeTrue
        $s.SignInEnabled     | Should -BeFalse
        $s.CloudSelectionEnabled | Should -BeFalse
        $s.TenantGridEnabled | Should -BeFalse
        $s.LoadGroupsEnabled | Should -BeFalse
    }

    It 'allows only cancel while loading groups' {
        $s = Get-PimUiControlState -State 'LoadingGroups' -SelectedTenantCount 2

        $s.IsBusy            | Should -BeTrue
        $s.CancelEnabled     | Should -BeTrue
        $s.LoadGroupsEnabled | Should -BeFalse
        $s.TenantGridEnabled | Should -BeFalse
    }

    It 'keeps Load Eligible Groups disabled until a tenant is selected' {
        (Get-PimUiControlState -State 'TenantsReady' -SelectedTenantCount 0).LoadGroupsEnabled | Should -BeFalse
        (Get-PimUiControlState -State 'TenantsReady' -SelectedTenantCount 1).LoadGroupsEnabled | Should -BeTrue
    }

    It 'enables switching accounts once tenants are known' {
        (Get-PimUiControlState -State 'SignedOut').SwitchAccountEnabled    | Should -BeFalse
        (Get-PimUiControlState -State 'TenantsReady').SwitchAccountEnabled | Should -BeTrue
        (Get-PimUiControlState -State 'Completed').SwitchAccountEnabled    | Should -BeTrue
    }

    It 'requires a selected group, justification, and duration before submit is enabled' {
        $readyArgs = @{ State = 'GroupsReady'; SelectedGroupCount = 1; Justification = 'Approved change CHG123'; Duration = [timespan]::FromHours(2) }
        (Get-PimUiControlState @readyArgs).SubmitEnabled | Should -BeTrue

        (Get-PimUiControlState -State 'GroupsReady' -SelectedGroupCount 0 -Justification 'Approved change CHG123' -Duration ([timespan]::FromHours(2))).SubmitEnabled | Should -BeFalse
        (Get-PimUiControlState -State 'GroupsReady' -SelectedGroupCount 1 -Justification '   ' -Duration ([timespan]::FromHours(2))).SubmitEnabled | Should -BeFalse
        (Get-PimUiControlState -State 'GroupsReady' -SelectedGroupCount 1 -Justification 'Approved change CHG123' -Duration $null).SubmitEnabled | Should -BeFalse
    }

    It 'explains why submit is blocked' {
        $s = Get-PimUiControlState -State 'GroupsReady' -SelectedGroupCount 0 -Justification '' -Duration $null
        $s.SubmitBlockedReasons | Should -Contain 'Select at least one group.'
        $s.SubmitBlockedReasons | Should -Contain 'Enter a justification of at least 10 characters.'
        $s.SubmitBlockedReasons | Should -Contain 'Choose a duration.'
    }

    It 'tells the user to load groups first when none are loaded' {
        $s = Get-PimUiControlState -State 'TenantsReady' -SelectedTenantCount 1
        $s.SubmitBlockedReasons | Should -Contain 'Load eligible groups first.'
    }

    It 'never enables submit while an operation is running' {
        $s = Get-PimUiControlState -State 'Submitting' -SelectedGroupCount 3 -Justification 'Approved change CHG123' -Duration ([timespan]::FromHours(1))
        $s.SubmitEnabled | Should -BeFalse
        $s.CancelEnabled | Should -BeTrue
        $s.SubmitBlockedReasons | Should -Contain 'An operation is already running.'
    }

    It 'allows resubmitting from Completed' {
        $s = Get-PimUiControlState -State 'Completed' -SelectedGroupCount 1 -Justification 'Approved change CHG123' -Duration ([timespan]::FromHours(1)) -ResultCount 1
        $s.SubmitEnabled | Should -BeTrue
        $s.ExportEnabled | Should -BeTrue
    }

    It 'only enables export when there are results and nothing is running' {
        (Get-PimUiControlState -State 'Completed' -ResultCount 0).ExportEnabled  | Should -BeFalse
        (Get-PimUiControlState -State 'Completed' -ResultCount 5).ExportEnabled  | Should -BeTrue
        (Get-PimUiControlState -State 'Submitting' -ResultCount 5).ExportEnabled | Should -BeFalse
    }

    It 'rejects an unknown state' {
        { Get-PimUiControlState -State 'Bogus' } | Should -Throw
    }
}

Describe 'Get-PimResetScope' {
    It 'clears everything when the cloud changes' {
        $r = Get-PimResetScope -Change 'Cloud'
        $r.ClearTenants | Should -BeTrue
        $r.ClearGroups  | Should -BeTrue
        $r.ClearResults | Should -BeTrue
        $r.ResetState   | Should -Be 'SignedOut'
    }

    It 'clears everything when the account changes' {
        $r = Get-PimResetScope -Change 'Account'
        $r.ClearTenants | Should -BeTrue
        $r.ResetState   | Should -Be 'SignedOut'
    }

    It 'keeps tenants but clears groups and results when the tenant selection changes' {
        $r = Get-PimResetScope -Change 'TenantSelection'
        $r.ClearTenants | Should -BeFalse
        $r.ClearGroups  | Should -BeTrue
        $r.ClearResults | Should -BeTrue
        $r.ResetState   | Should -Be 'TenantsReady'
    }

    It 'never retains group selections' -ForEach @(
        @{ Change = 'Cloud' }
        @{ Change = 'Account' }
        @{ Change = 'TenantSelection' }
        @{ Change = 'GroupReload' }
    ) {
        (Get-PimResetScope -Change $Change).ClearGroups | Should -BeTrue
    }
}
