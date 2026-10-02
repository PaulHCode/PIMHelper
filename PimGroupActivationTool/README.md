# PIM Group Activation Tool

Activate your Privileged Identity Management (PIM) eligible **Microsoft Entra ID group**
assignments across **every tenant you have access to**, from one window.

If you are a guest (B2B) in several tenants and hold PIM-eligible group memberships in
more than one of them, the Entra portal makes you sign in to each tenant separately and
activate each group one at a time. This tool discovers every tenant you can reach,
collects your eligible groups from all of them, and submits the activations in one batch.

No custom app registration is required. The tool authenticates through the first-party
**Microsoft Graph PowerShell** enterprise application, which already exists in every
Entra tenant.

---

## Requirements

| Requirement | Notes |
|---|---|
| Windows | WinForms is Windows-only. The headless modes still need Windows for `Az.Accounts` interactive sign-in. |
| PowerShell 7.2+ | PowerShell 5.1 also works. |
| `Az.Accounts` 2.12.1+ | Azure sign-in and tenant discovery. |
| `Microsoft.Graph.Authentication` 2.26.0+ | Microsoft Graph sign-in and REST calls. |

Install the modules:

```powershell
Install-Module Az.Accounts, Microsoft.Graph.Authentication -Scope CurrentUser
```

The tool offers to install them for you if they are missing.

---

## Quick start

```powershell
cd PimGroupActivationTool
.\Start-PimGroupActivationTool.ps1
```

1. Pick your cloud and click **Sign in and Discover Tenants**.
2. Tick the tenants you care about and click **Load Eligible Groups**.
3. Tick the groups, choose an access type and duration, enter a justification.
4. Click **Submit Activation Requests**.
5. Review the results grid; **Export results** if you need a record.

The window is 1200x800 and opens centred. Long operations run on a background runspace,
so the UI stays responsive and can be cancelled.

---

## Headless usage

Every GUI action has a terminal equivalent. These are useful in a remote session, in a
pipeline, or when you just want one group activated quickly.

```powershell
# Which tenants can I reach?
.\Start-PimGroupActivationTool.ps1 -ListTenants

# What am I eligible for, everywhere?
.\Start-PimGroupActivationTool.ps1 -ListGroups

# ...or in one tenant only
.\Start-PimGroupActivationTool.ps1 -ListGroups -TenantId da667b97-c1f7-494e-b7ba-172131cd40d9

# What is already active?
.\Start-PimGroupActivationTool.ps1 -ListActive

# Activate two groups for four hours
.\Start-PimGroupActivationTool.ps1 -Activate `
    -TenantId da667b97-c1f7-494e-b7ba-172131cd40d9 `
    -GroupId 11111111-1111-1111-1111-111111111111, 22222222-2222-2222-2222-222222222222 `
    -Justification 'Change request 12345 - deploying hotfix' `
    -Duration 04:00:00
```

`-Activate` exits with code `1` if any request failed, so it composes with CI and scripts.

### Parameters

| Parameter | Applies to | Description |
|---|---|---|
| `-Cloud` | all | `Commercial` (default), `US Government`, `US Government DoD`, or a locally registered custom Azure environment. |
| `-TenantId` | list modes, `-Activate` | Filters the list modes. Required, and must be a single tenant, for `-Activate`. |
| `-GroupId` | `-Activate` | One or more group object IDs. |
| `-AccessId` | `-Activate` | `member` (default) or `owner`. |
| `-Justification` | `-Activate` | Recorded in the PIM audit log. Minimum 10 characters. |
| `-Duration` | `-Activate` | TimeSpan, e.g. `02:00:00`. Defaults to 2 hours. The GUI offers 30 minutes, 1, 2, 4, and 8 hours. |
| `-TicketNumber`, `-TicketSystem` | `-Activate` | Optional, recorded with the request when your policy asks for a ticket. |
| `-LogPath` | all | Overrides the log file location. |
| `-NoLog` | all | Disables file logging for this run. |
| `-UseDeviceAuthentication` | headless modes | Signs in with a device code instead of a browser. Use this over SSH or in a session with no browser. Not available in the window — see below. |
| `-SkipModuleCheck` | all | Skips the prerequisite check. |

---

## Permissions and consent

The tool requests these **delegated** Microsoft Graph scopes:

| Scope | Why |
|---|---|
| `PrivilegedEligibilitySchedule.Read.AzureADGroup` | Read your eligible group assignments. |
| `PrivilegedAssignmentSchedule.ReadWrite.AzureADGroup` | Submit the activation request. |
| `User.Read` | Read your own object ID, which every eligibility query is filtered by. |
| `Group.Read.All` | Resolve group **display names**. Optional. |

These are delegated scopes, so the tool can never do anything you could not already do in
the Entra portal yourself.

If a tenant will not consent to `Group.Read.All` — common for guests — the tool
automatically retries without it and carries on. Groups are then shown by object ID
instead of display name. You will see a warning saying so.

