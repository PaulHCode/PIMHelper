#Requires -Version 5.1
<#
.SYNOPSIS
    WinForms user interface for the PIM Group Activation Tool.

.DESCRIPTION
    Builds the main window, runs every Azure/Graph call on a background runspace, and
    drives control enablement from the explicit state machine in PimModels.

    Background work uses runspaces plus a UI timer rather than BackgroundWorker. A
    BackgroundWorker raises its events on a threadpool thread, and a PowerShell
    scriptblock handler attached to that event has to marshal back into a runspace that
    is already blocked inside the WinForms message loop, which deadlocks. Polling a
    completed runspace handle from a UI timer keeps every PowerShell call on a thread
    that owns its own runspace.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'PimModels.psm1')  -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'PimLogging.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'PimGraph.psm1')   -DisableNameChecking -ErrorAction Stop

Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
Add-Type -AssemblyName System.Drawing -ErrorAction Stop

$script:ModuleRoot = $PSScriptRoot

#region Async plumbing

function New-PimSharedState {
    <#
    .SYNOPSIS
        Creates the synchronized hashtable shared between the UI and a worker runspace.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return [hashtable]::Synchronized(@{
        Status          = 'Starting...'
        PercentComplete = 0
        CancelRequested = $false
        Completed       = 0
        Total           = 0
    })
}

function Start-PimAsyncOperation {
    <#
    .SYNOPSIS
        Runs a scriptblock on its own runspace and returns a handle the UI timer polls.

    .PARAMETER Script
        The worker scriptblock. It receives the named parameters in -Parameters plus a
        [hashtable] $Shared parameter for progress and cooperative cancellation.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [scriptblock] $Script,

        [Parameter()]
        [hashtable] $Parameters = @{}
    )

    $shared = New-PimSharedState

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.ThreadOptions = 'ReuseThread'
    $runspace.Open()

    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    $null = $shell.AddScript($Script)
    foreach ($key in $Parameters.Keys) {
        $null = $shell.AddParameter($key, $Parameters[$key])
    }
    $null = $shell.AddParameter('Shared', $shared)

    [pscustomobject]@{
        Name        = $Name
        PowerShell  = $shell
        Runspace    = $runspace
        Handle      = $shell.BeginInvoke()
        Shared      = $shared
        InfoIndex   = 0
        WarningIndex = 0
        ErrorIndex  = 0
    }
}

function Get-PimAsyncStreamText {
    <#
    .SYNOPSIS
        Drains new records from a worker's information, warning, and error streams.

    .DESCRIPTION
        Returns objects with Text and Level so the caller can mirror worker output into
        the on-screen log without subscribing to cross-runspace events.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Operation
    )

    $lines = New-Object System.Collections.Generic.List[object]

    $streams = $Operation.PowerShell.Streams

    for ($i = $Operation.InfoIndex; $i -lt $streams.Information.Count; $i++) {
        $lines.Add([pscustomobject]@{ Level = 'Information'; Text = [string]$streams.Information[$i] })
    }
    $Operation.InfoIndex = $streams.Information.Count

    for ($i = $Operation.WarningIndex; $i -lt $streams.Warning.Count; $i++) {
        $lines.Add([pscustomobject]@{ Level = 'Warning'; Text = [string]$streams.Warning[$i] })
    }
    $Operation.WarningIndex = $streams.Warning.Count

    for ($i = $Operation.ErrorIndex; $i -lt $streams.Error.Count; $i++) {
        $lines.Add([pscustomobject]@{ Level = 'Error'; Text = (ConvertTo-PimErrorText -ErrorObject $streams.Error[$i]) })
    }
    $Operation.ErrorIndex = $streams.Error.Count

    return , ([object[]]$lines.ToArray())
}

function Complete-PimAsyncOperation {
    <#
    .SYNOPSIS
        Ends a finished worker, returning its output and any terminating error.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Operation
    )

    $output = @()
    $failure = $null

    try {
        $output = @($Operation.PowerShell.EndInvoke($Operation.Handle))
    }
    catch {
        $failure = $_
    }

    if ($null -eq $failure -and $Operation.PowerShell.Streams.Error.Count -gt 0) {
        $failure = $Operation.PowerShell.Streams.Error[0]
    }

    try { $Operation.PowerShell.Dispose() } catch { Write-Debug "Disposing the worker shell failed: $($_.Exception.Message)" }
    try { $Operation.Runspace.Dispose() }   catch { Write-Debug "Disposing the worker runspace failed: $($_.Exception.Message)" }

    [pscustomobject]@{
        Name    = $Operation.Name
        Output  = $output
        Failure = $failure
        Success = ($null -eq $failure)
    }
}

#endregion

#region Worker scripts

# Each worker runs in a clean runspace, so it re-imports the modules by path. $Shared is
# supplied by Start-PimAsyncOperation.

