#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:SrcPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'src'
    Import-Module (Join-Path $script:SrcPath 'PimModels.psm1') -Force
    Import-Module (Join-Path $script:SrcPath 'PimLogging.psm1') -Force

    $script:TempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("PimLogTests-" + [guid]::NewGuid().ToString('N'))
}

AfterAll {
    Initialize-PimLog -Disable | Out-Null
    Set-PimLogSink -Sink $null
    if ($script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot)) {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Module PimLogging, PimModels -Force -ErrorAction SilentlyContinue
}

Describe 'PimLogging' {

BeforeEach {
    Set-PimLogSink -Sink $null
    $script:LogDirectory = Join-Path -Path $script:TempRoot -ChildPath ([guid]::NewGuid().ToString('N'))
}

Describe 'Get-PimLogDirectory' {
    It 'defaults to a PimGroupActivationTool folder under the local app data root' {
        Initialize-PimLog -Disable | Out-Null
        (Get-PimLogDirectory) | Should -BeLike '*PimGroupActivationTool*logs'
    }

    It 'returns the overridden directory after initialization' {
        Initialize-PimLog -Path $script:LogDirectory | Out-Null
        Get-PimLogDirectory | Should -Be $script:LogDirectory
    }
}

Describe 'Initialize-PimLog' {
    It 'creates the log directory and a dated file path' {
        $state = Initialize-PimLog -Path $script:LogDirectory

        $state.Enabled  | Should -BeTrue
        Test-Path -LiteralPath $script:LogDirectory | Should -BeTrue
        $state.FilePath | Should -BeLike (Join-Path $script:LogDirectory 'PimGroupActivationTool-*.log')
        $state.FilePath | Should -BeLike ('*PimGroupActivationTool-{0:yyyyMMdd}.log' -f (Get-Date))
    }

    It 'disables logging and clears the file path when asked' {
        Initialize-PimLog -Path $script:LogDirectory | Out-Null
        $state = Initialize-PimLog -Disable

        $state.Enabled  | Should -BeFalse
        $state.FilePath | Should -BeNullOrEmpty
    }

    It 'never creates a file on disk while logging is disabled' {
        Initialize-PimLog -Disable | Out-Null
        Write-PimLog -Message 'should not be written' -Operation 'Test'

        if (Test-Path -LiteralPath $script:LogDirectory) {
            @(Get-ChildItem -LiteralPath $script:LogDirectory -File).Count | Should -Be 0
        }
    }

    It 'falls back to disabled logging when the directory cannot be created' {
        # Illegal path characters make New-Item fail on Windows.
        $badPath = Join-Path -Path $script:TempRoot -ChildPath 'inva|lid<dir>'

        $state = Initialize-PimLog -Path $badPath -WarningAction SilentlyContinue

        $state.Enabled  | Should -BeFalse
        $state.FilePath | Should -BeNullOrEmpty
    }
}

Describe 'Write-PimLog' {
    It 'writes one line per call with the operational fields' {
        $state = Initialize-PimLog -Path $script:LogDirectory
        Write-PimLog -Message 'Activation submitted.' -Operation 'Activate' -TenantId '11111111-1111-1111-1111-111111111111' -GroupId '22222222-2222-2222-2222-222222222222' -GroupDisplayName 'PIM Test Group' -AccessId 'member' -Status 'Succeeded'

        $lines = @(Get-Content -LiteralPath $state.FilePath)
        $lines.Count | Should -Be 1
        $lines[0] | Should -BeLike '`[*`] `[INFORMATION`] op=Activate tenant=11111111-1111-1111-1111-111111111111 group=22222222-2222-2222-2222-222222222222 groupName="PIM Test Group" access=member status=Succeeded Activation submitted.'
    }

    It 'omits fields that were not supplied' {
        $state = Initialize-PimLog -Path $script:LogDirectory
        Write-PimLog -Message 'Simple message.'

        $line = @(Get-Content -LiteralPath $state.FilePath)[0]
        $line | Should -Not -BeLike '*op=*'
        $line | Should -Not -BeLike '*tenant=*'
        $line | Should -BeLike '*Simple message.'
    }

    It 'appends rather than truncating' {
        $state = Initialize-PimLog -Path $script:LogDirectory
        Write-PimLog -Message 'first'
        Write-PimLog -Message 'second'
        Write-PimLog -Message 'third'

        @(Get-Content -LiteralPath $state.FilePath).Count | Should -Be 3
    }

    It 'records the level in upper case' {
        $state = Initialize-PimLog -Path $script:LogDirectory
        Write-PimLog -Message 'a warning' -Level Warning
        Write-PimLog -Message 'an error' -Level Error

        $lines = @(Get-Content -LiteralPath $state.FilePath)
        $lines[0] | Should -BeLike '*`[WARNING`]*'
        $lines[1] | Should -BeLike '*`[ERROR`]*'
    }

    It 'redacts a bearer token before it reaches disk' {
        $state = Initialize-PimLog -Path $script:LogDirectory
        $token = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk'
        Write-PimLog -Message "Request failed with Authorization: Bearer $token"

        $content = Get-Content -LiteralPath $state.FilePath -Raw
        $content | Should -Not -BeLike '*eyJhbGciOiJIUzI1NiJ9*'
        $content | Should -BeLike '*REDACTED*'
    }

    It 'redacts a JSON access_token before it reaches disk' {
        $state = Initialize-PimLog -Path $script:LogDirectory
        Write-PimLog -Message '{"access_token":"super-secret-value","expires_in":3600}'

        $content = Get-Content -LiteralPath $state.FilePath -Raw
        $content | Should -Not -BeLike '*super-secret-value*'
        $content | Should -BeLike '*REDACTED*'
    }

    It 'sends the formatted line and level to a registered sink' {
        Initialize-PimLog -Disable | Out-Null
        $script:SinkLines = New-Object System.Collections.Generic.List[string]
        $script:SinkLevels = New-Object System.Collections.Generic.List[string]
        Set-PimLogSink -Sink { param($line, $level) $script:SinkLines.Add($line); $script:SinkLevels.Add($level) }

        Write-PimLog -Message 'to the sink' -Level Warning -Operation 'Test'

        $script:SinkLines.Count  | Should -Be 1
        $script:SinkLines[0]     | Should -BeLike '*op=Test to the sink'
        $script:SinkLevels[0]    | Should -Be 'Warning'
    }

    It 'redacts secrets before they reach the sink' {
        Initialize-PimLog -Disable | Out-Null
        $script:SinkLines = New-Object System.Collections.Generic.List[string]
        Set-PimLogSink -Sink { param($line, $level) $script:SinkLines.Add($line) }

        Write-PimLog -Message '{"refresh_token":"do-not-show-me"}'

        $script:SinkLines[0] | Should -Not -BeLike '*do-not-show-me*'
    }

    It 'keeps writing to disk when the sink throws' {
        $state = Initialize-PimLog -Path $script:LogDirectory
        Set-PimLogSink -Sink { param($line, $level) throw 'sink exploded' }

        { Write-PimLog -Message 'still logged' } | Should -Not -Throw
        (Get-Content -LiteralPath $state.FilePath -Raw) | Should -BeLike '*still logged*'
    }

    It 'stops writing but does not throw when the log file becomes unwritable' {
        $state = Initialize-PimLog -Path $script:LogDirectory
        Write-PimLog -Message 'before'

        # Replacing the file with a directory makes Add-Content fail.
        Remove-Item -LiteralPath $state.FilePath -Force
        New-Item -ItemType Directory -Path $state.FilePath -Force | Out-Null

        { Write-PimLog -Message 'after' -WarningAction SilentlyContinue } | Should -Not -Throw
        (Get-PimLogState).Enabled | Should -BeFalse
    }

    It 'accepts an empty message without throwing' {
        Initialize-PimLog -Path $script:LogDirectory | Out-Null
        { Write-PimLog -Message '' } | Should -Not -Throw
    }

    It 'removes the sink when passed null' {
        Initialize-PimLog -Disable | Out-Null
        $script:SinkLines = New-Object System.Collections.Generic.List[string]
        Set-PimLogSink -Sink { param($line, $level) $script:SinkLines.Add($line) }
        Set-PimLogSink -Sink $null

        Write-PimLog -Message 'ignored'
        $script:SinkLines.Count | Should -Be 0
    }
}

} # Describe 'PimLogging'
