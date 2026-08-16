# Installation and fleet rollout

This guide installs the repository as a managed checkout at `C:\scripts`,
places a stable supervisor under `C:\ProgramData`, and registers one daily
`LOCAL SYSTEM` task for 04:00 local VM time.

## What gets installed

```text
Task Scheduler: Hermes-Agent-SelfUpdate-Daily (daily 04:00, SYSTEM/Highest)
  -> C:\ProgramData\HermesAgent-SelfUpdate\Invoke-HermesSelfUpdate.ps1
       -> validate and fast-forward C:\scripts to origin/main
       -> export the exact commit to Runs\<run-id>
       -> validate the PowerShell source
       -> start the snapshot's Hermes-SelfUpdate.ps1 in a new process
```

The supervisor is outside the checkout so the repository can be updated safely.
The core runs from a protected, commit-exact per-run snapshot, so the executed
files match
the commit recorded in the supervisor log.

## Prerequisites

- Windows PowerShell 5.1
- An elevated Administrator session for installation
- Git for Windows on `PATH`, in Program Files, or in the Hermes Portable Git
  location
- Hermes installed for `C:\Users\Administrator` by default
- Network access to `https://github.com/don040/HermesAgent-Selfupdate.git`

The installer and task do not need GitHub credentials because the repository is
public. The task stores no user password; it uses the built-in `SYSTEM` service
account.

## Fresh installation

Open an elevated Windows PowerShell session. The universal bootstrap also works
when Git is available only through Hermes Portable Git:

```powershell
$installer = Join-Path $env:TEMP 'Install-HermesSelfUpdate.ps1'
Invoke-WebRequest -UseBasicParsing `
  -Uri 'https://raw.githubusercontent.com/don040/HermesAgent-Selfupdate/main/Install-HermesSelfUpdate.ps1' `
  -OutFile $installer
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installer
```

The final command is idempotent. Running it again validates and fast-forwards
the checkout, refreshes the installed supervisor, hardens directory ACLs, and
replaces the task definition with the desired configuration. Any stopped,
obsolete `Hermes-OneShot-SelfUpdate` task is removed during installation; a
running legacy task makes the installer stop until that run finishes.

To use a different Hermes Windows profile:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File "C:\scripts\Install-HermesSelfUpdate.ps1" `
  -HermesUserProfile "C:\Users\AgentAdmin"
```

## Migrating an existing single-file agent

The known legacy layout has `C:\Scripts\Hermes-SelfUpdate.ps1` but no `.git`.
Do not clone over it. Download the standalone installer to a temporary path and
run it elevated:

```powershell
$installer = Join-Path $env:TEMP 'Install-HermesSelfUpdate.ps1'
Invoke-WebRequest `
  -UseBasicParsing `
  -Uri 'https://raw.githubusercontent.com/don040/HermesAgent-Selfupdate/main/Install-HermesSelfUpdate.ps1' `
  -OutFile $installer
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installer
```

The installer first clones and validates a staging checkout. Only then does it
move the recognized legacy directory to:

```text
C:\ProgramData\HermesAgent-SelfUpdate\MigrationBackup\Scripts-<timestamp>-<id>
```

It then activates the new checkout at `C:\scripts`. If the non-Git directory
contains anything other than the single known legacy script, installation stops
without moving or overwriting it.

## Installer options

| Parameter | Default | Purpose |
|---|---|---|
| `-InstallPath` | `C:\scripts` | Managed Git checkout |
| `-StatePath` | `C:\ProgramData\HermesAgent-SelfUpdate` | Supervisor, logs, snapshots, backups |
| `-RepositoryUrl` | Public GitHub repository | Required and validated `origin` |
| `-Branch` | `main` | Required deployment branch |
| `-TaskName` | `Hermes-Agent-SelfUpdate-Daily` | Persistent task name |
| `-DailyAt` | `04:00` | Daily local VM time (`HH:mm`) |
| `-HermesUserProfile` | `C:\Users\Administrator` | Profile containing the Hermes installation |
| `-RunNow` | Off | Starts the real scheduled workflow after installation |

`-RunNow` is destructive in the same sense as the normal 04:00 job: it may stop
the gateway, update Hermes, and restart the previous gateway state.

## Daily behavior

At 04:00 local VM time, the task:

1. Runs as `LOCAL SYSTEM` with the highest run level.
2. Refuses overlapping execution using both Task Scheduler `IgnoreNew` and a
   global mutex.
3. Validates the exact Git origin, branch, and clean tracked state.
4. Fetches `origin/main` with bounded retries and allows only a fast-forward.
5. Refuses a diverged branch, force-pushed history, or tracked local changes.
6. Exports the resulting commit to a run snapshot and parses the PowerShell
   source before execution.
7. Starts the fresh core in a separate Windows PowerShell process and returns
   its exit code to Task Scheduler.

Before changing Hermes, the core records whether the gateway was stopped,
running as the official root `Hermes_Gateway` Scheduled Task, or running as a
legacy Windows service. It restores only that captured backend. A running
unmanaged gateway, a named-profile task such as `Hermes_Gateway_work`, an
invalid task wrapper, or an unknown liveness result fails closed before any
gateway process is stopped. Automatic repair from mutable upstream scripts is
disabled; a broken Hermes installation must be repaired explicitly.

If the machine misses 04:00, `StartWhenAvailable` requests a catch-up run. A
repository validation or network failure fails closed: Hermes is not updated
from a stale checkout. The supervisor keeps the newest 14 run snapshots.

## Verification

Run the read-only installation check:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File "C:\scripts\Test-HermesSelfUpdateInstallation.ps1"
```