$script:SignInWorker = {
    param(
        [hashtable] $Paths,
        [object]    $CloudConfiguration,
        [bool]      $ForceNewAccount,
        [bool]      $UseDeviceCode,
        [hashtable] $Shared
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $InformationPreference = 'Continue'

    Import-Module $Paths.Models  -Force -DisableNameChecking
    Import-Module $Paths.Logging -Force -DisableNameChecking
    Import-Module $Paths.Graph   -Force -DisableNameChecking

    if (-not $Paths.LoggingEnabled) { Initialize-PimLog -Disable | Out-Null }
    elseif ($Paths.LogDirectory)    { Initialize-PimLog -Path $Paths.LogDirectory | Out-Null }
    else                            { Initialize-PimLog | Out-Null }

    $Shared.Status = 'Signing in to Azure...'
    Write-Information "Signing in to $($CloudConfiguration.DisplayName)..."

    if ($ForceNewAccount) {
        # Clear both contexts, otherwise the Graph session can stay bound to the
        # previous account while the UI shows the new one.
        Write-Information 'Clearing the existing Azure and Microsoft Graph sessions...'
        Disconnect-PimAzureAccount
        Disconnect-PimGraph
    }

    $connectParams = @{ CloudConfiguration = $CloudConfiguration }
    if ($ForceNewAccount) { $connectParams['Force'] = $true }
    if ($UseDeviceCode)   { $connectParams['UseDeviceAuthentication'] = $true }

    $context = Connect-PimAzureAccount @connectParams

    $Shared.Status = 'Discovering tenants...'
    Write-Information 'Discovering tenants you can access...'

    $tenants = Get-PimAuthorizedTenant -CloudConfiguration $CloudConfiguration

    $Shared.Status = "Found $($tenants.Count) tenant(s)."

    [pscustomobject]@{
        Kind    = 'SignIn'
        Account = $context.Account
        Tenants = $tenants
    }
}

$script:LoadGroupsWorker = {
    param(
        [hashtable] $Paths,
        [object]    $CloudConfiguration,
        [object[]]  $Tenants,
        [bool]      $UseDeviceCode,
        [hashtable] $Shared
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $InformationPreference = 'Continue'

    Import-Module $Paths.Models  -Force -DisableNameChecking
    Import-Module $Paths.Logging -Force -DisableNameChecking
    Import-Module $Paths.Graph   -Force -DisableNameChecking

    if (-not $Paths.LoggingEnabled) { Initialize-PimLog -Disable | Out-Null }
    elseif ($Paths.LogDirectory)    { Initialize-PimLog -Path $Paths.LogDirectory | Out-Null }
    else                            { Initialize-PimLog | Out-Null }

    $groups = New-Object System.Collections.Generic.List[object]
    $tenantStatus = New-Object System.Collections.Generic.List[object]

    $Shared.Total = $Tenants.Count
    $index = 0

    foreach ($tenant in $Tenants) {
        if ($Shared.CancelRequested) {
            Write-Warning 'Cancelled before all tenants were processed.'
            break
        }

        $index++
        $Shared.Completed = $index - 1
        $Shared.PercentComplete = [int](100 * ($index - 1) / [Math]::Max(1, $Tenants.Count))
        $Shared.Status = "Connecting to $($tenant.TenantDisplayName) ($index of $($Tenants.Count))..."
        Write-Information "Connecting to $($tenant.TenantDisplayName) [$($tenant.TenantId)]..."

        $connection = Connect-PimGraphTenant -TenantId $tenant.TenantId -CloudConfiguration $CloudConfiguration -UseDeviceAuthentication:([bool]$UseDeviceCode)

        if (-not $connection.Success) {
            Write-Warning "$($tenant.TenantDisplayName): $($connection.Message)"
            $tenantStatus.Add([pscustomobject]@{
                TenantId          = $tenant.TenantId
                TenantDisplayName = $tenant.TenantDisplayName
                Success           = $false
                Message           = $connection.Message
                GroupCount        = 0
            })
            continue
        }

        if (-not $connection.HasGroupRead) {
            Write-Warning "$($tenant.TenantDisplayName): $($connection.Message)"
        }

        try {
            $Shared.Status = "Reading eligible groups in $($tenant.TenantDisplayName)..."

            # The connection result carries no principal ID; resolve it per tenant,
            # because the guest object ID differs in every directory.
            $me = Get-CurrentGraphUser -GraphBaseUri $CloudConfiguration.GraphBaseUri

            $eligible = Get-PimEligibleGroups `
                -TenantId $tenant.TenantId `
                -PrincipalId $me.Id `
                -GraphBaseUri $CloudConfiguration.GraphBaseUri `
                -TenantDisplayName $tenant.TenantDisplayName `
                -SkipGroupNameResolution:(-not $connection.HasGroupRead)

            foreach ($item in $eligible) { $groups.Add($item) }

            Write-Information "$($tenant.TenantDisplayName): $($eligible.Count) eligible group assignment(s)."
            $tenantStatus.Add([pscustomobject]@{
                TenantId          = $tenant.TenantId
                TenantDisplayName = $tenant.TenantDisplayName
                Success           = $true
                Message           = "$($eligible.Count) eligible group assignment(s)."
                GroupCount        = $eligible.Count
            })
        }
        catch {
            Write-Warning "$($tenant.TenantDisplayName): $($_.Exception.Message)"
            $tenantStatus.Add([pscustomobject]@{
                TenantId          = $tenant.TenantId
                TenantDisplayName = $tenant.TenantDisplayName
                Success           = $false
                Message           = $_.Exception.Message
                GroupCount        = 0
            })
        }
        finally {
            Disconnect-PimGraph | Out-Null
        }
    }

    $Shared.PercentComplete = 100
    $Shared.Status = "Found $($groups.Count) eligible group assignment(s)."

    [pscustomobject]@{
        Kind         = 'LoadGroups'
        Groups       = $groups.ToArray()
        TenantStatus = $tenantStatus.ToArray()
        Cancelled    = [bool]$Shared.CancelRequested
    }
}

$script:SubmitWorker = {
    param(
        [hashtable] $Paths,
        [object]    $CloudConfiguration,
        [object[]]  $Groups,
        [string]    $Justification,
        [timespan]  $Duration,
        [bool]      $StopOnFirstFailure,
        [string]    $TicketNumber,
        [string]    $TicketSystem,
        [bool]      $UseDeviceCode,
        [hashtable] $Shared
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $InformationPreference = 'Continue'

    Import-Module $Paths.Models  -Force -DisableNameChecking
    Import-Module $Paths.Logging -Force -DisableNameChecking
    Import-Module $Paths.Graph   -Force -DisableNameChecking

    if (-not $Paths.LoggingEnabled) { Initialize-PimLog -Disable | Out-Null }
    elseif ($Paths.LogDirectory)    { Initialize-PimLog -Path $Paths.LogDirectory | Out-Null }
    else                            { Initialize-PimLog | Out-Null }

    $results = New-Object System.Collections.Generic.List[object]
    $Shared.Total = $Groups.Count

    # Group by tenant so each tenant is connected once.
    $byTenant = $Groups | Group-Object -Property TenantId
    $index = 0
    $stop = $false

    foreach ($tenantGroup in $byTenant) {
        if ($stop -or $Shared.CancelRequested) { break }

        $tenantId = $tenantGroup.Name
        $tenantName = $tenantGroup.Group[0].TenantDisplayName
        $Shared.Status = "Connecting to $tenantName..."
        Write-Information "Connecting to $tenantName [$tenantId]..."

        $connection = Connect-PimGraphTenant -TenantId $tenantId -CloudConfiguration $CloudConfiguration -UseDeviceAuthentication:([bool]$UseDeviceCode)

        if (-not $connection.Success) {
            Write-Warning "$tenantName`: $($connection.Message)"
            foreach ($item in $tenantGroup.Group) {
                $index++
                $Shared.Completed = $index
                $results.Add((New-PimActivationResultRecord `
                    -TenantId $tenantId `
                    -TenantDisplayName $tenantName `
                    -GroupId $item.GroupId `
                    -GroupDisplayName $item.GroupDisplayName `
                    -AccessId $item.AccessId `
                    -Status 'Skipped' `
                    -Message $connection.Message))
            }
            if ($StopOnFirstFailure) { $stop = $true }
            continue
        }

        try {
            # The connection result carries no principal ID, and the guest object ID
            # differs in every directory, so resolve it once per tenant.
            $me = Get-CurrentGraphUser -GraphBaseUri $CloudConfiguration.GraphBaseUri

            foreach ($item in $tenantGroup.Group) {
                if ($Shared.CancelRequested) {
                    $results.Add((New-PimActivationResultRecord `
                        -TenantId $tenantId `
                        -TenantDisplayName $tenantName `
                        -GroupId $item.GroupId `
                        -GroupDisplayName $item.GroupDisplayName `
                        -AccessId $item.AccessId `
                        -Status 'Skipped' `
                        -Message 'Cancelled by the user.'))
                    continue
                }

                $index++
                $Shared.Completed = $index
                $Shared.PercentComplete = [int](100 * $index / [Math]::Max(1, $Groups.Count))
                $Shared.Status = "Activating $($item.GroupDisplayName) ($index of $($Groups.Count))..."

                $result = Request-PimGroupActivation `
                    -TenantId $tenantId `
                    -TenantDisplayName $tenantName `
                    -GroupId $item.GroupId `
                    -GroupDisplayName $item.GroupDisplayName `
                    -PrincipalId $(if ($item.PrincipalId) { $item.PrincipalId } else { $me.Id }) `
                    -AccessId $item.AccessId `
                    -Justification $Justification `
                    -Duration $Duration `
                    -GraphBaseUri $CloudConfiguration.GraphBaseUri `
                    -TicketNumber $TicketNumber `
                    -TicketSystem $TicketSystem

                $results.Add($result)

                if ($result.Status -eq 'Success') {
                    Write-Information "$($item.GroupDisplayName): $($result.Message)"
                }
                else {
                    Write-Warning "$($item.GroupDisplayName): $($result.Message)"
                    if ($StopOnFirstFailure) {
                        $stop = $true
                        break
                    }
                }
            }
        }
        finally {
            Disconnect-PimGraph | Out-Null
        }
    }

    # Anything never attempted is reported rather than silently dropped.
    $attempted = @{}
    foreach ($result in $results) { $attempted["$($result.TenantId)|$($result.GroupId)|$($result.AccessId)"] = $true }
    foreach ($item in $Groups) {
        $key = "$($item.TenantId)|$($item.GroupId)|$($item.AccessId)"
        if (-not $attempted.ContainsKey($key)) {
            $reason = if ($Shared.CancelRequested) { 'Cancelled by the user.' } else { 'Skipped after an earlier failure.' }
            $results.Add((New-PimActivationResultRecord `
                -TenantId $item.TenantId `
                -TenantDisplayName $item.TenantDisplayName `
                -GroupId $item.GroupId `
                -GroupDisplayName $item.GroupDisplayName `
                -AccessId $item.AccessId `
                -Status 'Skipped' `
                -Message $reason))
        }
    }

    $Shared.PercentComplete = 100
    $Shared.Status = 'Finished.'

    [pscustomobject]@{
        Kind      = 'Submit'
        Results   = $results.ToArray()
        Cancelled = [bool]$Shared.CancelRequested
    }
}

