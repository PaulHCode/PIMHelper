# WinForms PowerShell PIM Request Tool Implementation Plan

## Goal

Build a Windows-friendly PowerShell + WinForms tool that lets users request Privileged Identity Management (PIM) activation for multiple Microsoft Entra ID groups across multiple tenants where they have B2B access.

The tool should avoid requiring a custom app registration for the supported built-in clouds. It should establish an Azure PowerShell sign-in when needed, discover the tenants available to that account, and let the user select tenants in the GUI. It should then authenticate through Microsoft Graph PowerShell and call Microsoft Graph PIM for Groups APIs on behalf of the signed-in user.

## Target users

- Users who already have PowerShell installed.
- Users who can access one or more customer / partner / cross-tenant directories through B2B.
- Users who are eligible for PIM activation on one or more groups.
- Users who are not comfortable writing PowerShell commands manually.

## Recommended technology

- PowerShell 7 preferred, Windows PowerShell 5.1 acceptable if tested.
- WinForms UI hosted from PowerShell.
- Az.Accounts for cloud sign-in and authorized-tenant discovery.
- Microsoft Graph PowerShell SDK for authentication and Graph calls.
- Raw Graph REST calls through `Invoke-MgGraphRequest` for PIM endpoints.

## Required Graph permissions

The Microsoft Graph PowerShell enterprise application must have admin consent in each target tenant for the required delegated permissions.

Minimum expected permissions:

- `PrivilegedEligibilitySchedule.Read.AzureADGroup`
- `PrivilegedAssignmentSchedule.ReadWrite.AzureADGroup`

Likely additional read permission for friendly names and group details:

- `Group.Read.All` or `Directory.Read.All`

The developer should verify the exact minimum permission set during implementation because Graph behavior can vary depending on endpoint, tenant policy, and whether the tool reads group metadata beyond the PIM schedule objects.

## High-level architecture

The application is a single PowerShell script or module that:

1. Loads WinForms assemblies.
2. Checks for required Az.Accounts and Microsoft Graph modules.
3. Opens a WinForms UI and asks the user to choose a cloud.
4. Reuses a valid Az context for that cloud or automatically calls `Connect-AzAccount`.
5. Calls `Get-AzTenant` and displays the authorized tenants in a multi-select grid.
6. Authenticates to each selected tenant using `Connect-MgGraph` and the matching Graph environment.
7. Reads the user's eligible PIM group assignments in that tenant.
8. Displays eligible groups in a grid.
9. Lets the user select multiple groups.
10. Collects justification and requested duration.
11. Submits one PIM activation request per selected group.
12. Displays success/failure results per group.

For Commercial, US Government, and US Government DoD, no client secret, custom app registration, web server, or browser-hosted JavaScript auth flow should be used. A Custom environment may be enabled only when its authentication requirements are documented and approved; otherwise the tool must mark it unsupported.

## Suggested repository structure

Use this structure if the tool becomes more than one file:

```text
PimGroupActivationTool\
  Start-PimGroupActivationTool.ps1
  src\
    PimGraph.psm1
    PimUi.psm1
    PimModels.psm1
  README.md
```

For a first prototype, a single script is acceptable:

```text
Start-PimGroupActivationTool.ps1
```

If the tool will be distributed broadly, prefer the multi-file structure and sign the entry script.

## Functional requirements

### Cloud selection

Before sign-in, show a cloud dropdown with these choices:

| UI choice | Az environment | Microsoft Graph environment | Graph base URI |
| --- | --- | --- | --- |
| Commercial | `AzureCloud` | `Global` | `https://graph.microsoft.com` |
| US Government | `AzureUSGovernment` | `USGov` | `https://graph.microsoft.us` |
| US Government DoD | `AzureUSGovernment` | `USGovDoD` | `https://dod-graph.microsoft.us` |
| Custom | User-selected registered environments | User-selected environment | Read from `Get-MgEnvironment` |

Keep this mapping in one configuration object. Do not scatter cloud-specific strings throughout the code.

