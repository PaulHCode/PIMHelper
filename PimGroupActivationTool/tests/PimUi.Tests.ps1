#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:SrcPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'src'
    Import-Module (Join-Path $script:SrcPath 'PimModels.psm1')  -Force
    Import-Module (Join-Path $script:SrcPath 'PimLogging.psm1') -Force
    Import-Module (Join-Path $script:SrcPath 'PimGraph.psm1')   -Force
    Import-Module (Join-Path $script:SrcPath 'PimUi.psm1')      -Force

    Initialize-PimLog -Disable | Out-Null

    $script:TempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("PimUiTests-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
}

AfterAll {
    if ($script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot)) {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Module PimUi, PimGraph, PimLogging, PimModels -Force -ErrorAction SilentlyContinue
}

Describe 'PimUi' {

Describe 'Stop-PimUiOperation' {
    It 'returns promptly when the worker refuses to yield' {
        # This runs on the UI thread inside FormClosing, where anything that waits
        # shows the user a frozen window. Thread::Sleep does not yield to Stop(),
        # which is how an in-flight interactive sign-in behaves.
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ApartmentState = 'STA'
        $runspace.Open()

        $ps = [powershell]::Create()
        $ps.Runspace = $runspace
        $null = $ps.AddScript('[System.Threading.Thread]::Sleep(4000)')
        $handle = $ps.BeginInvoke()

        # Let the pipeline actually enter the sleep before asking it to stop.
        Start-Sleep -Milliseconds 400

        $shared = New-PimSharedState
        $operation = [pscustomobject]@{ PowerShell = $ps; Runspace = $runspace; Shared = $shared }

        $elapsed = Measure-Command { $script:Disposed = Stop-PimUiOperation -Operation $operation }

        try {
            $elapsed.TotalSeconds | Should -BeLessThan 2 -Because 'the UI thread must not wait for a worker that will not yield'
            $script:Disposed      | Should -BeFalse -Because 'disposing would have blocked, so the handles are left to process exit'
            $shared.CancelRequested | Should -BeTrue
        }
        finally {
            $null = $handle
            try { $ps.Dispose() }       catch { }
            try { $runspace.Dispose() } catch { }
        }
    }

    It 'reclaims the handles when the worker has already finished' {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()

        $ps = [powershell]::Create()
        $ps.Runspace = $runspace
        $null = $ps.AddScript('1')
        $null = $ps.Invoke()

        $operation = [pscustomobject]@{ PowerShell = $ps; Runspace = $runspace; Shared = (New-PimSharedState) }

        Stop-PimUiOperation -Operation $operation | Should -BeTrue
    }

    It 'does nothing when there is no operation' {
        Stop-PimUiOperation -Operation $null | Should -BeFalse
    }
}

Describe 'New-PimSharedState' {
    It 'creates a synchronized hashtable with the progress fields' {
        $shared = New-PimSharedState

        $shared                     | Should -Not -BeNullOrEmpty
        $shared.ContainsKey('Status')          | Should -BeTrue
        $shared.ContainsKey('PercentComplete') | Should -BeTrue
        $shared.ContainsKey('CancelRequested') | Should -BeTrue
        $shared.CancelRequested     | Should -BeFalse
        $shared.PercentComplete     | Should -Be 0
    }

    It 'is synchronized so a worker thread can write to it safely' {
        $shared = New-PimSharedState
        $shared.IsSynchronized | Should -BeTrue
    }

    It 'returns a new instance each time' {
        $a = New-PimSharedState
        $b = New-PimSharedState
        $a.Status = 'changed'
        $b.Status | Should -Not -Be 'changed'
    }
}

Describe 'Start-PimAsyncOperation and Complete-PimAsyncOperation' {
    It 'runs a scriptblock on a worker runspace and returns its output' {
        $operation = Start-PimAsyncOperation -Name 'Test' -Script { param($Value, $Shared) "echo:$Value" } -Parameters @{ Value = 'hello' }

        while (-not $operation.Handle.IsCompleted) { Start-Sleep -Milliseconds 25 }
        $completion = Complete-PimAsyncOperation -Operation $operation

        $completion.Success | Should -BeTrue
        $completion.Name    | Should -Be 'Test'
        $completion.Output  | Should -Contain 'echo:hello'
    }

    It 'shares progress state between the worker and the caller' {
        $operation = Start-PimAsyncOperation -Name 'Progress' -Script {
            param($Shared)
            $Shared.Status = 'working'
            $Shared.PercentComplete = 42
            'done'
        }

        while (-not $operation.Handle.IsCompleted) { Start-Sleep -Milliseconds 25 }
        $null = Complete-PimAsyncOperation -Operation $operation

        $operation.Shared.Status          | Should -Be 'working'
        $operation.Shared.PercentComplete | Should -Be 42
    }

    It 'lets the caller request cooperative cancellation' {
        $operation = Start-PimAsyncOperation -Name 'Cancel' -Script {
            param($Shared)
            for ($i = 0; $i -lt 200; $i++) {
                if ($Shared.CancelRequested) { return 'cancelled' }
                Start-Sleep -Milliseconds 20
            }
            return 'finished'
        }

        Start-Sleep -Milliseconds 100
        $operation.Shared.CancelRequested = $true

        while (-not $operation.Handle.IsCompleted) { Start-Sleep -Milliseconds 25 }
        $completion = Complete-PimAsyncOperation -Operation $operation

        $completion.Output | Should -Contain 'cancelled'
    }

    It 'reports a terminating error instead of throwing' {
        $operation = Start-PimAsyncOperation -Name 'Boom' -Script { param($Shared) throw 'worker exploded' }

        while (-not $operation.Handle.IsCompleted) { Start-Sleep -Milliseconds 25 }
        $completion = Complete-PimAsyncOperation -Operation $operation

        $completion.Success | Should -BeFalse
        $completion.Failure | Should -Not -BeNullOrEmpty
        (ConvertTo-PimErrorText -ErrorObject $completion.Failure) | Should -Match 'worker exploded'
    }
}

Describe 'Get-PimAsyncStreamText' {
    It 'drains information, warning, and error records once each' {
        $operation = Start-PimAsyncOperation -Name 'Streams' -Script {
            param($Shared)
            $InformationPreference = 'Continue'
            Write-Information 'info one'
            Write-Warning 'warn one'
            Write-Error 'error one' -ErrorAction Continue
            'output'
        }

        while (-not $operation.Handle.IsCompleted) { Start-Sleep -Milliseconds 25 }

        $first = Get-PimAsyncStreamText -Operation $operation
        $levels = @($first | ForEach-Object { $_.Level })

        $levels | Should -Contain 'Information'
        $levels | Should -Contain 'Warning'
        $levels | Should -Contain 'Error'
        @($first | Where-Object { $_.Text -match 'info one' }).Count  | Should -Be 1
        @($first | Where-Object { $_.Text -match 'warn one' }).Count  | Should -Be 1

        # A second drain must not repeat records already surfaced to the UI.
        $second = Get-PimAsyncStreamText -Operation $operation
        $second.Count | Should -Be 0

        $null = Complete-PimAsyncOperation -Operation $operation
    }

    It 'returns an empty array when there is nothing new' {
        $operation = Start-PimAsyncOperation -Name 'Quiet' -Script { param($Shared) 'quiet' }
        while (-not $operation.Handle.IsCompleted) { Start-Sleep -Milliseconds 25 }

        $lines = Get-PimAsyncStreamText -Operation $operation
        ($lines -is [array]) | Should -BeTrue
        $lines.Count | Should -Be 0

        $null = Complete-PimAsyncOperation -Operation $operation
    }
}

Describe 'New-PimDataGridView' {
    It 'disables auto-generated columns and row editing' {
        $grid = New-PimDataGridView -Name 'test'
        try {
            $grid.AutoGenerateColumns   | Should -BeFalse
            $grid.AllowUserToAddRows    | Should -BeFalse
            $grid.AllowUserToDeleteRows | Should -BeFalse
            $grid.RowHeadersVisible     | Should -BeFalse
            $grid.Name                  | Should -Be 'test'
        }
        finally { $grid.Dispose() }
    }
}

Describe 'Add-PimGridTextColumn' {
    It 'adds a read-only sortable column' {
        $grid = New-PimDataGridView -Name 'test'
        try {
            $null = Add-PimGridTextColumn -Grid $grid -Name 'GroupName' -HeaderText 'Group' -Width 120

            $grid.Columns.Count            | Should -Be 1
            $grid.Columns['GroupName'].HeaderText | Should -Be 'Group'
            $grid.Columns['GroupName'].ReadOnly   | Should -BeTrue
            $grid.Columns['GroupName'].SortMode   | Should -Be ([System.Windows.Forms.DataGridViewColumnSortMode]::Automatic)
        }
        finally { $grid.Dispose() }
    }

    It 'uses fill sizing when asked' {
        $grid = New-PimDataGridView -Name 'test'
        try {
            $null = Add-PimGridTextColumn -Grid $grid -Name 'Wide' -HeaderText 'Wide' -Width 30 -Fill
            $grid.Columns['Wide'].AutoSizeMode | Should -Be ([System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill)
            $grid.Columns['Wide'].FillWeight   | Should -Be 30
        }
        finally { $grid.Dispose() }
    }
}

Describe 'Add-PimGridCheckBoxColumn' {
    It 'adds an editable checkbox column with an empty header' {
        $grid = New-PimDataGridView -Name 'test'
        try {
            $null = Add-PimGridCheckBoxColumn -Grid $grid -Name 'Selected' -HeaderText ''

            $grid.Columns['Selected']          | Should -Not -BeNullOrEmpty
            $grid.Columns['Selected'].ReadOnly | Should -BeFalse
            $grid.Columns['Selected'] -is [System.Windows.Forms.DataGridViewCheckBoxColumn] | Should -BeTrue
        }
        finally { $grid.Dispose() }
    }
}

Describe 'Get-PimCheckedRowTag' {
    BeforeEach {
        $script:Grid = New-PimDataGridView -Name 'test'
        $null = Add-PimGridCheckBoxColumn -Grid $script:Grid -Name 'Selected' -HeaderText ''
        $null = Add-PimGridTextColumn -Grid $script:Grid -Name 'Label' -HeaderText 'Label'

        foreach ($label in 'alpha', 'beta', 'gamma') {
            $index = $script:Grid.Rows.Add($false, $label)
            $script:Grid.Rows[$index].Tag = [pscustomobject]@{ Label = $label }
        }
    }

    AfterEach {
        if ($script:Grid) { $script:Grid.Dispose(); $script:Grid = $null }
    }

    It 'returns an empty array when nothing is checked' {
        $selected = Get-PimCheckedRowTag -Grid $script:Grid
        ($selected -is [array]) | Should -BeTrue
        $selected.Count | Should -Be 0
    }

    It 'returns the tag of every checked row, in row order' {
        $script:Grid.Rows[0].Cells['Selected'].Value = $true
        $script:Grid.Rows[2].Cells['Selected'].Value = $true

        $selected = Get-PimCheckedRowTag -Grid $script:Grid
        $selected.Count     | Should -Be 2
        $selected[0].Label  | Should -Be 'alpha'
        $selected[1].Label  | Should -Be 'gamma'
    }

    It 'ignores rows that have no record attached' {
        $index = $script:Grid.Rows.Add($true, 'orphan')
        $script:Grid.Rows[$index].Tag = $null

        (Get-PimCheckedRowTag -Grid $script:Grid).Count | Should -Be 0
    }

    It 'returns a single checked row as a one-element array, not a bare object' {
        $script:Grid.Rows[1].Cells['Selected'].Value = $true

        $selected = Get-PimCheckedRowTag -Grid $script:Grid
        ($selected -is [array]) | Should -BeTrue
        $selected.Count | Should -Be 1
    }
}

Describe 'Set-PimAllRowChecked' {
    It 'checks and clears every row' {
        $grid = New-PimDataGridView -Name 'test'
        try {
            $null = Add-PimGridCheckBoxColumn -Grid $grid -Name 'Selected' -HeaderText ''
            $null = Add-PimGridTextColumn -Grid $grid -Name 'Label' -HeaderText 'Label'
            foreach ($label in 'a', 'b', 'c') {
                $index = $grid.Rows.Add($false, $label)
                $grid.Rows[$index].Tag = [pscustomobject]@{ Label = $label }
            }

            Set-PimAllRowChecked -Grid $grid -Checked $true
            (Get-PimCheckedRowTag -Grid $grid).Count | Should -Be 3

            Set-PimAllRowChecked -Grid $grid -Checked $false
            (Get-PimCheckedRowTag -Grid $grid).Count | Should -Be 0
        }
        finally { $grid.Dispose() }
    }
}

Describe 'Export-PimResultCsv' {
    BeforeEach {
        $script:CsvPath = Join-Path -Path $script:TempRoot -ChildPath ("results-" + [guid]::NewGuid().ToString('N') + '.csv')
        $script:SampleResults = @(
            New-PimActivationResultRecord -TenantId '11111111-1111-1111-1111-111111111111' -TenantDisplayName 'Contoso' -GroupId '22222222-2222-2222-2222-222222222222' -GroupDisplayName 'PIM Test Group' -AccessId 'member' -Status 'Success' -Message 'Activation requested.' -RequestId 'req-1'
            New-PimActivationResultRecord -TenantId '33333333-3333-3333-3333-333333333333' -TenantDisplayName 'Fabrikam' -GroupId '44444444-4444-4444-4444-444444444444' -GroupDisplayName 'Other Group' -AccessId 'owner' -Status 'Failed' -Message 'Not eligible.'
        )
    }

    It 'writes one row per result with the documented columns' {
        Export-PimResultCsv -Result $script:SampleResults -Path $script:CsvPath

        $rows = @(Import-Csv -LiteralPath $script:CsvPath)
        $rows.Count | Should -Be 2
        $rows[0].TenantDisplayName | Should -Be 'Contoso'
        $rows[0].GroupDisplayName  | Should -Be 'PIM Test Group'
        $rows[0].AccessId          | Should -Be 'member'
        $rows[0].Status            | Should -Be 'Success'
        $rows[0].RequestId         | Should -Be 'req-1'
        $rows[1].Status            | Should -Be 'Failed'
    }

    It 'writes a header-only file for an empty result set' {
        Export-PimResultCsv -Result @() -Path $script:CsvPath
        @(Import-Csv -LiteralPath $script:CsvPath).Count | Should -Be 0
    }

    It 'honours -WhatIf' {
        Export-PimResultCsv -Result $script:SampleResults -Path $script:CsvPath -WhatIf
        Test-Path -LiteralPath $script:CsvPath | Should -BeFalse
    }

    It 'neutralizes a formula-bearing group name from a foreign tenant' {
        # A guest tenant's administrator controls the group display name, so it must not
        # reach Excel as a live formula.
        $hostile = @(
            New-PimActivationResultRecord -TenantId '11111111-1111-1111-1111-111111111111' `
                -TenantDisplayName "=HYPERLINK(`"https://attacker.example`",`"Click`")" `
                -GroupId '22222222-2222-2222-2222-222222222222' `
                -GroupDisplayName "=cmd|'/c calc'!A1" `
                -AccessId 'member' -Status 'Success' -Message '@SUM(A1:A9)'
        )

        Export-PimResultCsv -Result $hostile -Path $script:CsvPath

        $row = @(Import-Csv -LiteralPath $script:CsvPath)[0]
        $row.GroupDisplayName[0]  | Should -Be "'"
        $row.TenantDisplayName[0] | Should -Be "'"
        $row.Message[0]           | Should -Be "'"
    }
}

} # Describe 'PimUi'