#endregion

#region Grid helpers

function Add-PimGridTextColumn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Grid,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $HeaderText,
        [Parameter()] [int] $Width = 140,
        [Parameter()] [switch] $Fill
    )

    $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $column.Name = $Name
    $column.HeaderText = $HeaderText
    $column.ReadOnly = $true
    $column.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::Automatic
    if ($Fill) {
        $column.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
        $column.FillWeight = $Width
    }
    else {
        $column.Width = $Width
    }
    $null = $Grid.Columns.Add($column)
    return $column
}

function Add-PimGridCheckBoxColumn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Grid,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $HeaderText,
        [Parameter()] [int] $Width = 60
    )

    $column = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $column.Name = $Name
    $column.HeaderText = $HeaderText
    $column.Width = $Width
    $column.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::Automatic
    $null = $Grid.Columns.Add($column)
    return $column
}

function New-PimDataGridView {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name
    )

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Name = $Name
    $grid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $grid.AutoGenerateColumns = $false
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.MultiSelect = $true
    $grid.EditMode = [System.Windows.Forms.DataGridViewEditMode]::EditOnEnter
    $grid.BackgroundColor = [System.Drawing.SystemColors]::Window
    $grid.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $grid.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::AutoSize

    return $grid
}

function Get-PimCheckedRowTag {
    <#
    .SYNOPSIS
        Returns the record attached to every checked row of a grid.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [object] $Grid,
        [Parameter()] [string] $CheckBoxColumnName = 'Selected'
    )

    $selected = New-Object System.Collections.Generic.List[object]
    foreach ($row in $Grid.Rows) {
        $cell = $row.Cells[$CheckBoxColumnName]
        if ($null -ne $cell -and $cell.Value -eq $true -and $null -ne $row.Tag) {
            $selected.Add($row.Tag)
        }
    }

    return , ([object[]]$selected.ToArray())
}

function Set-PimAllRowChecked {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Grid,
        [Parameter(Mandatory)] [bool] $Checked,
        [Parameter()] [string] $CheckBoxColumnName = 'Selected'
    )

    foreach ($row in $Grid.Rows) {
        $cell = $row.Cells[$CheckBoxColumnName]
        if ($null -ne $cell) { $cell.Value = $Checked }
    }
}

#endregion

#region Export

function Export-PimResultCsv {
    <#
    .SYNOPSIS
        Writes activation results to a CSV file.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Result,

        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not $PSCmdlet.ShouldProcess($Path, 'Write activation results')) { return }

    $rows = foreach ($item in $Result) {
        # Display names come from foreign tenants, so every text cell is neutralized
        # against spreadsheet formula injection before it reaches the file.
        [pscustomobject]@{
            TenantDisplayName = ConvertTo-PimSafeCsvValue -Value $item.TenantDisplayName
            TenantId          = ConvertTo-PimSafeCsvValue -Value $item.TenantId
            GroupDisplayName  = ConvertTo-PimSafeCsvValue -Value $item.GroupDisplayName
            GroupId           = ConvertTo-PimSafeCsvValue -Value $item.GroupId
            AccessId          = ConvertTo-PimSafeCsvValue -Value $item.AccessId
            Status            = ConvertTo-PimSafeCsvValue -Value $item.Status
            Message           = ConvertTo-PimSafeCsvValue -Value $item.Message
            RequestId         = ConvertTo-PimSafeCsvValue -Value $item.RequestId
            SubmittedAt       = (Get-PimPropertyValue -InputObject $item -Name 'Timestamp')
            Detail            = ConvertTo-PimSafeCsvValue -Value (Get-PimPropertyValue -InputObject $item -Name 'Detail')
        }
    }

    $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

#endregion

