# PIMHelper

Tools for working with Microsoft Entra ID Privileged Identity Management (PIM).

## PIM Group Activation Tool

Activate your PIM-eligible **Entra ID group** assignments across every tenant you have
access to, from one window — instead of signing in to each tenant separately and
activating each group one at a time.

No custom app registration required; it authenticates through the first-party Microsoft
Graph PowerShell enterprise application.

```powershell
cd PimGroupActivationTool
.\Start-PimGroupActivationTool.ps1
```

See [`PimGroupActivationTool/README.md`](PimGroupActivationTool/README.md) for
requirements, headless usage, required permissions, and troubleshooting.

The design it was built from is in
[`docs/PIM-WinForms-Implementation-Plan.md`](docs/PIM-WinForms-Implementation-Plan.md).