If consent is blocked entirely in a tenant, a Global Administrator or Privileged Role
Administrator there must consent to the Microsoft Graph PowerShell application
(`14d82eec-204b-4c2f-b7e8-296a70dab67e`) for those scopes. An admin can pre-consent with:

```powershell
Connect-MgGraph -TenantId <tenant> -Scopes 'PrivilegedEligibilitySchedule.Read.AzureADGroup','PrivilegedAssignmentSchedule.ReadWrite.AzureADGroup','Group.Read.All','User.Read'
```

---

## Clouds

| Cloud | Azure environment | Graph endpoint |
|---|---|---|
| Commercial | `AzureCloud` | `https://graph.microsoft.com` |
| US Government | `AzureUSGovernment` | `https://graph.microsoft.us` |
| US Government DoD | `AzureUSGovernment` | `https://dod-graph.microsoft.us` |

Custom Azure environments registered on your machine (`Get-AzEnvironment`) also appear in
the picker. A custom environment is only marked usable when a matching Microsoft Graph
environment with a Graph endpoint is registered too; otherwise the tool explains what is
missing rather than failing mid-request.

---

## Logging

Logs are written to:

```
%LOCALAPPDATA%\PimGroupActivationTool\logs\PimGroupActivationTool-yyyyMMdd.log
```

Each line records the timestamp, level, operation, tenant, group, and outcome.

**Tokens are never logged.** Everything written to the log, shown in the UI log pane, or
exported to CSV passes through a redaction filter that strips JWTs, `Bearer` headers, and
JSON fields named `access_token`, `refresh_token`, `id_token`, `client_secret`,
`password`, and `code_verifier`. URIs are logged without their query strings.

**Log records cannot be forged.** Group and tenant display names come from directories
you do not administer, so every structured field is stripped of line breaks, tabs, and
double quotes before it is written. A group named with an embedded newline plus a fake
`[timestamp] [INFO] ...` prefix still produces exactly one record. The same reasoning
applies to CSV exports, where a leading `=`, `+`, `-`, or `@` is neutralised so Excel
cannot evaluate a display name as a formula.

If the log file cannot be written, logging disables itself silently rather than breaking
the run. Use `-NoLog` to turn it off deliberately.

---

## Troubleshooting

**Sign-in falls back to a device code on its own**
On Windows the Graph SDK signs in through the Web Account Manager (WAM) broker, which
needs a usable parent window. In an embedded terminal, over a remote session, or when
the broker crashes, it can fail without raising an error, and `Connect-MgGraph` returns
leaving `Get-MgContext` null. Microsoft.Graph.Authentication 2.25.0 and earlier swallow
this completely, which is why 2.26.0 is the minimum version.

Rather than stopping there, the headless modes notice the empty context and retry once
with a device code, which needs no window. You will see a warning in the log and then a
code to enter. Nothing is approved on your behalf — the code is yours to enter, and you
still sign in yourself. Pass `-UseDeviceAuthentication` to skip the broker attempt
entirely.

**"A device code is needed to sign in, but this window has no way to show you one"**
Device codes are a terminal-only option. The window runs its work on a background
runspace, and the Graph SDK prints the code through the PowerShell host, which a
background runspace does not have — the code is written to nowhere. Verified by running
`Connect-MgGraph -UseDeviceCode` on a worker runspace and finding nothing on its
information, warning, or error streams.

So rather than hang on a code you would never see, the window says this and stops. Run
the headless mode from a terminal instead:

```powershell
pwsh -File .\Start-PimGroupActivationTool.ps1 -ListGroups -TenantId <tenant> -UseDeviceAuthentication
pwsh -File .\Start-PimGroupActivationTool.ps1 -Activate -TenantId <tenant> -GroupId <group> -Justification '...' -UseDeviceAuthentication
```

If the broker works on your machine — which it usually does on a normal desktop session —
the window signs in without any of this.

*Known limitation:* Az.Accounts prints its device code through `Write-Host`, so the
Azure half of a device-code sign-in does show up in the window's log. Only the Microsoft
Graph half is invisible. Making the window handle device codes end to end would mean
running the OAuth device-code flow directly instead of through the Graph SDK, so the tool
owns the code string and can display it; that is not implemented.

**"Microsoft Graph reported no error but left no sign-in context, with or without a device code"**
Both sign-in methods came back empty, so this is not the broker. Check that
Microsoft.Graph.Authentication is installed and importable; the installed version is
named in the message.

**"Unable to switch to a single-threaded apartment"**
WinForms needs STA and PowerShell 7 starts MTA on Windows. The script relaunches itself
with `-STA` automatically; if that fails, start it yourself:
`pwsh -STA -File .\Start-PimGroupActivationTool.ps1`.

**No tenants listed**
`Get-AzTenant` only returns tenants where your account is a member or an accepted guest.
Pending B2B invitations do not count — accept the invitation first.