`Custom` means an environment already returned by `Get-AzEnvironment` and a compatible environment returned by `Get-MgEnvironment`. Arbitrary endpoint entry is out of scope for the first version. Some sovereign or custom Graph environments require a custom app registration, which conflicts with the default no-app-registration goal. Detect that case and show an actionable unsupported/configuration-required message instead of attempting commercial-cloud endpoints.

### Azure sign-in and tenant discovery

The user must not type a tenant ID. After cloud selection:

1. Inspect `Get-AzContext` and confirm its account and environment match the selected cloud.
2. Validate the context by calling `Get-AzTenant`. A non-null context alone is not proof that its token is usable.
3. If there is no matching usable context, call `Connect-AzAccount -Environment <AzEnvironment> -Scope Process` automatically.
4. Call `Get-AzTenant` and convert each returned tenant to a tenant record.
5. Display the discovered tenants in a checkbox grid. Show name, primary domain when available, tenant ID, and category.
6. Require at least one selected tenant before enabling "Load Eligible Groups".

`Get-AzTenant` returns tenants authorized for the current account, including B2B tenants in which the account is an accepted guest. A tenant might still reject the later Graph sign-in because of consent, licensing, Conditional Access, or tenant policy; handle that as a per-tenant failure.

Provide a "Sign in with a different account" button. It should clear only this tool's process-scoped Az context and repeat sign-in; it must not delete the user's persisted Azure profiles.

### Authentication

Az PowerShell and Microsoft Graph PowerShell maintain separate authentication contexts. Do not assume `Connect-AzAccount` authenticates `Invoke-MgGraphRequest`. For each selected tenant, the tool should call:

```powershell
Connect-MgGraph -TenantId $TenantId -Scopes @(
    "PrivilegedEligibilitySchedule.Read.AzureADGroup",
    "PrivilegedAssignmentSchedule.ReadWrite.AzureADGroup",
    "Group.Read.All"
) -Environment $GraphEnvironment -ContextScope Process -NoWelcome
```

Implementation notes:

- Use delegated auth only.
- Do not use client secrets.
- Do not embed credentials.
- Use the Microsoft Graph PowerShell enterprise app consent model.
- Reconnect per tenant before calling tenant-specific Graph APIs, then verify both `TenantId` and `Environment` in `Get-MgContext`.
- The browser may reuse single sign-on, but the tool must tolerate an interactive prompt for each tenant.
- Show clear errors when the user lacks access, the tenant has not consented to permissions, or MFA/Conditional Access blocks sign-in.
- Keep all authentication and Graph calls in the background worker; never call them directly on the WinForms UI thread.

### Eligibility discovery

For each connected tenant, query the user's eligible PIM group assignments.

Use the documented v1.0 endpoint:

```text
/identityGovernance/privilegedAccess/group/eligibilitySchedules
```

Use `Invoke-MgGraphRequest`, for example:

```powershell
$uri = "$GraphBaseUri/v1.0/identityGovernance/privilegedAccess/group/eligibilitySchedules?`$filter=principalId eq '$userId'"
$response = Invoke-MgGraphRequest -Method GET -Uri $uri
```

Never hard-code `graph.microsoft.com`; obtain `$GraphBaseUri` from the selected cloud configuration. Follow `@odata.nextLink` until all pages have been read.

The implementation should:

1. Get the signed-in user's object ID in the current tenant.
2. Query eligible PIM group schedules for that principal.
3. Extract:
   - Tenant ID
   - Tenant display name if available
   - Group ID
   - Group display name
   - Access type: `member` or `owner`
   - Eligibility schedule ID
   - Assignment status / start / expiration if available
4. Resolve group names if the eligibility object does not include them.

To resolve group names:

```powershell
GET /groups/{groupId}?$select=id,displayName,description
```

or:

```powershell
Get-MgGroup -GroupId $groupId -Property Id,DisplayName,Description
```

### Activation request submission

For each selected group, submit a PIM activation request.

Use the documented v1.0 endpoint:

```text
POST /identityGovernance/privilegedAccess/group/assignmentScheduleRequests
```

Expected body shape:

```powershell
$body = @{
    action = "selfActivate"
    principalId = $PrincipalId
    groupId = $GroupId
    accessId = $AccessId
    justification = $Justification
    scheduleInfo = @{
        startDateTime = (Get-Date).ToUniversalTime().ToString("o")
        expiration = @{
            type = "afterDuration"
            duration = "PT2H"
        }
    }
} | ConvertTo-Json -Depth 10

