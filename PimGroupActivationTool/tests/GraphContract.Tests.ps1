#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Checks the activation request the tool builds against Microsoft Graph's own
    published schema.

    The PIM calls are the part of this tool that unit tests can say the least
    about. Every other test hands the request to a fake, and a fake will happily
    accept 'groupID' or an action of 'activate' - names that look right and that
    Graph rejects. The real schema is served without authentication, so it can be
    checked even though an actual activation cannot be.

    This needs the network. It is a contract check rather than a unit test, so it
    skips rather than fails when the metadata cannot be reached - a machine
    without internet should not get a red suite over it.
#>

BeforeAll {
    $script:SrcPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'src'
    Import-Module (Join-Path $script:SrcPath 'PimModels.psm1') -Force
    Import-Module (Join-Path $script:SrcPath 'PimLogging.psm1') -Force
    Import-Module (Join-Path $script:SrcPath 'PimGraph.psm1') -Force
    Initialize-PimLog -Disable | Out-Null

    $script:MetadataUri = 'https://graph.microsoft.com/v1.0/$metadata'
    $script:Types = $null
    $script:Enums = $null
    $script:SkipReason = $null

    # Cached per machine: it is ~1.8 MB and does not change between the tests in
    # this file.
    $cachePath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'pim-graph-v1-metadata.xml'
    try {
        $cache = Get-Item -LiteralPath $cachePath -ErrorAction SilentlyContinue
        if (-not $cache -or $cache.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-7)) {
            $progress = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            try {
                Invoke-WebRequest -Uri $script:MetadataUri -OutFile $cachePath -UseBasicParsing -TimeoutSec 60
            }
            finally {
                $ProgressPreference = $progress
            }
        }

        [xml]$metadata = Get-Content -LiteralPath $cachePath -Raw
        $schema = $metadata.Edmx.DataServices.Schema | Where-Object { $_.Namespace -eq 'microsoft.graph' }
        if (-not $schema) { throw 'The metadata document has no microsoft.graph schema.' }

        $script:Types = @{}
        foreach ($type in @($schema.EntityType)) { if ($type.Name) { $script:Types[$type.Name] = $type } }
        foreach ($type in @($schema.ComplexType)) { if ($type.Name) { $script:Types[$type.Name] = $type } }

        $script:Enums = @{}
        foreach ($enum in @($schema.EnumType)) { if ($enum.Name) { $script:Enums[$enum.Name] = @($enum.Member.Name) } }

        if ($script:Types.Count -eq 0) { throw 'The metadata document declared no types.' }
    }
    catch {
        $script:SkipReason = "Microsoft Graph metadata is unavailable here: $($_.Exception.Message)"
    }

    # Walks the base type chain so inherited members count too.
    function Get-PimEdmMember {
        param([string] $TypeName)

        $members = @{}
        $current = $TypeName
        $guard = 0
        while ($current -and $script:Types.ContainsKey($current) -and $guard -lt 32) {
            $type = $script:Types[$current]
            foreach ($property in @($type.Property)) {
                if ($property.Name) { $members[$property.Name] = [string]$property.Type }
            }
            foreach ($property in @($type.NavigationProperty)) {
                if ($property.Name) { $members[$property.Name] = [string]$property.Type }
            }
            $current = if ($type.BaseType) { ([string]$type.BaseType) -replace '^.*\.' } else { $null }
            $guard++
        }

        return $members
    }

    function Get-PimEdmTypeName {
        param([string] $EdmType)
        return ($EdmType -replace '^Collection\(' -replace '\)$' -replace '^.*\.')
    }

    # Returns 'parent.child' paths for every leaf and branch the body sets, each
    # paired with the type it has to be a member of.
    function Get-PimBodyMemberPath {
        param([hashtable] $Body, [string] $TypeName, [string] $Prefix = '')

        $results = New-Object System.Collections.Generic.List[object]
        foreach ($key in $Body.Keys) {
            $results.Add([pscustomobject]@{
                Path     = "$Prefix$key"
                Name     = $key
                TypeName = $TypeName
                Value    = $Body[$key]
            })

            if ($Body[$key] -is [hashtable]) {
                $members = Get-PimEdmMember -TypeName $TypeName
                if ($members.ContainsKey($key)) {
                    $childType = Get-PimEdmTypeName -EdmType $members[$key]
                    foreach ($child in (Get-PimBodyMemberPath -Body $Body[$key] -TypeName $childType -Prefix "$Prefix$key.")) {
                        $results.Add($child)
                    }
                }
            }
        }

        return , ([object[]]$results.ToArray())
    }
}

AfterAll {
    Clear-PimCommandOverride
    Remove-Module PimGraph, PimLogging, PimModels -Force -ErrorAction SilentlyContinue
}

