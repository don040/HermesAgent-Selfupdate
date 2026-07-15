# Hermes Self-Update for Windows

A safety-focused PowerShell script for updating a Hermes Agent installation on Windows without leaving locked files, orphaned processes, or an unavailable gateway service behind.

The script performs the update outside the active Hermes process tree by creating a one-time Windows Scheduled Task running as `SYSTEM`. It stops the Hermes gateway, terminates remaining Hermes-owned processes, creates a backup, installs the update, verifies the result, restores the previous gateway state, and generates a detailed report.

Optional Discord webhook notifications provide live status information and a complete post-update report.

## Features

- Safe Hermes self-update on Windows
- One-time execution through Windows Task Scheduler
- Runs the destructive update phase as `SYSTEM`
- Prevents destructive execution from inside Hermes
- Detects Hermes-related parent processes before updating
- Configures the correct Administrator profile for scheduled execution
- Stops the Hermes gateway cleanly through the Hermes CLI
- Stops detected Hermes gateway services
- Terminates remaining Hermes, Python, Node.js, or Bun processes belonging to the Hermes installation
- Creates a backup using the built-in Hermes update command
- Automatically repairs missing or incomplete Hermes installations when possible
- Supports Portable Git and `uv` installations
- Applies configurable execution timeouts
- Restarts the gateway only if it was running before the update
- Supports both Windows service and manual gateway restart modes
- Verifies the Hermes launcher after the update
- Compares versions and revisions before and after the update
- Measures installation size changes
- Produces separate stdout and stderr logs
- Generates a detailed human-readable update report
- Sends structured Discord status embeds
- Uploads the full report as a Discord attachment
- Automatically removes the one-time Scheduled Task
- Includes a non-destructive dry-run mode

## Safety Model

The script is designed to avoid updating Hermes from inside its own running process tree.

A normal destructive update can stop services, terminate Hermes-related processes, and replace files inside the Hermes installation. Running those operations directly from an active Hermes session could terminate the process responsible for performing the update or leave files locked.

For this reason, the intended workflow is:

1. Hermes starts the script with `-ScheduleOnly`.
2. The script creates a one-time Scheduled Task.
3. Windows launches a separate PowerShell process as `SYSTEM`.
4. The scheduled process verifies that it is not running below a Hermes-owned parent process.
5. The scheduled process performs the update.
6. The one-time task removes itself after execution.

Direct destructive execution is rejected unless the script was started with `-FromScheduledTask`.

> **Important:** Do not manually use `-FromScheduledTask` to bypass the safety checks. Use `-ScheduleOnly` for real updates.

## Update Workflow

During a normal update, the script performs the following operations:

1. Initializes the Hermes environment for the Administrator installation.
2. Locates the required Git executable.
3. Collects the current Hermes version and revision.
4. Measures the current installation size.
5. Checks the Hermes gateway and Windows service state.
6. Determines whether the gateway must be restarted later.
7. Performs preflight checks and repairs the installation if required.
8. Sends an optional Discord notification that the update has started.
9. Stops all Hermes gateways through the Hermes CLI.
10. Stops detected Hermes gateway services.
11. Terminates remaining Hermes-owned processes.
12. Runs:

   ```text
   hermes update --yes --backup --force