Invoke-MgGraphRequest `
    -Method POST `
    -Uri "$GraphBaseUri/v1.0/identityGovernance/privilegedAccess/group/assignmentScheduleRequests" `
    -Body $body `
    -ContentType "application/json"
```

Implementation notes:

- `accessId` is typically `member` or `owner`.
- Duration should be collected from the UI and converted to ISO 8601 duration format, such as `PT1H`, `PT2H`, or `PT4H`.
- Use the current UTC time as `startDateTime` unless the UI later supports scheduled future activation.
- Submit requests sequentially at first. Parallel submission can be added later, but sequential is easier to troubleshoot and avoids throttling surprises.
- Capture the full Graph error response for troubleshooting, but show a concise message in the UI.

## UI design

Use a single main WinForms window with clear sections.

### Window layout

Recommended controls:

1. Sign-in panel
    - Cloud dropdown: Commercial, US Government, US Government DoD, Custom.
    - Button: "Sign in and Discover Tenants".
    - Signed-in account label.
    - Button: "Sign in with a different account".

2. Tenant grid
    - `DataGridView` with checkbox selection.
    - Tenant name, primary domain, tenant ID, and category.
    - Button: "Load Eligible Groups".

3. Group grid
   - `DataGridView`.
   - Checkbox column: selected.
   - Tenant name.
   - Tenant ID.
   - Group display name.
   - Group ID.
   - Access type: member/owner.
   - Eligibility status.

4. Request settings panel
   - Justification multiline textbox.
   - Duration dropdown: 30 minutes, 1 hour, 2 hours, 4 hours, 8 hours.
   - Optional checkbox: "Stop on first failure".

5. Action panel
   - Button: "Submit Activation Requests".
   - Progress bar.
   - Status label.

6. Results grid or log box
   - Tenant.
   - Group.
   - Access type.
   - Status: Success / Failed / Skipped.
   - Message.
   - Request ID if returned.

### Suggested default window size

- Width: 1200
- Height: 800
- Start position: CenterScreen

### UI behavior

- Disable the submit button until at least one group is selected and justification is provided.
- Disable tenant loading until sign-in succeeds and at least one tenant is selected.
- Disable sign-in and load buttons while discovery is running.
- Disable the submit button while requests are being submitted.
- Show progress after each tenant and each group.
- Do not freeze the UI during long operations. Use a background runspace or background worker.
- Do not preselect every discovered tenant; selection must be deliberate.

### UI state model

Implement these states explicitly rather than enabling controls from many unrelated event handlers:

| State | Enabled actions | Expected next state |
| --- | --- | --- |
| `SignedOut` | Choose cloud, sign in | `DiscoveringTenants` |
| `DiscoveringTenants` | Cancel only | `TenantsReady` or `SignedOut` on failure |
| `TenantsReady` | Select tenants, change account, load groups | `LoadingGroups` |
| `LoadingGroups` | Cancel only | `GroupsReady` or `TenantsReady` |
| `GroupsReady` | Select groups, edit request settings, submit | `Submitting` |
| `Submitting` | Cancel future requests only | `Completed` |
| `Completed` | Export results, change selection, submit again | `Submitting` or `TenantsReady` |

Changing the cloud or signed-in account clears tenant, group, and result rows. Changing tenant selection clears group and result rows. Never retain group selections across tenant or cloud changes.

## Data model

Use simple PowerShell custom objects.

### Tenant record

```powershell
[pscustomobject]@{
    Selected = $false
    TenantId = "11111111-1111-1111-1111-111111111111"
    TenantDisplayName = "Contoso"
    PrimaryDomain = "contoso.onmicrosoft.com"
    Category = "Home"
    Cloud = "Commercial"
    Status = "Discovered"
    Error = $null
}
```

### Cloud configuration record

```powershell
[pscustomobject]@{
    DisplayName = "Commercial"
    AzEnvironment = "AzureCloud"
    GraphEnvironment = "Global"
    GraphBaseUri = "https://graph.microsoft.com"
}
```

### Eligible group record

```powershell
[pscustomobject]@{
    Selected = $false
    TenantId = $tenantId
    TenantDisplayName = $tenantDisplayName
    GroupId = $groupId
    GroupDisplayName = $groupDisplayName
    GroupDescription = $groupDescription
    PrincipalId = $principalId
    AccessId = $accessId
    EligibilityScheduleId = $eligibilityScheduleId
    Status = "Eligible"
}
```

### Activation result record

```powershell
[pscustomobject]@{
    TenantId = $tenantId
    TenantDisplayName = $tenantDisplayName
    GroupId = $groupId
    GroupDisplayName = $groupDisplayName
    AccessId = $accessId
    Status = "Success"
    Message = $message
    RequestId = $requestId
}
```

## Implementation phases

### Phase 1: Command-line proof of concept

Before building the UI, create a command-line function that proves the Graph calls work.

Deliverables:

- `Get-PimCloudConfiguration`
- `Connect-PimAzureAccount`
- `Get-PimAuthorizedTenant`
- `Connect-PimGraphTenant`
- `Get-PimEligibleGroups`
- `Request-PimGroupActivation`

Acceptance criteria:

- Developer can select a cloud and the code calls `Connect-AzAccount` only when the current context is missing, invalid, or belongs to another environment.
- Developer can list the tenants returned by `Get-AzTenant` without entering a tenant ID.
- Developer can connect Graph to a selected tenant using the matching Graph environment.
- Developer can list eligible PIM groups for the signed-in user.
- Developer can activate one eligible group using a justification and duration.

### Phase 2: Basic WinForms shell

Create the main form with:

- Cloud dropdown and sign-in button.
- Tenant selection grid and load button.
- Eligible groups grid.
- Justification textbox.
- Duration dropdown.
- Submit button.
- Results log.

Acceptance criteria:

- Form opens reliably.
- Controls resize acceptably.
- User can choose a cloud, sign in, and select discovered tenants.
- UI remains understandable even before Graph logic is wired.

### Phase 3: Wire discovery into UI

Connect the load button to the discovery function.

Acceptance criteria:

- Tool discovers tenants after Azure sign-in.
- User selects multiple tenants from the grid.
- Tool authenticates to Graph tenant by tenant using the correct environment.
- Eligible groups appear in the grid.
- Tenant-level failures are shown without crashing the entire tool.

### Phase 4: Wire activation into UI

Connect the submit button to the activation function.

Acceptance criteria:

- User selects multiple groups across tenants.
- Tool submits one request per selected group.
- Results are shown per group.
- Failures do not hide successes.

### Phase 5: Hardening and usability

Add:

- Input validation.
- Better error messages.
- CSV export of results.
- Optional local settings file for recent tenants.
- Script signing guidance.
- README with screenshots and prerequisites.

Acceptance criteria:

- Non-PowerShell user can follow the README and run the tool.
- Errors are actionable.
- No credentials or tokens are written to disk by this tool.

## Error handling requirements

Handle these cases clearly:

- Microsoft Graph PowerShell module is not installed.
- User cancels sign-in.
- Existing Az context is expired or belongs to a different cloud.
- No authorized tenants are returned for the signed-in account.
- User cannot access a tenant.
- Tenant has not granted admin consent to required permissions.
- User has no eligible PIM groups in a tenant.
- Activation requires MFA or additional Conditional Access.
- Activation policy requires ticket number or extra justification fields.
- Requested duration exceeds tenant policy.
- Graph throttling or transient Graph failure.

For each group activation result, show:

- Success/failure.
- Short friendly message.
- Raw Graph error detail available through an expandable details field or copied log output.

## Module and dependency handling

At startup, check for required modules:

```powershell
$requiredModules = @(
    "Az.Accounts",
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.Groups"
)
```

If missing, show a dialog:

```text
Azure and Microsoft Graph PowerShell modules are required.
Install them now for the current user?
```

If the user agrees:

```powershell
Install-Module Az.Accounts -Scope CurrentUser
Install-Module Microsoft.Graph -Scope CurrentUser
```

Avoid silently installing modules without user confirmation.

## Security requirements

- Do not create or use a custom app registration for Commercial, US Government, or US Government DoD.
- Do not accept arbitrary Custom endpoints. A Custom environment that requires an app registration needs a separately approved design and configuration.
- Do not store credentials.
- Do not store access tokens.
- Do not ask users to paste tokens.
- Do not run arbitrary scripts from remote URLs.
- Prefer signed scripts for distribution.
- Log only operational details: tenant, group, status, request ID, and error text.
- Do not log access tokens, refresh tokens, cookies, or authorization headers.

## Logging

Create an optional local log file under the user's profile, for example:

```text
%LOCALAPPDATA%\PimGroupActivationTool\logs\
```

Log records should include:

- Timestamp.
- Tenant ID.
- Group ID.
- Group display name.
- Access type.
- Operation.
- Status.
- Error message if failed.

Do not log credentials or tokens.

## Suggested function design

### `Initialize-PimTool`

Responsibilities:

- Load WinForms assemblies.
- Check PowerShell version.
- Check modules.
- Initialize script-level settings.

### `Get-PimCloudConfiguration`

Responsibilities:

- Return the built-in cloud mappings.
- For Custom, enumerate `Get-AzEnvironment` and `Get-MgEnvironment` values.
- Reject an incomplete or incompatible environment pairing before sign-in.

### `Connect-PimAzureAccount`

Parameters:

- `AzEnvironment`

Responsibilities:

- Check for a matching process context.
- Validate it with `Get-AzTenant`.
- Call `Connect-AzAccount` automatically if validation fails.
- Return the account and environment details.

### `Get-PimAuthorizedTenant`

Responsibilities:

- Call `Get-AzTenant` after successful Az authentication.
- Normalize tenant name, ID, domains, and category into tenant records.
- Return an empty array, rather than `$null`, when no tenants are found.

### `Connect-PimGraphTenant`

Parameters:

- `TenantId`
- `GraphEnvironment`
- `Scopes`

Responsibilities:

- Call `Connect-MgGraph`.
- Verify tenant and environment using `Get-MgContext`.
- Return Graph context details or a structured tenant-level error.

### `Get-CurrentGraphUser`

Responsibilities:

- Call `/me`.
- Return user ID, UPN, and display name.

Example:

```powershell
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/me?`$select=id,userPrincipalName,displayName"
```