Useful native checks are:

```powershell
Get-ScheduledTask -TaskName 'Hermes-Agent-SelfUpdate-Daily'
Get-ScheduledTaskInfo -TaskName 'Hermes-Agent-SelfUpdate-Daily'
```

To request an immediate real run without bypassing the safety boundary:

```powershell
Start-ScheduledTask -TaskName 'Hermes-Agent-SelfUpdate-Daily'
```

Hermes itself may use the compatibility entry point:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File "C:\scripts\Hermes-SelfUpdate.ps1" `
  -ScheduleOnly
```

That command starts the installed daily task. It does not create a disposable
task and does not run the tracked core directly.

## Webhook configuration

Webhook setup is deliberately separate and per agent. Never edit a tracked
script to add the value. When the operator supplies it, set the existing
machine-scoped environment variable from an elevated session:

```powershell
[Environment]::SetEnvironmentVariable(
  'HERMES_UPDATE_WEBHOOK_URL',
  '<per-agent webhook URL>',
  'Machine'
)
```

The next `SYSTEM` task process reads the machine value. Do not add the value to
Task Scheduler arguments, logs, issue reports, or commits.

## Logs and retained artifacts

| Path | Contents |
|---|---|
| `C:\ProgramData\HermesAgent-SelfUpdate\Logs\supervisor.log` | Pull, commit, snapshot, child exit status |
| `C:\ProgramData\HermesAgent-SelfUpdate\Runs\<run-id>` | Exact executed source plus captured stdout/stderr |
| `C:\Users\Administrator\AppData\Local\hermes\logs\self-update.log` | Core update event log |
| `...\hermes\logs\self-update.report.txt` | Latest detailed Hermes report |
| `...\hermes\logs\self-update.*.log` | Latest command-specific output |

The old `weekly-self-update*` files are not deleted during migration; they remain
historical artifacts if present.

## Troubleshooting

### Tracked local changes

Run:

```powershell
git -C C:\scripts status --short
git -C C:\scripts diff
```

Move machine-specific data outside the checkout. Do not automatically reset or
delete changes you have not reviewed. After restoring a clean checkout, rerun
the installer.

### Unexpected origin or branch

Inspect without changing anything:

```powershell
git -C C:\scripts remote -v
git -C C:\scripts branch --show-current
```

The automation intentionally refuses any origin other than the configured URL
and any branch other than the configured branch.

### Task result is nonzero

Read `supervisor.log`, then the newest `Runs` directory, then the Hermes core
report. Exit code `102` means another supervisor held the lock. Exit code `100`
means the supervisor failed before starting the core. Other codes are generally
propagated from `Hermes-SelfUpdate.ps1`.

### Installation is not the default layout

Rerun the installer with the same explicit `-InstallPath`, `-StatePath`,
`-TaskName`, `-DailyAt`, and `-HermesUserProfile` values. The status script
accepts the corresponding parameters.

## Removal

To disable automation without deleting evidence or backups:

```powershell
Unregister-ScheduledTask `
  -TaskName 'Hermes-Agent-SelfUpdate-Daily' `
  -Confirm:$false
```

This intentionally leaves `C:\scripts` and the protected ProgramData state in
place. Review and back up logs or migration data before removing either
directory manually.

## Trust model

Every accepted new commit on the configured branch is eventually executed as
`SYSTEM`. Protect the GitHub repository accordingly: require MFA, branch
protection, reviewed changes, and restricted write access. The installer limits
local write access to `SYSTEM` and the local Administrators group, validates the
remote and branch, rejects tracked modifications and divergent history, and
executes only an archived commit snapshot. These controls do not compensate for
a compromised upstream repository.