**Groups show object IDs instead of names**
`Group.Read.All` was not consented in that tenant. This is cosmetic; activation still
works. See *Permissions and consent* above.

**"The caller must be an owner or member of the group"**
Microsoft Graph requires the caller to be an owner or member of the group, or to hold a
supported directory role, for some group reads. Eligibility reads and `selfActivate`
should work regardless, but if a specific group fails this way, activate it from the
Entra portal once and report the group type.

**"Microsoft Graph signed in as … but Azure is signed in as …"**
A warning, not a failure. Every Graph session is checked against the account you
signed in to Azure with, both when an existing session is reused and immediately
after a new sign-in — signing in again is not proof of *who* you signed in as,
because the WAM broker can satisfy a sign-in from a cached account without ever
prompting. If the two names are not the same person, close the tool and sign in
again before activating anything.

It is a warning rather than a hard stop because the two names can differ for one
legitimate person. A B2B guest's user principal name is minted from the address
the invitation was sent to, so Graph reports
`ada.lovelace_contoso.com#EXT#@fabrikam.onmicrosoft.com` while Azure reports
whatever your UPN is. Wherever an organisation's UPN differs from its primary
mail address those two strings cannot be reconciled locally, and refusing would
block exactly the cross-tenant case this tool exists for. The tool therefore
compares your Azure account against every name Graph knows you by — the folded
guest UPN, your `mail`, and your `otherMails` — and only warns when none match.

**"Microsoft Graph connected but would not say which account the session belongs to"**
This *is* a failure. Graph accepted the sign-in but would not return your profile,
so the tool has no evidence of who it is acting as. Since the same profile read
supplies the principal ID that every PIM call needs, nothing could have worked
anyway. Sign in again, and check that the tenant allows guests to read their own
profile.

*Known limitation:* the check binds to names, which an administrator can
reassign. A durable binding would use the MSAL `HomeAccountId`, which is not
available across all supported module versions. The check is a safeguard against
an accidental account switch, not an authentication boundary.

**Activation succeeds but access does not work**
Group-based access is evaluated at token issue time. Sign out and back in to the
downstream application after activating.

**Throttling (HTTP 429)**
Handled automatically. The tool honours `Retry-After`, otherwise backs off exponentially
to a 60 second cap.

---

## Development

```powershell
cd PimGroupActivationTool

# Full suite - needs STA because the UI tests build real WinForms controls
pwsh -NoProfile -STA -Command "Import-Module Pester -MinimumVersion 5.0 -MaximumVersion 5.99 -Force; Invoke-Pester -Path .\tests"
```

### Layout

```
PimGroupActivationTool\
  Start-PimGroupActivationTool.ps1   entry point, GUI + headless modes
  src\
    PimModels.psm1                   pure logic, no I/O - cloud table, record builders,
                                     request bodies, redaction, UI state machine
    PimLogging.psm1                  redacted file logging
    PimGraph.psm1                    all Azure and Microsoft Graph calls
    PimUi.psm1                       WinForms UI
  tests\
    PimModels.Tests.ps1
    PimLogging.Tests.ps1
    PimGraph.Tests.ps1
    PimUi.Tests.ps1
    SourceConventions.Tests.ps1      static analysis over the sources
```

Everything that can be tested without a network or a desktop lives in `PimModels.psm1`,
which is why the model tests make up most of the suite. `PimGraph.psm1` routes every
Azure and Graph cmdlet through `Invoke-PimExternalCommand`, so its tests register fakes
with `Set-PimCommandOverride` and run without `Az` or `Microsoft.Graph` installed.

`SourceConventions.Tests.ps1` is static analysis, not behaviour. It guards bug classes
that cost real debugging time during development:

- Wrapping a comma-returning function call in `@()`. A function ending in
  `return , ([object[]]$x)` emits its array as a *single* pipeline item, so `@(f)` nests
  instead of flattening and silently drops every record.
- Piping such a function straight into `Where-Object`/`ForEach-Object`. Same cause: the
  downstream cmdlet receives one `Object[]` rather than one item per record, so a filter
  like `Get-PimAvailableCloudConfiguration | Where-Object { $_.DisplayName -eq 'Commercial' }`
  returns the whole array instead of one cloud. Assign to a variable first, then pipe or
  `foreach` over the variable.
- `GetNewClosure()`. It rebinds a scriptblock to a new dynamic module, which breaks
  resolution of functions imported as nested modules.

### Code signing

For distribution inside an organisation, sign the scripts so they run under
`AllSigned`/`RemoteSigned`:

```powershell
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Select-Object -First 1
Get-ChildItem -Recurse -Include *.ps1, *.psm1 |
    Set-AuthenticodeSignature -Certificate $cert -TimestampServer 'http://timestamp.digicert.com'
```

Unsigned, users will need `Unblock-File` after downloading.
