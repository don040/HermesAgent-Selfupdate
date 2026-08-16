# Agent operating instructions

This repository deploys the Hermes Agent self-update workflow on Windows. Treat
the deployment as privileged infrastructure: the Scheduled Task executes code
from this repository as `LOCAL SYSTEM`.

## Required deployment state

- Managed checkout: `C:\scripts`
- Stable supervisor: `C:\ProgramData\HermesAgent-SelfUpdate\Invoke-HermesSelfUpdate.ps1`
- Daily task: `Hermes-Agent-SelfUpdate-Daily`
- Schedule: every day at `04:00` in the VM's local time
- Repository: `https://github.com/don040/HermesAgent-Selfupdate.git`
- Branch: `main`
- Default Hermes profile: `C:\Users\Administrator`

Do not deploy only `Hermes-SelfUpdate.ps1`. The installer, supervisor, managed
Git checkout, and daily task are one system.

## Autonomous installation procedure

1. Work in an elevated Windows PowerShell 5.1 session.
2. Inspect `C:\scripts` without deleting or overwriting anything unknown.
3. If it is already the correct clean Git checkout, run its installer. Do not
   pull manually; the installer validates and fast-forwards it:

   ```powershell
   powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "C:\scripts\Install-HermesSelfUpdate.ps1"
   ```

4. If `C:\scripts` is missing, empty, or is the legacy deployment containing
   only `Hermes-SelfUpdate.ps1` and no `.git`, use this universal bootstrap.
   It locates Hermes Portable Git and safely preserves the legacy directory:

   ```powershell
   $installer = Join-Path $env:TEMP 'Install-HermesSelfUpdate.ps1'
   Invoke-WebRequest -UseBasicParsing `
     -Uri 'https://raw.githubusercontent.com/don040/HermesAgent-Selfupdate/main/Install-HermesSelfUpdate.ps1' `
     -OutFile $installer
   powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installer
   ```

5. Verify without changing or starting anything:

   ```powershell
   powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "C:\scripts\Test-HermesSelfUpdateInstallation.ps1"
   ```

6. Report the installed commit, task name, next run time, and any legacy backup
   path. Do not report webhook values.

See `INSTALL.md` for fresh-clone and legacy-migration commands.

## Operational rules

- Never edit tracked files in `C:\scripts` for machine-specific settings. A
  tracked modification intentionally blocks automatic synchronization.
- Never put a webhook URL or token in this repository, a Task Scheduler action,
  or a command committed to documentation. Use the machine-scoped
  `HERMES_UPDATE_WEBHOOK_URL` environment variable when the operator supplies
  the per-agent value.
- Never invoke `Hermes-SelfUpdate.ps1 -FromScheduledTask` manually. The core
  rejects destructive execution outside `LOCAL SYSTEM`.
- To request an immediate real run, use either
  `Start-ScheduledTask -TaskName 'Hermes-Agent-SelfUpdate-Daily'` or run the
  core with `-ScheduleOnly`. Both routes use the installed supervisor and pull
  first.
- `Hermes-SelfUpdate.ps1 -DryRun` is a direct core-only diagnostic. It does not
  refresh the self-update repository and must never be combined with
  `-ScheduleOnly`.
- Stop and investigate on an unexpected Git origin, wrong branch, tracked local
  changes, a non-fast-forward update, a reparse-point deployment path, or an
  unexpected non-Git directory. Do not force-reset or delete unknown contents.
- Keep machine state, logs, run snapshots, and secrets outside the checkout.
- Do not add the unrelated `C:\Tools` / rclone project to this repository or to
  this workflow.

## Change and validation rules

- Maintain Windows PowerShell 5.1 compatibility.
- Preserve the stable parameter contract between the supervisor and core:
  `-FromScheduledTask` and `-HermesUserProfile`.
- Keep the daily task name separate from obsolete one-shot task names. The
  daily task must never unregister itself.
- A repository refresh must fail closed: if fetch, origin/branch validation,
  fast-forward, snapshot creation, or PowerShell parsing fails, do not run the
  Hermes update from stale code.
- Run the static test suite after changes:

  ```powershell
  Invoke-Pester -Path .\tests\Static.Tests.ps1
  ```

- Also parse every `.ps1` file explicitly with the Windows PowerShell parser.
- Scheduler, ACL, migration, and destructive Hermes integration tests belong on
  a disposable elevated Windows VM, never on a production agent.