In implementation, replace the hard-coded host in this example with `$GraphBaseUri`.

### `Get-PimEligibleGroups`

Parameters:

- `TenantId`
- `PrincipalId`
- `GraphBaseUri`

Responsibilities:

- Query PIM eligibility schedules.
- Resolve group names.
- Return eligible group records.

### `Request-PimGroupActivation`

Parameters:

- `TenantId`
- `PrincipalId`
- `GroupId`
- `AccessId`
- `Justification`
- `Duration`
- `GraphBaseUri`

Responsibilities:

- Reconnect or confirm current Graph tenant context.
- Build activation request payload.
- POST request.
- Return result object.

### `ConvertTo-Iso8601Duration`

Parameters:

- `TimeSpan`

Responsibilities:

- Convert selected UI duration to Graph-compatible duration string.

Examples:

- 30 minutes -> `PT30M`
- 1 hour -> `PT1H`
- 2 hours -> `PT2H`

### `Show-PimMainForm`

Responsibilities:

- Build all WinForms controls.
- Wire event handlers.
- Start the UI loop.

## WinForms implementation guidance

Load required assemblies:

```powershell
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
```

Use `DataGridView` for eligible groups:

- Set `AutoGenerateColumns = $false`.
- Add explicit columns.
- Use a checkbox column for selection.
- Make group and tenant columns sortable if possible.

