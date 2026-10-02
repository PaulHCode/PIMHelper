#Requires -Version 5.1
<#
.SYNOPSIS
    Operational logging for the PIM Group Activation Tool.

.DESCRIPTION
    Writes structured, append-only log lines to %LOCALAPPDATA%\PimGroupActivationTool\logs.
    Credentials and tokens are never logged: every message is passed through
    Remove-PimSensitiveData before it is written.
#>

Set-StrictMode -Version Latest

# Remove-PimSensitiveData lives in PimModels and must be available inside this
# module's own scope, so import it as a nested module.
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'PimModels.psm1') -DisableNameChecking -ErrorAction Stop

$script:LogState = [pscustomobject]@{
    Enabled   = $true
    Directory = $null
    FilePath  = $null
    Sink      = $null   # Optional scriptblock used by the UI to mirror lines into the log box.
}

$script:LogSyncRoot = [System.Object]::new()

function Get-PimLogDirectory {
    <#
    .SYNOPSIS
        Returns the directory used for log files.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($script:LogState.Directory) { return $script:LogState.Directory }

    $root = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
    }
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = [System.IO.Path]::GetTempPath()
    }

    return (Join-Path -Path $root -ChildPath 'PimGroupActivationTool\logs')
}

function Initialize-PimLog {
    <#
    .SYNOPSIS
        Prepares the log file for this session.

    .PARAMETER Path
        Override the log directory. Primarily used by tests.

    .PARAMETER Disable
        Turn logging off for this session.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Path,

        [Parameter()]
        [switch] $Disable
    )

    if ($Disable) {
        $script:LogState.Enabled = $false
        $script:LogState.FilePath = $null
        return $script:LogState
    }

    $script:LogState.Enabled = $true

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $script:LogState.Directory = $Path
    }

    $directory = Get-PimLogDirectory

    try {
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
        }

        $fileName = 'PimGroupActivationTool-{0:yyyyMMdd}.log' -f (Get-Date)
        $script:LogState.Directory = $directory
        $script:LogState.FilePath = Join-Path -Path $directory -ChildPath $fileName
    }
    catch {
        # Logging must never break the tool.
        Write-Warning "Could not initialize the log directory '$directory'. Logging to file is disabled. $($_.Exception.Message)"
        $script:LogState.Enabled = $false
        $script:LogState.FilePath = $null
    }

    return $script:LogState
}

function Set-PimLogSink {
    <#
    .SYNOPSIS
        Registers a scriptblock that receives every formatted log line.

    .DESCRIPTION
        The WinForms UI uses this to mirror log output into the on-screen log box.
        Pass $null to remove the sink.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [scriptblock] $Sink
    )

    $script:LogState.Sink = $Sink
}

function Get-PimLogState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    return $script:LogState
}

function Write-PimLog {
    <#
    .SYNOPSIS
        Writes one operational log record.

    .DESCRIPTION
        Only operational details are logged: timestamp, level, tenant, group, access
        type, operation, status, and message. Tokens and credentials are redacted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string] $Message,

        [Parameter()]
        [ValidateSet('Information', 'Warning', 'Error', 'Debug')]
        [string] $Level = 'Information',

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Operation,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $TenantId,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $GroupId,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $GroupDisplayName,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $AccessId,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Status
    )

    # Message is redacted; every other field is attacker-influenced text from a
    # foreign directory, so it must not be able to forge a new log record.
    $safeMessage = ConvertTo-PimSafeLogValue -Value (Remove-PimSensitiveData -Text $Message)

    $fields = New-Object System.Collections.Generic.List[string]
    $fields.Add(('[{0:yyyy-MM-dd HH:mm:ss.fffZ}]' -f [datetime]::UtcNow))
    $fields.Add(('[{0}]' -f $Level.ToUpperInvariant()))
    if (-not [string]::IsNullOrWhiteSpace($Operation))        { $fields.Add("op=$(ConvertTo-PimSafeLogValue -Value $Operation)") }
    if (-not [string]::IsNullOrWhiteSpace($TenantId))         { $fields.Add("tenant=$(ConvertTo-PimSafeLogValue -Value $TenantId)") }
    if (-not [string]::IsNullOrWhiteSpace($GroupId))          { $fields.Add("group=$(ConvertTo-PimSafeLogValue -Value $GroupId)") }
    if (-not [string]::IsNullOrWhiteSpace($GroupDisplayName)) { $fields.Add("groupName=""$(ConvertTo-PimSafeLogValue -Value $GroupDisplayName)""") }
    if (-not [string]::IsNullOrWhiteSpace($AccessId))         { $fields.Add("access=$(ConvertTo-PimSafeLogValue -Value $AccessId)") }
    if (-not [string]::IsNullOrWhiteSpace($Status))           { $fields.Add("status=$(ConvertTo-PimSafeLogValue -Value $Status)") }
    $fields.Add($safeMessage)

    $line = ($fields -join ' ')

    switch ($Level) {
        'Warning' { Write-Verbose $line }
        'Error'   { Write-Verbose $line }
        'Debug'   { Write-Debug $line }
        default   { Write-Verbose $line }
    }

    if ($script:LogState.Sink) {
        try { & $script:LogState.Sink $line $Level } catch { Write-Debug "Log sink failed: $($_.Exception.Message)" }
    }

    if (-not $script:LogState.Enabled -or [string]::IsNullOrWhiteSpace($script:LogState.FilePath)) {
        return
    }

    # Multiple background workers can log at once.
    [System.Threading.Monitor]::Enter($script:LogSyncRoot)
    try {
        Add-Content -LiteralPath $script:LogState.FilePath -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        $script:LogState.Enabled = $false
        Write-Warning "Writing to the log file failed; file logging is now disabled. $($_.Exception.Message)"
    }
    finally {
        [System.Threading.Monitor]::Exit($script:LogSyncRoot)
    }
}

Export-ModuleMember -Function @(
    'Get-PimLogDirectory'
    'Initialize-PimLog'
    'Set-PimLogSink'
    'Get-PimLogState'
    'Write-PimLog'
)