Describe 'Graph activation request contract' {
    BeforeEach {
        if ($script:SkipReason) {
            Set-ItResult -Skipped -Because $script:SkipReason
            return
        }
    }

    It 'sends only properties the real privilegedAccessGroupAssignmentScheduleRequest declares' {
        if ($script:SkipReason) { return }

        # Every optional field is supplied so none of them escape the check.
        $body = New-PimActivationRequestBody `
            -PrincipalId '22a090af-a24c-4658-b466-9373747cb69e' `
            -GroupId 'c2af020b-e23a-49f6-99bb-f7380855756a' `
            -AccessId 'member' `
            -Justification 'Contract test' `
            -Duration ([TimeSpan]::FromHours(2)) `
            -TicketNumber '12345' `
            -TicketSystem 'Helpdesk'

        $paths = Get-PimBodyMemberPath -Body $body -TypeName 'privilegedAccessGroupAssignmentScheduleRequest'
        @($paths).Count | Should -BeGreaterThan 0 -Because 'an empty body would make this check vacuous'

        foreach ($entry in $paths) {
            $members = Get-PimEdmMember -TypeName $entry.TypeName
            $members.Count | Should -BeGreaterThan 0 -Because "Graph should declare the type '$($entry.TypeName)'"

            # Ordinal on purpose. PowerShell hashtables and -Contain both ignore
            # case, which would let 'groupID' pass for 'groupId' - the single most
            # likely way to get one of these names wrong, and one OData does not
            # forgive.
            $exact = @($members.Keys | Where-Object { [string]::Equals($_, $entry.Name, [System.StringComparison]::Ordinal) })
            $exact.Count | Should -Be 1 -Because "Graph rejects '$($entry.Path)' - $($entry.TypeName) declares no member spelled exactly that way"
        }
    }

    It 'sends enum values the real schema accepts' -ForEach @(
        @{ EnumName = 'scheduleRequestActions'; Value = 'selfActivate' }
        @{ EnumName = 'privilegedAccessGroupRelationships'; Value = 'member' }
        @{ EnumName = 'privilegedAccessGroupRelationships'; Value = 'owner' }
        @{ EnumName = 'expirationPatternType'; Value = 'afterDuration' }
    ) {
        if ($script:SkipReason) { return }

        $script:Enums.ContainsKey($EnumName) | Should -BeTrue -Because "Graph should declare the enum '$EnumName'"

        $exact = @($script:Enums[$EnumName] | Where-Object { [string]::Equals($_, $Value, [System.StringComparison]::Ordinal) })
        $exact.Count | Should -Be 1 -Because "Graph rejects '$Value' for $EnumName - no member is spelled exactly that way"
    }

    It 'reaches every collection the tool addresses' {
        if ($script:SkipReason) { return }

        $group = $script:Types['privilegedAccessGroup']
        $group | Should -Not -BeNullOrEmpty

        $navigations = @($group.NavigationProperty.Name)
        foreach ($name in @('assignmentScheduleRequests', 'assignmentSchedules', 'eligibilitySchedules')) {
            $navigations | Should -Contain $name -Because "the tool builds a URL ending in '$name'"
        }
    }

    It 'puts a schema-valid body on the wire, not just in the builder' {
        if ($script:SkipReason) { return }

        # The checks above validate a body built in isolation. They say nothing
        # about what Request-PimGroupActivation actually transmits, so a change to
        # the POST could send a different shape and still pass. This captures the
        # real request at the network boundary and holds that against the schema.
        $captured = $null
        Set-PimCommandOverride -Name 'Invoke-MgGraphRequest' -Handler { param($p)
            $script:CapturedBody   = $p['Body']
            $script:CapturedUri    = $p['Uri']
            $script:CapturedMethod = $p['Method']
            return @{ id = 'request-123'; status = 'Provisioned' }
        }

        try {
            $null = Request-PimGroupActivation `
                -TenantId '11111111-1111-1111-1111-111111111111' `
                -PrincipalId '22a090af-a24c-4658-b466-9373747cb69e' `
                -GroupId 'c2af020b-e23a-49f6-99bb-f7380855756a' `
                -GroupDisplayName 'Contract Test Group' `
                -AccessId 'member' `
                -Justification 'Contract test of the transmitted body' `
                -Duration ([TimeSpan]::FromHours(2)) `
                -TicketNumber '12345' `
                -TicketSystem 'Helpdesk' `
                -GraphBaseUri 'https://graph.microsoft.com' `
                -Confirm:$false
        }
        finally {
            Clear-PimCommandOverride
        }

        $script:CapturedMethod | Should -Be 'POST'
        $script:CapturedUri    | Should -Be 'https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/assignmentScheduleRequests'
        $script:CapturedBody   | Should -Not -BeNullOrEmpty

        # It goes out as JSON, so check the JSON rather than the hashtable behind it.
        $captured = $script:CapturedBody | ConvertFrom-Json

        $walk = {
            param($Node, [string] $TypeName, [string] $Prefix)

            foreach ($property in $Node.PSObject.Properties) {
                $members = Get-PimEdmMember -TypeName $TypeName
                $members.Count | Should -BeGreaterThan 0 -Because "Graph should declare the type '$TypeName'"

                $exact = @($members.Keys | Where-Object { [string]::Equals($_, $property.Name, [System.StringComparison]::Ordinal) })
                $exact.Count | Should -Be 1 -Because "Graph rejects '$Prefix$($property.Name)' - $TypeName declares no member spelled exactly that way"

                if ($property.Value -is [System.Management.Automation.PSCustomObject]) {
                    $childType = Get-PimEdmTypeName -EdmType $members[$exact[0]]
                    & $walk $property.Value $childType "$Prefix$($property.Name)."
                }
            }
        }

        $propertyCount = @($captured.PSObject.Properties).Count
        $propertyCount | Should -BeGreaterThan 0 -Because 'an empty request would make this check vacuous'

        & $walk $captured 'privilegedAccessGroupAssignmentScheduleRequest' ''
    }
}