Avoid long-running Graph calls directly on the UI thread. Use:

- `System.ComponentModel.BackgroundWorker`, or
- PowerShell runspaces.

For a junior developer, `BackgroundWorker` may be simpler.

Important: UI controls must be updated on the UI thread. Use form/control `Invoke()` when updating controls from a background worker.

## Testing plan

### Unit-style tests

Test pure helper functions:

- Duration conversion.
- Cloud configuration lookup and environment mapping.
- Tenant record normalization.
- Payload creation.
- Error formatting.

### Manual integration tests

Run against a test tenant where:

- Existing Az context is valid for the selected cloud.
- Existing Az context is absent, expired, or for another cloud.
- Account has multiple B2B tenants.
- User has no eligible groups.
- User has one eligible group.
- User has multiple eligible groups.
- User has both member and owner eligibility.
- Requested duration is allowed.
- Requested duration is too long.
- Tenant lacks admin consent.
- User lacks B2B access.

### Acceptance test scenario

1. Launch the tool.
2. Select Commercial, US Government, or US Government DoD.
3. Click "Sign in and Discover Tenants" and complete sign-in if prompted.
4. Confirm the tenant grid contains the account's authorized tenants.
5. Select two tenants and click "Load Eligible Groups".
6. Complete any tenant-specific Graph sign-in prompts.
7. Confirm eligible groups appear.
8. Select three groups across two tenants.
9. Enter justification and choose two-hour duration.
10. Submit requests and confirm the results grid shows one row per selected group.

