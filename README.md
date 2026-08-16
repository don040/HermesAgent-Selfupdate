# Hermes Agent Self-Update for Windows

This repository installs a fleet-ready Windows workflow that refreshes its own
code before safely updating Hermes Agent.

The persistent Scheduled Task runs every day at **04:00 local VM time** as
`LOCAL SYSTEM`. A stable supervisor updates the managed checkout at `C:\scripts`,
validates the exact `origin/main` commit, exports a protected commit-exact run
snapshot, and only then starts the Hermes update core in a new PowerShell process.

## Quick start

From an elevated Windows PowerShell 5.1 session, use the same bootstrap for a
fresh machine or a legacy single-file installation. The installer locates
system Git or Hermes Portable Git itself:

```powershell
$installer = Join-Path $env:TEMP 'Install-HermesSelfUpdate.ps1'
Invoke-WebRequest -UseBasicParsing `
  -Uri 'https://raw.githubusercontent.com/don040/HermesAgent-Selfupdate/main/Install-HermesSelfUpdate.ps1' `
  -OutFile $installer
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installer
```

Existing agents that have only `C:\Scripts\Hermes-SelfUpdate.ps1` are migrated
safely; follow [INSTALL.md](INSTALL.md) instead of cloning over that directory.

Verify the result without starting an update:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "C:\scripts\Test-HermesSelfUpdateInstallation.ps1"
```

## Installed flow

```text
Hermes-Agent-SelfUpdate-Daily (04:00, SYSTEM/Highest)
  -> ProgramData supervisor
       -> fetch + validated fast-forward of C:\scripts
       -> exact commit snapshot + PowerShell parse check
       -> Hermes-SelfUpdate.ps1 -FromScheduledTask
            -> inspect gateway state
            -> stop gateway and Hermes-owned processes
            -> hermes update --yes --backup --force
            -> restore only the captured gateway backend/state
            -> verify, report, and notify when configured
```

The supervisor fails closed. A network error, wrong remote, wrong branch,
tracked local modification, non-fast-forward history, or invalid PowerShell file
prevents the Hermes update from running with stale or unexpected code.

## Repository contents

- `Install-HermesSelfUpdate.ps1` — idempotent installation, legacy migration,
  ACL hardening, and daily Task Scheduler registration
- `Invoke-HermesSelfUpdate.ps1` — stable supervisor source; the installer copies
  it outside the checkout
- `Hermes-SelfUpdate.ps1` — destructive Hermes update core and direct dry-run
- `Test-HermesSelfUpdateInstallation.ps1` — read-only deployment verification
- `INSTALL.md` — complete rollout, migration, operation, and troubleshooting
- `AGENTS.md` — concise rules for autonomous coding/operations agents

## Important defaults

- Checkout: `C:\scripts`
- State: `C:\ProgramData\HermesAgent-SelfUpdate`
- Task: `Hermes-Agent-SelfUpdate-Daily`
- Hermes user profile: `C:\Users\Administrator`
- Gateway backend: official root task `Hermes_Gateway`; legacy Windows services
  are also restored
- Optional webhook variable: machine-scoped `HERMES_UPDATE_WEBHOOK_URL`

Do not put webhook values or other machine-specific configuration into the Git
checkout. Do not invoke `-FromScheduledTask` manually. Use the installed task or
the `-ScheduleOnly` compatibility entry point for a real run.

For all prerequisites, migration behavior, parameters, log paths, manual-run
commands, and the security model, see [INSTALL.md](INSTALL.md).
