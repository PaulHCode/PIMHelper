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
        foreach ($file in $script:SourceFiles) {
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