## Distribution plan

Start with a signed script:

```text
Start-PimGroupActivationTool.ps1
```

Later options:

- Package as a PowerShell module.
- Wrap with a shortcut.
- Package as an internal Intune Win32 app.
- Package with PS2EXE only if the organization is comfortable with the tradeoffs.

Recommended first distribution:

1. Publish to an internal Git repository or SharePoint location.
2. Include README.
3. Sign the script.
4. Instruct users to run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Start-PimGroupActivationTool.ps1
```

or, preferably with PowerShell 7:

```powershell
pwsh.exe -File .\Start-PimGroupActivationTool.ps1
```

## Open questions for the developer to confirm

1. Are target tenants consenting to Microsoft Graph PowerShell enterprise app permissions directly?
2. Are group activations only for `member`, or also `owner`?
3. Does each tenant require ticket information or custom justification rules?
4. What maximum activation durations should the UI offer?
5. Which custom or sovereign environments, if any, have a compatible Graph environment and approved app registration?
6. Should the tool support both PowerShell 5.1 and PowerShell 7?
7. Should result logs be saved automatically or only exported on demand?

## Official references

Use these pages as the source of truth while implementing; cmdlet and API behavior can change:

- [Connect-AzAccount](https://learn.microsoft.com/powershell/module/az.accounts/connect-azaccount)
- [Get-AzTenant](https://learn.microsoft.com/powershell/module/az.accounts/get-aztenant)
- [Microsoft Graph PowerShell authentication commands](https://learn.microsoft.com/powershell/microsoftgraph/authentication-commands)
- [List PIM for Groups eligibility schedules](https://learn.microsoft.com/graph/api/privilegedaccessgroup-list-eligibilityschedules)
- [Create a PIM for Groups assignment schedule request](https://learn.microsoft.com/graph/api/privilegedaccessgroup-post-assignmentschedulerequests)

## Definition of done

The tool is complete when:

- A non-PowerShell user can launch the UI.
- The user can choose Commercial, US Government, US Government DoD, or a validated Custom environment.
- The tool reuses a valid Az context or automatically runs `Connect-AzAccount` when needed.
- The tool discovers authorized tenants and never requires manual tenant-ID entry.
- The user can select one or more discovered tenants in the GUI.
- The tool authenticates to each selected tenant using Microsoft Graph PowerShell and the correct cloud environment.
- The tool lists eligible PIM groups per tenant.
- The user can select multiple groups.
- The user can provide justification and duration.
- The tool submits activation requests.
- The tool shows per-group success/failure.
- The built-in Commercial, US Government, and US Government DoD paths do not require a custom app registration.
- The tool does not store credentials or tokens.
- The implementation has been tested in at least one tenant with real PIM group eligibility.