function Show-PimMainForm {
    <#
    .SYNOPSIS
        Builds and shows the PIM Group Activation window.

    .PARAMETER NoShow
        Build the form and return it without entering the message loop. Used by smoke
        tests so the layout can be validated headlessly.
    #>
    [CmdletBinding()]
    [OutputType([System.Windows.Forms.Form])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $LogDirectory,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $CloudName,

        [Parameter()]
        [switch] $NoShow
    )

    [System.Windows.Forms.Application]::EnableVisualStyles()

    # Workers run in fresh runspaces, so the host's logging choice has to travel with
    # them or -NoLog and a custom -LogPath would be silently ignored.
    $hostLogState = Get-PimLogState

    $paths = @{
        Models         = (Join-Path -Path $script:ModuleRoot -ChildPath 'PimModels.psm1')
        Logging        = (Join-Path -Path $script:ModuleRoot -ChildPath 'PimLogging.psm1')
        Graph          = (Join-Path -Path $script:ModuleRoot -ChildPath 'PimGraph.psm1')
        LogDirectory   = if ([string]::IsNullOrWhiteSpace($LogDirectory)) { $hostLogState.Directory } else { $LogDirectory }
        LoggingEnabled = [bool]$hostLogState.Enabled
    }

    # ---- Mutable UI state -------------------------------------------------------
    $ui = [pscustomobject]@{
        State        = 'SignedOut'
        Account      = $null
        Cloud        = $null
        Operation    = $null
        Results      = @()
        Groups       = @()
        Form         = $null
    }

    # ---- Form -------------------------------------------------------------------
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'PIM Group Activation'
    $form.Size = New-Object System.Drawing.Size(1200, 800)
    $form.MinimumSize = New-Object System.Drawing.Size(900, 600)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $ui.Form = $form

    # ---- Sign-in panel ----------------------------------------------------------
    $panelTop = New-Object System.Windows.Forms.Panel
    $panelTop.Dock = [System.Windows.Forms.DockStyle]::Top
    $panelTop.Height = 76
    $panelTop.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)

    $labelCloud = New-Object System.Windows.Forms.Label
    $labelCloud.Text = 'Cloud:'
    $labelCloud.AutoSize = $true
    $labelCloud.Location = New-Object System.Drawing.Point(12, 14)

    $comboCloud = New-Object System.Windows.Forms.ComboBox
    $comboCloud.Name = 'comboCloud'
    $comboCloud.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $comboCloud.Location = New-Object System.Drawing.Point(60, 10)
    $comboCloud.Width = 220
    # Built-ins first, then any custom Az environment registered on this machine.
    $availableClouds = Get-PimAvailableCloudConfiguration
    foreach ($cloud in $availableClouds) {
        $null = $comboCloud.Items.Add($cloud.DisplayName)
    }
    $comboCloud.SelectedIndex = 0
    if (-not [string]::IsNullOrWhiteSpace($CloudName)) {
        for ($i = 0; $i -lt $availableClouds.Count; $i++) {
            $candidate = $availableClouds[$i]
            if ($candidate.DisplayName -eq $CloudName -or $candidate.AzEnvironment -eq $CloudName) {
                $comboCloud.SelectedIndex = $i
                break
            }
        }
    }
    $ui.Cloud = $availableClouds[$comboCloud.SelectedIndex]

    $checkDeviceCode = New-Object System.Windows.Forms.CheckBox
    $checkDeviceCode.Name = 'checkDeviceCode'
    $checkDeviceCode.Text = 'Use device code sign-in'
    $checkDeviceCode.AutoSize = $true
    $checkDeviceCode.Location = New-Object System.Drawing.Point(296, 13)

    $buttonSignIn = New-Object System.Windows.Forms.Button
    $buttonSignIn.Name = 'buttonSignIn'
    $buttonSignIn.Text = 'Sign in and Discover Tenants'
    $buttonSignIn.Location = New-Object System.Drawing.Point(480, 8)
    $buttonSignIn.Size = New-Object System.Drawing.Size(200, 28)

    $buttonSwitchAccount = New-Object System.Windows.Forms.Button
    $buttonSwitchAccount.Name = 'buttonSwitchAccount'
    $buttonSwitchAccount.Text = 'Sign in with a different account'
    $buttonSwitchAccount.Location = New-Object System.Drawing.Point(688, 8)
    $buttonSwitchAccount.Size = New-Object System.Drawing.Size(210, 28)

    $labelAccount = New-Object System.Windows.Forms.Label
    $labelAccount.Name = 'labelAccount'
    $labelAccount.Text = 'Not signed in.'
    $labelAccount.AutoSize = $true
    $labelAccount.Location = New-Object System.Drawing.Point(12, 46)

    $panelTop.Controls.AddRange(@($labelCloud, $comboCloud, $checkDeviceCode, $buttonSignIn, $buttonSwitchAccount, $labelAccount))

    # ---- Results / log panel ----------------------------------------------------
    $panelResults = New-Object System.Windows.Forms.Panel
    $panelResults.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $panelResults.Height = 230
    $panelResults.Padding = New-Object System.Windows.Forms.Padding(10, 0, 10, 10)

    $splitResults = New-Object System.Windows.Forms.SplitContainer
    $splitResults.Dock = [System.Windows.Forms.DockStyle]::Fill
    $splitResults.Orientation = [System.Windows.Forms.Orientation]::Vertical
    $splitResults.SplitterDistance = 760

    $gridResults = New-PimDataGridView -Name 'gridResults'
    $gridResults.ReadOnly = $true
    $null = Add-PimGridTextColumn -Grid $gridResults -Name 'Tenant'  -HeaderText 'Tenant'      -Width 20 -Fill
    $null = Add-PimGridTextColumn -Grid $gridResults -Name 'Group'   -HeaderText 'Group'       -Width 24 -Fill
    $null = Add-PimGridTextColumn -Grid $gridResults -Name 'Access'  -HeaderText 'Access'      -Width 8  -Fill
    $null = Add-PimGridTextColumn -Grid $gridResults -Name 'Status'  -HeaderText 'Status'      -Width 10 -Fill
    $null = Add-PimGridTextColumn -Grid $gridResults -Name 'Message' -HeaderText 'Message'     -Width 30 -Fill
    $null = Add-PimGridTextColumn -Grid $gridResults -Name 'RequestId' -HeaderText 'Request ID' -Width 18 -Fill

    $groupResults = New-Object System.Windows.Forms.GroupBox
    $groupResults.Text = 'Results'
    $groupResults.Dock = [System.Windows.Forms.DockStyle]::Fill
    $groupResults.Controls.Add($gridResults)

    $textLog = New-Object System.Windows.Forms.TextBox
    $textLog.Name = 'textLog'
    $textLog.Multiline = $true
    $textLog.ReadOnly = $true
    $textLog.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $textLog.Dock = [System.Windows.Forms.DockStyle]::Fill
    $textLog.WordWrap = $false
    $textLog.Font = New-Object System.Drawing.Font('Consolas', 8.25)

    $groupLog = New-Object System.Windows.Forms.GroupBox
    $groupLog.Text = 'Activity'
    $groupLog.Dock = [System.Windows.Forms.DockStyle]::Fill
    $groupLog.Controls.Add($textLog)

    $splitResults.Panel1.Controls.Add($groupResults)
    $splitResults.Panel2.Controls.Add($groupLog)
    $panelResults.Controls.Add($splitResults)

    # ---- Request settings / action panel ----------------------------------------
    $panelSettings = New-Object System.Windows.Forms.Panel
    $panelSettings.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $panelSettings.Height = 150
    $panelSettings.Padding = New-Object System.Windows.Forms.Padding(10, 4, 10, 4)

    $labelJustification = New-Object System.Windows.Forms.Label
    $labelJustification.Text = 'Justification:'
    $labelJustification.AutoSize = $true
    $labelJustification.Location = New-Object System.Drawing.Point(12, 10)

    $textJustification = New-Object System.Windows.Forms.TextBox
    $textJustification.Name = 'textJustification'
    $textJustification.Multiline = $true
    $textJustification.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $textJustification.Location = New-Object System.Drawing.Point(100, 8)
    $textJustification.Size = New-Object System.Drawing.Size(520, 60)
    $textJustification.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

    $labelDuration = New-Object System.Windows.Forms.Label
    $labelDuration.Text = 'Duration:'
    $labelDuration.AutoSize = $true
    $labelDuration.Location = New-Object System.Drawing.Point(640, 10)
    $labelDuration.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

    $comboDuration = New-Object System.Windows.Forms.ComboBox
    $comboDuration.Name = 'comboDuration'
    $comboDuration.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $comboDuration.Location = New-Object System.Drawing.Point(710, 7)
    $comboDuration.Width = 140
    $comboDuration.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $durationOptions = @(Get-PimDurationOption)
    foreach ($option in $durationOptions) { $null = $comboDuration.Items.Add($option.DisplayName) }
    $comboDuration.SelectedIndex = [Math]::Min(2, $durationOptions.Count - 1)

    $labelTicketNumber = New-Object System.Windows.Forms.Label
    $labelTicketNumber.Text = 'Ticket number:'
    $labelTicketNumber.AutoSize = $true
    $labelTicketNumber.Location = New-Object System.Drawing.Point(640, 40)
    $labelTicketNumber.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

    $textTicketNumber = New-Object System.Windows.Forms.TextBox
    $textTicketNumber.Name = 'textTicketNumber'
    $textTicketNumber.Location = New-Object System.Drawing.Point(740, 37)
    $textTicketNumber.Width = 110
    $textTicketNumber.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

    $labelTicketSystem = New-Object System.Windows.Forms.Label
    $labelTicketSystem.Text = 'Ticket system:'
    $labelTicketSystem.AutoSize = $true
    $labelTicketSystem.Location = New-Object System.Drawing.Point(640, 68)
    $labelTicketSystem.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

    $textTicketSystem = New-Object System.Windows.Forms.TextBox
    $textTicketSystem.Name = 'textTicketSystem'
    $textTicketSystem.Location = New-Object System.Drawing.Point(740, 65)
    $textTicketSystem.Width = 110
    $textTicketSystem.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

    $checkStopOnFailure = New-Object System.Windows.Forms.CheckBox
    $checkStopOnFailure.Name = 'checkStopOnFailure'
    $checkStopOnFailure.Text = 'Stop on first failure'
    $checkStopOnFailure.AutoSize = $true
    $checkStopOnFailure.Location = New-Object System.Drawing.Point(100, 74)

    $buttonSubmit = New-Object System.Windows.Forms.Button
    $buttonSubmit.Name = 'buttonSubmit'
    $buttonSubmit.Text = 'Submit Activation Requests'
    $buttonSubmit.Location = New-Object System.Drawing.Point(880, 7)
    $buttonSubmit.Size = New-Object System.Drawing.Size(200, 30)
    $buttonSubmit.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

    $buttonCancel = New-Object System.Windows.Forms.Button
    $buttonCancel.Name = 'buttonCancel'
    $buttonCancel.Text = 'Cancel'
    $buttonCancel.Location = New-Object System.Drawing.Point(880, 41)
    $buttonCancel.Size = New-Object System.Drawing.Size(96, 28)
    $buttonCancel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

    $buttonExport = New-Object System.Windows.Forms.Button
    $buttonExport.Name = 'buttonExport'
    $buttonExport.Text = 'Export results'
    $buttonExport.Location = New-Object System.Drawing.Point(984, 41)
    $buttonExport.Size = New-Object System.Drawing.Size(96, 28)
    $buttonExport.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Name = 'progressBar'
    $progressBar.Location = New-Object System.Drawing.Point(12, 106)
    $progressBar.Size = New-Object System.Drawing.Size(1068, 16)
    $progressBar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

    $labelStatus = New-Object System.Windows.Forms.Label
    $labelStatus.Name = 'labelStatus'
    $labelStatus.Text = 'Choose a cloud and sign in.'
    $labelStatus.AutoSize = $false
    $labelStatus.Location = New-Object System.Drawing.Point(12, 126)
    $labelStatus.Size = New-Object System.Drawing.Size(1068, 18)
    $labelStatus.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

    $panelSettings.Controls.AddRange(@(
        $labelJustification, $textJustification,
        $labelDuration, $comboDuration,
        $labelTicketNumber, $textTicketNumber,
        $labelTicketSystem, $textTicketSystem,
        $checkStopOnFailure,
        $buttonSubmit, $buttonCancel, $buttonExport,
        $progressBar, $labelStatus
    ))

    # ---- Tenant and group grids -------------------------------------------------
    $splitMain = New-Object System.Windows.Forms.SplitContainer
    $splitMain.Dock = [System.Windows.Forms.DockStyle]::Fill
    $splitMain.Orientation = [System.Windows.Forms.Orientation]::Horizontal
    $splitMain.SplitterDistance = 180

    $gridTenants = New-PimDataGridView -Name 'gridTenants'
    $null = Add-PimGridCheckBoxColumn -Grid $gridTenants -Name 'Selected' -HeaderText ''
    $null = Add-PimGridTextColumn -Grid $gridTenants -Name 'TenantName'   -HeaderText 'Tenant'         -Width 30 -Fill
    $null = Add-PimGridTextColumn -Grid $gridTenants -Name 'PrimaryDomain' -HeaderText 'Primary domain' -Width 25 -Fill
    $null = Add-PimGridTextColumn -Grid $gridTenants -Name 'TenantId'     -HeaderText 'Tenant ID'      -Width 28 -Fill
    $null = Add-PimGridTextColumn -Grid $gridTenants -Name 'Category'     -HeaderText 'Category'       -Width 15 -Fill

    $panelTenantActions = New-Object System.Windows.Forms.Panel
    $panelTenantActions.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $panelTenantActions.Height = 34

    $buttonLoadGroups = New-Object System.Windows.Forms.Button
    $buttonLoadGroups.Name = 'buttonLoadGroups'
    $buttonLoadGroups.Text = 'Load Eligible Groups'
    $buttonLoadGroups.Location = New-Object System.Drawing.Point(0, 3)
    $buttonLoadGroups.Size = New-Object System.Drawing.Size(160, 26)

    $buttonSelectAllTenants = New-Object System.Windows.Forms.Button
    $buttonSelectAllTenants.Name = 'buttonSelectAllTenants'
    $buttonSelectAllTenants.Text = 'Select all'
    $buttonSelectAllTenants.Location = New-Object System.Drawing.Point(168, 3)
    $buttonSelectAllTenants.Size = New-Object System.Drawing.Size(80, 26)

    $buttonClearTenants = New-Object System.Windows.Forms.Button
    $buttonClearTenants.Name = 'buttonClearTenants'
    $buttonClearTenants.Text = 'Clear'
    $buttonClearTenants.Location = New-Object System.Drawing.Point(256, 3)
    $buttonClearTenants.Size = New-Object System.Drawing.Size(80, 26)

    $panelTenantActions.Controls.AddRange(@($buttonLoadGroups, $buttonSelectAllTenants, $buttonClearTenants))

    $groupTenants = New-Object System.Windows.Forms.GroupBox
    $groupTenants.Text = 'Tenants'
    $groupTenants.Dock = [System.Windows.Forms.DockStyle]::Fill
    $groupTenants.Controls.Add($gridTenants)
    $groupTenants.Controls.Add($panelTenantActions)

    $gridGroups = New-PimDataGridView -Name 'gridGroups'
    $null = Add-PimGridCheckBoxColumn -Grid $gridGroups -Name 'Selected' -HeaderText ''
    $null = Add-PimGridTextColumn -Grid $gridGroups -Name 'TenantName' -HeaderText 'Tenant'      -Width 20 -Fill
    $null = Add-PimGridTextColumn -Grid $gridGroups -Name 'GroupName'  -HeaderText 'Group'       -Width 26 -Fill
    $null = Add-PimGridTextColumn -Grid $gridGroups -Name 'Access'     -HeaderText 'Access type' -Width 10 -Fill
    $null = Add-PimGridTextColumn -Grid $gridGroups -Name 'Status'     -HeaderText 'Eligibility' -Width 10 -Fill
    $null = Add-PimGridTextColumn -Grid $gridGroups -Name 'GroupId'    -HeaderText 'Group ID'    -Width 22 -Fill
    $null = Add-PimGridTextColumn -Grid $gridGroups -Name 'TenantId'   -HeaderText 'Tenant ID'   -Width 22 -Fill

    $panelGroupActions = New-Object System.Windows.Forms.Panel
    $panelGroupActions.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $panelGroupActions.Height = 34

    $buttonSelectAllGroups = New-Object System.Windows.Forms.Button
    $buttonSelectAllGroups.Name = 'buttonSelectAllGroups'
    $buttonSelectAllGroups.Text = 'Select all'
    $buttonSelectAllGroups.Location = New-Object System.Drawing.Point(0, 3)
    $buttonSelectAllGroups.Size = New-Object System.Drawing.Size(80, 26)

    $buttonClearGroups = New-Object System.Windows.Forms.Button
    $buttonClearGroups.Name = 'buttonClearGroups'
    $buttonClearGroups.Text = 'Clear'
    $buttonClearGroups.Location = New-Object System.Drawing.Point(88, 3)
    $buttonClearGroups.Size = New-Object System.Drawing.Size(80, 26)

    $panelGroupActions.Controls.AddRange(@($buttonSelectAllGroups, $buttonClearGroups))

    $groupGroups = New-Object System.Windows.Forms.GroupBox
    $groupGroups.Text = 'Eligible groups'
    $groupGroups.Dock = [System.Windows.Forms.DockStyle]::Fill
    $groupGroups.Controls.Add($gridGroups)
    $groupGroups.Controls.Add($panelGroupActions)

    $splitMain.Panel1.Controls.Add($groupTenants)
    $splitMain.Panel2.Controls.Add($groupGroups)

    # Fill must be added last so the docked panels claim their space first.
    $form.Controls.Add($splitMain)
    $form.Controls.Add($panelSettings)
    $form.Controls.Add($panelResults)
    $form.Controls.Add($panelTop)

    # ---- UI helpers -------------------------------------------------------------
    $appendLog = {
        param([string] $Text, [string] $Level = 'Information')

        if ([string]::IsNullOrWhiteSpace($Text)) { return }
        $safe = Remove-PimSensitiveData -Text $Text
        $stamp = '{0:HH:mm:ss}' -f (Get-Date)
        $prefix = switch ($Level) {
            'Warning' { 'WARN ' }
            'Error'   { 'ERROR' }
            default   { 'INFO ' }
        }
        $textLog.AppendText("[$stamp] $prefix $safe" + [Environment]::NewLine)
    }

    $getSelectedDuration = {
        $options = @(Get-PimDurationOption)
        if ($comboDuration.SelectedIndex -lt 0) { return $null }
        return $options[$comboDuration.SelectedIndex].TimeSpan
    }

    $applyState = {
        $selectedTenants = Get-PimCheckedRowTag -Grid $gridTenants
        $selectedGroups  = Get-PimCheckedRowTag -Grid $gridGroups
        $duration = & $getSelectedDuration

        $controlState = Get-PimUiControlState `
            -State $ui.State `
            -SelectedTenantCount $selectedTenants.Count `
            -SelectedGroupCount $selectedGroups.Count `
            -ResultCount @($ui.Results).Count `
            -Justification $textJustification.Text `
            -Duration $duration

        $comboCloud.Enabled             = $controlState.CloudSelectionEnabled
        $checkDeviceCode.Enabled        = $controlState.CloudSelectionEnabled
        $buttonSignIn.Enabled           = $controlState.SignInEnabled
        $buttonSwitchAccount.Enabled    = $controlState.SwitchAccountEnabled
        $gridTenants.Enabled            = $controlState.TenantGridEnabled
        $buttonSelectAllTenants.Enabled = $controlState.TenantGridEnabled
        $buttonClearTenants.Enabled     = $controlState.TenantGridEnabled
        $buttonLoadGroups.Enabled       = $controlState.LoadGroupsEnabled
        $gridGroups.Enabled             = $controlState.GroupGridEnabled
        $buttonSelectAllGroups.Enabled  = $controlState.GroupGridEnabled
        $buttonClearGroups.Enabled      = $controlState.GroupGridEnabled
        $textJustification.Enabled      = $controlState.RequestSettingsEnabled
        $comboDuration.Enabled          = $controlState.RequestSettingsEnabled
        $textTicketNumber.Enabled       = $controlState.RequestSettingsEnabled
        $textTicketSystem.Enabled       = $controlState.RequestSettingsEnabled
        $checkStopOnFailure.Enabled     = $controlState.RequestSettingsEnabled
        $buttonSubmit.Enabled           = $controlState.SubmitEnabled
        $buttonCancel.Enabled           = $controlState.CancelEnabled
        $buttonExport.Enabled           = $controlState.ExportEnabled
        $progressBar.Visible            = $controlState.ProgressVisible

        if (-not $controlState.SubmitEnabled -and $controlState.SubmitBlockedReasons.Count -gt 0) {
            $buttonSubmit.Text = 'Submit Activation Requests'
        }
    }

    $setState = {
        param([string] $NewState)

        if ($ui.State -ne $NewState -and -not (Test-PimUiStateTransition -From $ui.State -To $NewState)) {
            & $appendLog "Ignoring an invalid UI transition from $($ui.State) to $NewState." 'Warning'
            return
        }

        $ui.State = $NewState
        & $applyState
    }

    $clearGrid = {
        param([object] $Grid)
        $Grid.Rows.Clear()
    }

    $resetFor = {
        param([string] $Change)

        $scope = Get-PimResetScope -Change $Change
        if ($scope.ClearTenants) {
            & $clearGrid $gridTenants
            $ui.Account = $null
            $labelAccount.Text = 'Not signed in.'
        }
        if ($scope.ClearGroups)  { & $clearGrid $gridGroups; $ui.Groups = @() }
        if ($scope.ClearResults) { & $clearGrid $gridResults; $ui.Results = @() }

        $ui.State = $scope.ResetState
        & $applyState
    }

    # ---- Worker polling ---------------------------------------------------------
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 200

    $onSignInComplete = {
        param([object] $Completion)

        if (-not $Completion.Success) {
            $formatted = Format-PimGraphError -ErrorObject $Completion.Failure -Context 'Sign-in failed.'
            & $appendLog $formatted.FriendlyMessage 'Error'
            $labelStatus.Text = $formatted.FriendlyMessage
            & $setState 'SignedOut'
            [System.Windows.Forms.MessageBox]::Show($form, $formatted.FriendlyMessage, 'Sign-in failed', 'OK', 'Error') | Out-Null
            return
        }

        $payload = @($Completion.Output) | Where-Object { $null -ne $_ -and $_.PSObject.Properties['Kind'] -and $_.Kind -eq 'SignIn' } | Select-Object -First 1
        if ($null -eq $payload) {
            & $appendLog 'Sign-in returned no result.' 'Error'
            & $setState 'SignedOut'
            return
        }

        $ui.Account = $payload.Account
        $labelAccount.Text = "Signed in as $($payload.Account) ($($ui.Cloud.DisplayName))."

        $gridTenants.Rows.Clear()
        foreach ($tenant in @($payload.Tenants)) {
            # Selection must be deliberate, so nothing is pre-checked.
            $index = $gridTenants.Rows.Add($false, $tenant.TenantDisplayName, $tenant.PrimaryDomain, $tenant.TenantId, $tenant.Category)
            $gridTenants.Rows[$index].Tag = $tenant
        }

        $labelStatus.Text = "Found $(@($payload.Tenants).Count) tenant(s). Select tenants, then load eligible groups."
        & $appendLog $labelStatus.Text
        & $setState 'TenantsReady'
    }

    $onLoadGroupsComplete = {
        param([object] $Completion)

        if (-not $Completion.Success) {
            $formatted = Format-PimGraphError -ErrorObject $Completion.Failure -Context 'Loading eligible groups failed.'
            & $appendLog $formatted.FriendlyMessage 'Error'
            $labelStatus.Text = $formatted.FriendlyMessage
            & $setState 'TenantsReady'
            return
        }

        $payload = @($Completion.Output) | Where-Object { $null -ne $_ -and $_.PSObject.Properties['Kind'] -and $_.Kind -eq 'LoadGroups' } | Select-Object -First 1
        if ($null -eq $payload) {
            & $appendLog 'Loading eligible groups returned no result.' 'Error'
            & $setState 'TenantsReady'
            return
        }

        $ui.Groups = @($payload.Groups)
        $gridGroups.Rows.Clear()
        foreach ($group in $ui.Groups) {
            $index = $gridGroups.Rows.Add($false, $group.TenantDisplayName, $group.GroupDisplayName, $group.AccessId, $group.Status, $group.GroupId, $group.TenantId)
            $gridGroups.Rows[$index].Tag = $group
        }

        foreach ($status in @($payload.TenantStatus)) {
            $level = if ($status.Success) { 'Information' } else { 'Warning' }
            & $appendLog "$($status.TenantDisplayName): $($status.Message)" $level
        }

        if ($ui.Groups.Count -eq 0) {
            $labelStatus.Text = 'No eligible PIM for Groups assignments were found in the selected tenants.'
        }
        else {
            $labelStatus.Text = "Found $($ui.Groups.Count) eligible group assignment(s). Select groups, enter a justification, then submit."
        }
        & $appendLog $labelStatus.Text
        & $setState 'GroupsReady'
    }

    $onSubmitComplete = {
        param([object] $Completion)

        if (-not $Completion.Success) {
            $formatted = Format-PimGraphError -ErrorObject $Completion.Failure -Context 'Submitting activation requests failed.'
            & $appendLog $formatted.FriendlyMessage 'Error'
            $labelStatus.Text = $formatted.FriendlyMessage
            & $setState 'GroupsReady'
            return
        }

        $payload = @($Completion.Output) | Where-Object { $null -ne $_ -and $_.PSObject.Properties['Kind'] -and $_.Kind -eq 'Submit' } | Select-Object -First 1
        if ($null -eq $payload) {
            & $appendLog 'Submission returned no result.' 'Error'
            & $setState 'GroupsReady'
            return
        }

        $ui.Results = @($payload.Results)
        $gridResults.Rows.Clear()
        foreach ($result in $ui.Results) {
            $index = $gridResults.Rows.Add($result.TenantDisplayName, $result.GroupDisplayName, $result.AccessId, $result.Status, $result.Message, $result.RequestId)
            $row = $gridResults.Rows[$index]
            $row.Tag = $result
            switch ($result.Status) {
                'Success' { $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(223, 246, 221) }
                'Failed'    { $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(253, 224, 222) }
                default     { $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(250, 243, 215) }
            }
        }

        $succeeded = @($ui.Results | Where-Object { $_.Status -eq 'Success' }).Count
        $failed    = @($ui.Results | Where-Object { $_.Status -eq 'Failed' }).Count
        $skipped   = @($ui.Results | Where-Object { $_.Status -eq 'Skipped' }).Count

        $labelStatus.Text = "Finished: $succeeded succeeded, $failed failed, $skipped skipped."
        & $appendLog $labelStatus.Text
        & $setState 'Completed'
    }

    $timer.Add_Tick({
        $operation = $ui.Operation
        if ($null -eq $operation) {
            $timer.Stop()
            return
        }

        foreach ($line in (Get-PimAsyncStreamText -Operation $operation)) {
            & $appendLog $line.Text $line.Level
        }

        $shared = $operation.Shared
        if ($shared.Status) { $labelStatus.Text = [string]$shared.Status }
        $percent = [int]$shared.PercentComplete
        if ($percent -ge 0 -and $percent -le 100) { $progressBar.Value = $percent }

        if (-not $operation.Handle.IsCompleted) { return }

        $timer.Stop()
        $ui.Operation = $null

        $completion = Complete-PimAsyncOperation -Operation $operation

        switch ($completion.Name) {
            'SignIn'     { & $onSignInComplete $completion }
            'LoadGroups' { & $onLoadGroupsComplete $completion }
            'Submit'     { & $onSubmitComplete $completion }
        }

        $progressBar.Value = 0
    })

    $startOperation = {
        param([string] $Name, [scriptblock] $Script, [hashtable] $Parameters, [string] $BusyState)

        if ($null -ne $ui.Operation) {
            & $appendLog 'Another operation is already running.' 'Warning'
            return
        }

        $progressBar.Value = 0
        $ui.Operation = Start-PimAsyncOperation -Name $Name -Script $Script -Parameters $Parameters
        & $setState $BusyState
        $timer.Start()
    }

    # ---- Event handlers ---------------------------------------------------------
    $comboCloud.Add_SelectedIndexChanged({
        $selected = [string]$comboCloud.SelectedItem
        $cloud = @($availableClouds | Where-Object { $_.DisplayName -eq $selected }) | Select-Object -First 1
        if ($null -eq $cloud) { $cloud = Get-PimCloudConfiguration -Name $selected }
        $ui.Cloud = $cloud

        if (-not $cloud.IsSupported) {
            & $appendLog $cloud.UnsupportedReason 'Warning'
            $labelStatus.Text = $cloud.UnsupportedReason
        }
        else {
            $labelStatus.Text = "Cloud set to $($cloud.DisplayName). Sign in to discover tenants."
        }

        & $resetFor 'Cloud'
    })

    $signIn = {
        param([bool] $ForceNewAccount)

        if (-not $ui.Cloud.IsSupported) {
            [System.Windows.Forms.MessageBox]::Show($form, $ui.Cloud.UnsupportedReason, 'Cloud not supported', 'OK', 'Warning') | Out-Null
            return
        }

        $availability = @(Test-PimModuleAvailability)
        $missing = @($availability | Where-Object { -not $_.IsAvailable })
        if ($missing.Count -gt 0) {
            $message = "These modules are required:`r`n`r`n" + (($missing | ForEach-Object { " - $($_.Name) $($_.MinimumVersion)+ ($($_.Purpose))" }) -join "`r`n") + "`r`n`r`nInstall them with:`r`n" + (($missing | ForEach-Object { "Install-Module $($_.InstallName) -Scope CurrentUser" }) -join "`r`n")
            [System.Windows.Forms.MessageBox]::Show($form, $message, 'Missing modules', 'OK', 'Warning') | Out-Null
            return
        }

        if ($ForceNewAccount) { & $resetFor 'Account' }

        & $startOperation 'SignIn' $script:SignInWorker @{
            Paths              = $paths
            CloudConfiguration = $ui.Cloud
            ForceNewAccount    = $ForceNewAccount
            UseDeviceCode      = [bool]$checkDeviceCode.Checked
        } 'DiscoveringTenants'
    }

    $buttonSignIn.Add_Click({ & $signIn $false })
    $buttonSwitchAccount.Add_Click({ & $signIn $true })

    $buttonLoadGroups.Add_Click({
        $selectedTenants = Get-PimCheckedRowTag -Grid $gridTenants
        if ($selectedTenants.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show($form, 'Select at least one tenant first.', 'No tenants selected', 'OK', 'Information') | Out-Null
            return
        }

        # Group and result rows never survive a reload.
        $gridGroups.Rows.Clear()
        $gridResults.Rows.Clear()
        $ui.Groups = @()
        $ui.Results = @()

        & $startOperation 'LoadGroups' $script:LoadGroupsWorker @{
            Paths              = $paths
            CloudConfiguration = $ui.Cloud
            Tenants            = $selectedTenants
            UseDeviceCode      = [bool]$checkDeviceCode.Checked
        } 'LoadingGroups'
    })

    $buttonSubmit.Add_Click({
        $selectedGroups = Get-PimCheckedRowTag -Grid $gridGroups
        $duration = & $getSelectedDuration

        $readiness = Get-PimSubmissionReadiness -SelectedGroupCount $selectedGroups.Count -Justification $textJustification.Text -Duration $duration
        if (-not $readiness.CanSubmit) {
            [System.Windows.Forms.MessageBox]::Show($form, ($readiness.Reasons -join "`r`n"), 'Cannot submit yet', 'OK', 'Information') | Out-Null
            return
        }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            $form,
            "Submit $($selectedGroups.Count) activation request(s) for $($duration.TotalHours) hour(s)?",
            'Confirm activation',
            'YesNo',
            'Question')
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $gridResults.Rows.Clear()
        $ui.Results = @()

        & $startOperation 'Submit' $script:SubmitWorker @{
            Paths              = $paths
            CloudConfiguration = $ui.Cloud
            Groups             = $selectedGroups
            Justification      = $textJustification.Text
            Duration           = $duration
            StopOnFirstFailure = [bool]$checkStopOnFailure.Checked
            TicketNumber       = $textTicketNumber.Text
            TicketSystem       = $textTicketSystem.Text
            UseDeviceCode      = [bool]$checkDeviceCode.Checked
        } 'Submitting'
    })

    $buttonCancel.Add_Click({
        if ($null -eq $ui.Operation) { return }
        $ui.Operation.Shared.CancelRequested = $true
        $buttonCancel.Enabled = $false
        & $appendLog 'Cancellation requested. Finishing the current request first...' 'Warning'
    })

    $buttonExport.Add_Click({
        if (@($ui.Results).Count -eq 0) { return }

        $dialog = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
        $dialog.FileName = 'PimActivationResults-{0:yyyyMMdd-HHmmss}.csv' -f (Get-Date)
        if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }

        try {
            Export-PimResultCsv -Result $ui.Results -Path $dialog.FileName
            & $appendLog "Exported $(@($ui.Results).Count) result(s) to $($dialog.FileName)."
        }
        catch {
            & $appendLog "Export failed: $($_.Exception.Message)" 'Error'
            [System.Windows.Forms.MessageBox]::Show($form, "Export failed: $($_.Exception.Message)", 'Export failed', 'OK', 'Error') | Out-Null
        }
    })

    $buttonSelectAllTenants.Add_Click({ Set-PimAllRowChecked -Grid $gridTenants -Checked $true;  & $applyState })
    $buttonClearTenants.Add_Click({    Set-PimAllRowChecked -Grid $gridTenants -Checked $false; & $applyState })
    $buttonSelectAllGroups.Add_Click({ Set-PimAllRowChecked -Grid $gridGroups  -Checked $true;  & $applyState })
    $buttonClearGroups.Add_Click({     Set-PimAllRowChecked -Grid $gridGroups  -Checked $false; & $applyState })

    # Commit checkbox edits immediately so enablement tracks the click, not the focus change.
    $commitDirtyCell = {
        param($sender, $eventArgs)
        if ($sender.IsCurrentCellDirty) {
            $sender.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    }
    $gridTenants.Add_CurrentCellDirtyStateChanged($commitDirtyCell)
    $gridGroups.Add_CurrentCellDirtyStateChanged($commitDirtyCell)

    $gridTenants.Add_CellValueChanged({
        param($sender, $eventArgs)
        if ($eventArgs.ColumnIndex -ne $gridTenants.Columns['Selected'].Index) { return }
        # Changing the tenant selection invalidates any loaded groups and results.
        if ($gridGroups.Rows.Count -gt 0 -or $gridResults.Rows.Count -gt 0) {
            $gridGroups.Rows.Clear()
            $gridResults.Rows.Clear()
            $ui.Groups = @()
            $ui.Results = @()
            if ($ui.State -in @('GroupsReady', 'Completed')) { $ui.State = 'TenantsReady' }
        }
        & $applyState
    })

    $gridGroups.Add_CellValueChanged({
        param($sender, $eventArgs)
        if ($eventArgs.ColumnIndex -ne $gridGroups.Columns['Selected'].Index) { return }
        & $applyState
    })

    $textJustification.Add_TextChanged({ & $applyState })
    $comboDuration.Add_SelectedIndexChanged({ & $applyState })

    $form.Add_FormClosing({
        param($sender, $eventArgs)

        # The confirmation dialog runs a nested message loop, which would let the timer
        # tick and clear $ui.Operation underneath us. Stop the timer and take a local
        # reference before prompting.
        $timer.Stop()
        $operation = $ui.Operation

        if ($null -ne $operation) {
            $answer = [System.Windows.Forms.MessageBox]::Show($form, 'An operation is still running. Close anyway?', 'Operation in progress', 'YesNo', 'Warning')
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
                $eventArgs.Cancel = $true
                $timer.Start()
                return
            }

            # Ask the worker to stop cooperatively first; PowerShell.Stop() blocks until
            # the pipeline yields, which an in-flight sign-in may not do promptly.
            $operation.Shared.CancelRequested = $true
            try { $operation.PowerShell.BeginStop($null, $null) | Out-Null } catch { Write-Debug "Stopping the worker failed: $($_.Exception.Message)" }
            try { $operation.PowerShell.Dispose() } catch { Write-Debug "Disposing the worker failed: $($_.Exception.Message)" }
            try { $operation.Runspace.Dispose() }  catch { Write-Debug "Disposing the runspace failed: $($_.Exception.Message)" }
            $ui.Operation = $null
        }

        $timer.Dispose()
        Set-PimLogSink -Sink $null
    })

    # Mirror module logging into the activity box.
    Set-PimLogSink -Sink { param($line, $level) & $appendLog $line $level }

    & $applyState
    & $appendLog "Ready. Logs are written to $(Get-PimLogDirectory)."

    if ($NoShow) { return $form }

    $null = $form.ShowDialog()
    $form.Dispose()
}

Export-ModuleMember -Function @(
    'Show-PimMainForm'
    'New-PimSharedState'
    'Start-PimAsyncOperation'
    'Get-PimAsyncStreamText'
    'Complete-PimAsyncOperation'
    'New-PimDataGridView'
    'Add-PimGridTextColumn'
    'Add-PimGridCheckBoxColumn'
    'Get-PimCheckedRowTag'
    'Set-PimAllRowChecked'
    'Export-PimResultCsv'
)
