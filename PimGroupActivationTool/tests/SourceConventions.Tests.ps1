#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Static checks over the module sources.

    The array-wrapping rule exists because a function that ends with
    `return , ([object[]]$x)` emits its array as a single pipeline item. Wrapping such a
    call in @() therefore produces a one-element array containing an array rather than
    flattening it, which silently drops every record. That bug shipped twice during
    development, so it is now enforced here.
#>

BeforeAll {
    $script:SrcPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'src'
    $script:SourceFiles = @(Get-ChildItem -Path $script:SrcPath -Filter '*.psm1')

    # The entry script calls the same functions, so the call-site rules must cover it too.
    $script:EntryScript = Get-Item -LiteralPath (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Start-PimGroupActivationTool.ps1')
    $script:CallSiteFiles = @($script:SourceFiles) + @($script:EntryScript)

    $script:CommaReturningFunctions = New-Object System.Collections.Generic.List[string]
    foreach ($file in $script:SourceFiles) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
        $functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        foreach ($function in $functions) {
            if ($function.Extent.Text -match 'return\s*,\s*\(') {
                $script:CommaReturningFunctions.Add($function.Name)
            }
        }
    }
}

Describe 'Source conventions' {
    It 'finds the functions that return a comma-wrapped array' {
        $script:CommaReturningFunctions.Count | Should -BeGreaterThan 0
    }

    It 'never wraps a comma-returning function call in @()' {
        $names = @($script:CommaReturningFunctions | Sort-Object -Unique)
        $pattern = '@\(\s*(' + ($names -join '|') + ')\b'

        $offenders = New-Object System.Collections.Generic.List[string]
        foreach ($file in $script:CallSiteFiles) {
            $lineNumber = 0
            foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
                $lineNumber++
                if ($line -match $pattern) {
                    $offenders.Add("$($file.Name):$lineNumber $($line.Trim())")
                }
            }
        }

        $offenders -join "`n" | Should -BeNullOrEmpty -Because 'wrapping these calls in @() nests the array instead of flattening it'
    }

    It 'never pipes a comma-returning function directly into another command' {
        # Piping has the same hazard as @(): the comma-wrapped array arrives as a single
        # pipeline item, so Where-Object/ForEach-Object see one Object[] rather than each
        # record. Assign to a variable first, then pipe the variable.
        $names = @($script:CommaReturningFunctions | Sort-Object -Unique)
        $pattern = '(?<![$\w.-])(' + ($names -join '|') + ')\b[^|)\r\n]*\|\s*(Where-Object|ForEach-Object|Select-Object|Sort-Object|Group-Object|Measure-Object|\?|%)\b'

        $offenders = New-Object System.Collections.Generic.List[string]
        foreach ($file in $script:CallSiteFiles) {
            $lineNumber = 0
            foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
                $lineNumber++
                if ($line -match $pattern) {
                    $offenders.Add("$($file.Name):$lineNumber $($line.Trim())")
                }
            }
        }

        $offenders -join "`n" | Should -BeNullOrEmpty -Because 'the comma-wrapped array arrives as one pipeline item instead of one item per record'
    }

    It 'parses every source file without errors' {
        foreach ($file in $script:SourceFiles) {
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
            ($errors | ForEach-Object { "$($file.Name):$($_.Extent.StartLineNumber) $($_.Message)" }) -join "`n" | Should -BeNullOrEmpty
        }
    }

    It 'sets strict mode in every module' {
        foreach ($file in $script:SourceFiles) {
            (Get-Content -LiteralPath $file.FullName -Raw) | Should -Match 'Set-StrictMode -Version Latest'
        }
    }

    It 'never calls GetNewClosure, which breaks module command resolution' {
        # A closure created with GetNewClosure() is bound to a new dynamic module, so
        # functions from this module's nested imports stop resolving inside it.
        foreach ($file in $script:SourceFiles) {
            (Get-Content -LiteralPath $file.FullName -Raw) | Should -Not -Match 'GetNewClosure'
        }
    }

    It 'exports only functions that exist' {
        foreach ($file in $script:SourceFiles) {
            $content = Get-Content -LiteralPath $file.FullName -Raw
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$null)
            $defined = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })

            $exportMatch = [regex]::Match($content, 'Export-ModuleMember\s+-Function\s+@\(([^)]*)\)')
            $exportMatch.Success | Should -BeTrue -Because "$($file.Name) should export an explicit function list"

            $exported = [regex]::Matches($exportMatch.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
            foreach ($name in $exported) {
                $defined | Should -Contain $name -Because "$($file.Name) exports $name"
            }
        }
    }

    It 'never writes a secret-bearing value directly to the log' {
        foreach ($file in $script:SourceFiles) {
            foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
                $line | Should -Not -Match 'Write-PimLog.*\$(accessToken|AccessToken|token|Token|secret|Secret|password|Password)\b'
            }
        }
    }
}

Describe 'Entry script' {
    BeforeAll {
        $script:EntryPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Start-PimGroupActivationTool.ps1'
    }

    It 'exists next to the src folder' {
        Test-Path -LiteralPath $script:EntryPath | Should -BeTrue
    }

    It 'parses without errors' {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:EntryPath, [ref]$null, [ref]$errors)
        ($errors | ForEach-Object { "$($_.Extent.StartLineNumber) $($_.Message)" }) -join "`n" | Should -BeNullOrEmpty
    }

    It 'exposes the GUI and headless parameter sets' {
        $command = Get-Command -Name $script:EntryPath
        $names = @($command.ParameterSets | ForEach-Object { $_.Name })

        $names | Should -Contain 'Gui'
        $names | Should -Contain 'ListTenants'
        $names | Should -Contain 'ListGroups'
        $names | Should -Contain 'ListActive'
        $names | Should -Contain 'Activate'

        ($command.ParameterSets | Where-Object { $_.IsDefault }).Name | Should -Be 'Gui'
    }

    It 'requires a tenant, group, and justification to activate' {
        $command = Get-Command -Name $script:EntryPath
        $activateSet = $command.ParameterSets | Where-Object { $_.Name -eq 'Activate' }
        $mandatory = @($activateSet.Parameters | Where-Object { $_.IsMandatory } | ForEach-Object { $_.Name })

        $mandatory | Should -Contain 'TenantId'
        $mandatory | Should -Contain 'GroupId'
        $mandatory | Should -Contain 'Justification'
    }

    It 'documents every parameter set with an example' {
        $help = Get-Help -Name $script:EntryPath
        @($help.examples.example).Count | Should -BeGreaterOrEqual 4
    }

    It 'references only module files that exist' {
        $content = Get-Content -LiteralPath $script:EntryPath -Raw
        foreach ($name in [regex]::Matches($content, "'(Pim\w+\.psm1)'") | ForEach-Object { $_.Groups[1].Value }) {
            Test-Path -LiteralPath (Join-Path $script:SrcPath $name) | Should -BeTrue -Because "the entry script imports $name"
        }
    }
}
