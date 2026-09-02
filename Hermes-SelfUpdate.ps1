param(
    [switch]$ScheduleOnly,
    [switch]$FromScheduledTask,
    [switch]$DryRun,
    [string]$WebhookUrl = '',
    [string]$HermesUserProfile = 'C:\Users\Administrator'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($ScheduleOnly -and $FromScheduledTask) {
    throw '-ScheduleOnly and -FromScheduledTask cannot be used together.'
}

if ($ScheduleOnly -and $DryRun) {
    throw '-ScheduleOnly always starts the installed real update task. Run -DryRun directly instead.'
}

$WebhookEnvironmentVariable = 'HERMES_UPDATE_WEBHOOK_URL'

if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
    $WebhookUrl = [Environment]::GetEnvironmentVariable(
        $WebhookEnvironmentVariable,
        'Machine'
    )
}

if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
    $WebhookUrl = $env:HERMES_UPDATE_WEBHOOK_URL
}

# ============================================================
# Hermes Self Update - Safe Core Runner
#
# Hermes should run only:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\scripts\Hermes-SelfUpdate.ps1" -ScheduleOnly
#
# Optional dry run:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\scripts\Hermes-SelfUpdate.ps1" -DryRun
#
# Destructive mode:
#   Only allowed through the installed least-privileged supervisor with
#   -FromScheduledTask
# ============================================================

$HermesUserProfile = [IO.Path]::GetFullPath(
    [Environment]::ExpandEnvironmentVariables($HermesUserProfile)
).TrimEnd('\')
$HermesUserProfileRoot = [IO.Path]::GetPathRoot($HermesUserProfile)

if ([string]::IsNullOrWhiteSpace($HermesUserProfileRoot) -or
    $HermesUserProfile -eq $HermesUserProfileRoot.TrimEnd('\')) {
    throw "HermesUserProfile must not be a filesystem root: $HermesUserProfile"
}

$HermesHome = Join-Path $HermesUserProfile 'AppData\Local\hermes'
$HermesRepo = Join-Path $HermesHome 'hermes-agent'
$HermesExe = Join-Path $HermesRepo 'venv\Scripts\hermes.exe'
$HermesPython = Join-Path $HermesRepo 'venv\Scripts\python.exe'
$HermesModule = 'hermes_cli.main'

function Get-HermesProfileUserSid {
    param([Parameter(Mandatory = $true)][string]$ProfilePath)

    $normalizedProfile = [IO.Path]::GetFullPath($ProfilePath).TrimEnd('\')

    try {
        foreach ($profileKey in @(Get-ChildItem -LiteralPath (
                    'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
                ) -ErrorAction Stop)) {
            $profileImagePath = (Get-ItemProperty `
                    -LiteralPath $profileKey.PSPath `
                    -Name ProfileImagePath `
                    -ErrorAction Stop).ProfileImagePath

            if ([string]::IsNullOrWhiteSpace($profileImagePath)) {
                continue
            }

            $candidateProfile = [IO.Path]::GetFullPath(
                [Environment]::ExpandEnvironmentVariables($profileImagePath)
            ).TrimEnd('\')

            if ($candidateProfile.Equals($normalizedProfile, [StringComparison]::OrdinalIgnoreCase) -and
                $profileKey.PSChildName -match '^S-1-5-21-') {
                return $profileKey.PSChildName
            }
        }
    }
    catch {
        # Continue with ACL/account resolution.
    }

    try {
        $ownerSid = (Get-Acl -LiteralPath $normalizedProfile -ErrorAction Stop).GetOwner(
            [Security.Principal.SecurityIdentifier]
        ).Value

        if ($ownerSid -match '^S-1-5-21-') {
            return $ownerSid
        }
    }
    catch {
        # Continue with the conventional local-account fallback.
    }

    $profileUser = Split-Path -Leaf $normalizedProfile
    return (New-Object Security.Principal.NTAccount(
            $env:COMPUTERNAME,
            $profileUser
        )).Translate([Security.Principal.SecurityIdentifier]).Value
}

function ConvertTo-SidString {
    param([Parameter(Mandatory = $true)][string]$Identity)

    if ($Identity -match '^S-1-') {
        return (New-Object Security.Principal.SecurityIdentifier($Identity)).Value
    }

    return (New-Object Security.Principal.NTAccount($Identity)).Translate(
        [Security.Principal.SecurityIdentifier]
    ).Value
}

$HermesProfileUserSid = Get-HermesProfileUserSid -ProfilePath $HermesUserProfile

function Initialize-HermesTaskEnvironment {
    # S4U tasks do not load a complete interactive profile environment. Point
    # Hermes and its child processes at the configured profile explicitly.
    $env:USERPROFILE = $HermesUserProfile
    $env:HOME = $HermesUserProfile
    $env:HOMEDRIVE = [IO.Path]::GetPathRoot($HermesUserProfile).TrimEnd('\')
    $env:HOMEPATH = $HermesUserProfile.Substring($env:HOMEDRIVE.Length)
    $env:LOCALAPPDATA = Join-Path $HermesUserProfile 'AppData\Local'
    $env:APPDATA = Join-Path $HermesUserProfile 'AppData\Roaming'
    $env:HERMES_HOME = $HermesHome
    $env:PYTHONUTF8 = '1'
    $env:PYTHONIOENCODING = 'utf-8'

    $pathCandidates = @(
        (Join-Path $HermesRepo 'venv\Scripts'),
        (Join-Path $HermesHome 'bin'),
        (Join-Path $HermesHome 'git\cmd'),
        (Join-Path $HermesHome 'git\bin'),
        (Join-Path $HermesHome 'git\mingw64\bin'),
        (Join-Path $HermesHome 'git\usr\bin'),
        (Join-Path $HermesHome 'node'),
        (Join-Path $HermesUserProfile '.local\bin'),
        (Join-Path $HermesUserProfile 'AppData\Roaming\uv')
    )

    $pathEntries = @(
        $pathCandidates | Where-Object { Test-Path -LiteralPath $_ }
    )

    if ($env:PATH) {
        $pathEntries += $env:PATH
    }

    $env:PATH = $pathEntries -join ';'

    $gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue

    if (-not $gitCommand) {
        throw "git.exe was not found. Expected Portable Git below $HermesHome\git or Git on PATH."
    }

    return $gitCommand.Source
}

$ScriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }

$LogDir = Join-Path $HermesHome 'logs'
$LogFile = Join-Path $LogDir 'self-update.log'
$ReportFile = Join-Path $LogDir 'self-update.report.txt'

$UpdateOut = Join-Path $LogDir 'self-update.hermes.out.log'
$UpdateErr = Join-Path $LogDir 'self-update.hermes.err.log'

$GatewayStopOut = Join-Path $LogDir 'self-update.gateway-stop.out.log'
$GatewayStopErr = Join-Path $LogDir 'self-update.gateway-stop.err.log'

$GatewayStartOut = Join-Path $LogDir 'self-update.gateway-start.out.log'
$GatewayStartErr = Join-Path $LogDir 'self-update.gateway-start.err.log'

$GatewayStatusBeforeFile = Join-Path $LogDir 'self-update.gateway-status-before.log'
$GatewayStatusAfterFile = Join-Path $LogDir 'self-update.gateway-status-after.log'

$UpdateTimeoutMinutes = 20
$GatewayStartWaitSeconds = 15
$ScheduledTaskName = 'Hermes-Agent-SelfUpdate-Daily'
$GatewayServiceName = 'Hermes_Gateway'
$GatewayScheduledTaskName = 'Hermes_Gateway'
$ManagedRepositoryUrl = 'https://github.com/don040/HermesAgent-Selfupdate.git'
$script:UnterminatedHermesCommand = $false

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$ReportLines = New-Object System.Collections.Generic.List[string]

function Write-Log {
    param([string]$Message)

    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $LogFile -Encoding UTF8 -Value "[$stamp] $Message"
}

function Get-DirectorySizeBytes {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [long]0
    }

    $measurement = Get-ChildItem `
        -LiteralPath $Path `
        -File `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue |
    Measure-Object -Property Length -Sum

    if ($null -eq $measurement.Sum) {
        return [long]0
    }

    return [long]$measurement.Sum
}

function Format-ByteSize {
    param([long]$Bytes)

    if ($Bytes -ge 1GB) {
        return ('{0:N2} GB' -f ($Bytes / 1GB))
    }

    if ($Bytes -ge 1MB) {
        return ('{0:N1} MB' -f ($Bytes / 1MB))
    }

    if ($Bytes -ge 1KB) {
        return ('{0:N1} KB' -f ($Bytes / 1KB))
    }

    return "$Bytes B"
}

function Format-ByteDelta {
    param([long]$Bytes)

    if ($Bytes -eq 0) {
        return '0 B'
    }

    $prefix = if ($Bytes -gt 0) { '+' } else { '-' }
    return $prefix + (Format-ByteSize -Bytes ([Math]::Abs($Bytes)))
}

function Format-Duration {
    param([TimeSpan]$Duration)

    if ($Duration.TotalHours -ge 1) {
        return ('{0}h {1}m {2}s' -f [int]$Duration.TotalHours, $Duration.Minutes, $Duration.Seconds)
    }

    if ($Duration.TotalMinutes -ge 1) {
        return ('{0}m {1}s' -f [int]$Duration.TotalMinutes, $Duration.Seconds)
    }

    return ('{0:N1}s' -f $Duration.TotalSeconds)
}

function ConvertTo-HermesVersionInfo {
    param([string]$VersionText)

    $version = 'unknown'
    $release = 'unknown'
    $revision = 'unknown'

    if ($VersionText -match '(?i)Hermes\s+Agent\s+(v[^\s]+)') {
        $version = $Matches[1]
    }

    if ($VersionText -match '\(([^)]+)\)') {
        $release = $Matches[1]
    }

    if ($VersionText -match '(?i)(?:upstream|commit)\s+([0-9a-f]{7,40})') {
        $revision = $Matches[1]
    }

    return [pscustomobject]@{
        Version  = $version
        Release  = $release
        Revision = $revision
        Raw      = $VersionText
    }
}

function Get-GatewayStatusState {
    param(
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return 'Unknown'
    }

    # Match gateway-process liveness, not generic Scheduled Task text such as
    # "Task Status: Running". Official Hermes output can show a registered
    # task as running/ready while also saying that no gateway process exists.
    $runningPattern = '(?im)^\s*[^\p{L}\p{N}\r\n]*\s*Gateway(?:\s+process)?\s+(?:(?:is|status:)\s+)?running\b'
    $stoppedPattern = '(?im)^\s*[^\p{L}\p{N}\r\n]*\s*(?:No\s+gateway\s+process(?:es)?\s+detected\b|Gateway(?:\s+process)?\s+(?:(?:is|status:)\s+)?(?:not\s+running|stopped|inactive)\b)'
    $hasRunningState = $Text -match $runningPattern
    $hasStoppedState = $Text -match $stoppedPattern

    if ($hasRunningState -and -not $hasStoppedState) { return 'Running' }
    if ($hasStoppedState -and -not $hasRunningState) { return 'Stopped' }

    return 'Unknown'
}

function Test-GatewayStatusIndicatesRunning {
    param(
        [AllowEmptyString()]
        [string]$Text
    )

    return (Get-GatewayStatusState -Text $Text) -eq 'Running'
}

function Get-GatewayProcessIdsFromStatus {
    param(
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    $processIds = New-Object System.Collections.Generic.List[int]
    $runningLines = [regex]::Matches(
        $Text,
        '(?im)^\s*[^\p{L}\p{N}\r\n]*\s*Gateway(?:\s+process)?\s+(?:(?:is|status:)\s+)?running\b[^\r\n]*\bPID\s*:\s*([0-9][0-9,\s]*)'
    )

    foreach ($runningLine in $runningLines) {
        foreach ($rawProcessId in @($runningLine.Groups[1].Value -split ',')) {
            $parsedProcessId = 0

            if ([int]::TryParse($rawProcessId.Trim(), [ref]$parsedProcessId) -and
                $parsedProcessId -gt 0 -and
                -not $processIds.Contains($parsedProcessId)) {
                [void]$processIds.Add($parsedProcessId)
            }
        }
    }

    return $processIds.ToArray()
}

function Get-ServiceProcessId {
    param([string]$ServiceName)

    try {
        $escapedName = $ServiceName.Replace("'", "''")
        $service = Get-CimInstance `
            -ClassName Win32_Service `
            -Filter "Name='$escapedName'" `
            -ErrorAction Stop

        if ($service -and [int]$service.ProcessId -gt 0) {
            return [int]$service.ProcessId
        }
    }
    catch {
        Write-Log "Could not determine PID for service ${ServiceName}: $($_.Exception.Message)"
    }

    return 0
}

function Add-ReportLine {
    param([string]$Message = '')

    [void]$ReportLines.Add($Message)
}

function Add-ReportSection {
    param([string]$Title)

    Add-ReportLine ''
    Add-ReportLine "## $Title"
}

function Add-ReportBlock {
    param(
        [string]$Title,
        [string]$Text
    )

    Add-ReportSection $Title

    if ([string]::IsNullOrWhiteSpace($Text)) {
        Add-ReportLine '(no output)'
        return
    }

    foreach ($line in ($Text -split "`r?`n")) {
        Add-ReportLine $line
    }
}

function Write-Event {
    param([string]$Message)

    Write-Log $Message
    Add-ReportLine $Message
}

function Save-Report {
    Set-Content -Path $ReportFile -Value ($ReportLines -join "`r`n") -Encoding UTF8
}

function ConvertTo-CommandLine {
    param([string[]]$Arguments)

    $escaped = foreach ($arg in $Arguments) {
        if ($null -eq $arg) {
            '""'
        }
        elseif ($arg -match '[\s"]') {
            '"' + ($arg -replace '"', '\"') + '"'
        }
        else {
            $arg
        }
    }

    return ($escaped -join ' ')
}

function Get-ProcessChain {
    param([int]$StartPid = $PID)

    $chain = New-Object System.Collections.Generic.List[object]
    $currentPid = $StartPid

    while ($currentPid -and $currentPid -gt 0) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$currentPid" -ErrorAction SilentlyContinue

        if (-not $proc) {
            break
        }

        [void]$chain.Add($proc)
        $currentPid = $proc.ParentProcessId
    }

    return $chain.ToArray()
}

function Test-IsHermesProcess {
    param([object]$Process)

    if (-not $Process) {
        return $false
    }

    if ($Process.Name -notmatch '^(hermes|python|pythonw|node|bun)\.exe$') {
        return $false
    }

    if ($Process.ExecutablePath) {
        try {
            $executablePath = [IO.Path]::GetFullPath($Process.ExecutablePath)
            $homeBoundary = $HermesHome.TrimEnd('\') + '\'

            if ($executablePath.Equals($HermesHome, [StringComparison]::OrdinalIgnoreCase) -or
                $executablePath.StartsWith($homeBoundary, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
        catch {
            # Fall through to the command-line check for malformed or missing
            # executable paths returned by CIM.
        }
    }

    $escapedHome = [regex]::Escape($HermesHome.TrimEnd('\'))

    $commandLinePattern = '(?i){0}(?:[\\/\s"]|$)' -f $escapedHome
    $hermesCommandPattern = '(?i)(?:-m\s+hermes_cli(?:\.main)?\b|hermes(?:\.exe)?\s+gateway\b|gateway-service)'

    if ($Process.CommandLine -and
        $Process.CommandLine -match $commandLinePattern -and
        $Process.CommandLine -match $hermesCommandPattern) {
        return $true
    }

    return $false
}

function Assert-SafeExecutionMode {
    if ($DryRun) {
        return
    }

    if (-not $FromScheduledTask) {
        throw @"
Refusing to run destructive Hermes self-update directly.

This script stops Hermes services and kills Hermes-related processes under:
$HermesHome

Run it from Hermes only with:
-ScheduleOnly

Example:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ScriptPath" -ScheduleOnly
"@
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    if (-not $identity.User -or
        $identity.User.Value -eq 'S-1-5-18' -or
        $identity.User.Value -ne $HermesProfileUserSid) {
        throw @"
Refusing destructive execution outside the installed Hermes profile task.

Do not invoke -FromScheduledTask manually. Use:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ScriptPath" -ScheduleOnly
"@
    }

    if ([string]::IsNullOrWhiteSpace($env:HERMES_SELFUPDATE_SNAPSHOT_PATH) -or
        [string]::IsNullOrWhiteSpace($env:HERMES_SELFUPDATE_SUPERVISOR_PATH) -or
        $env:HERMES_SELFUPDATE_COMMIT -notmatch '^[0-9a-f]{40}$') {
        throw 'Refusing destructive execution without a validated supervisor snapshot contract.'
    }

    $snapshotPath = [IO.Path]::GetFullPath($env:HERMES_SELFUPDATE_SNAPSHOT_PATH).TrimEnd('\')
    $expectedCorePath = Join-Path $snapshotPath 'Hermes-SelfUpdate.ps1'
    $actualCorePath = [IO.Path]::GetFullPath($ScriptPath)

    if (-not $actualCorePath.Equals($expectedCorePath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing core outside the supervisor snapshot: $actualCorePath"
    }

    $snapshotItem = Get-Item -LiteralPath $snapshotPath -Force -ErrorAction Stop

    if (-not $snapshotItem.PSIsContainer -or
        ($snapshotItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Supervisor snapshot is not a safe directory: $snapshotPath"
    }

    $supervisorPath = [IO.Path]::GetFullPath($env:HERMES_SELFUPDATE_SUPERVISOR_PATH)

    if ([IO.Path]::GetFileName($supervisorPath) -ine 'Invoke-HermesSelfUpdate.ps1' -or
        -not (Test-Path -LiteralPath $supervisorPath -PathType Leaf)) {
        throw "Supervisor contract points to an invalid runner: $supervisorPath"
    }

    $chain = @(Get-ProcessChain)

    $badParents = @(
        $chain | Where-Object {
            $_.ProcessId -ne $PID -and (Test-IsHermesProcess -Process $_)
        }
    )

    if ($badParents.Count -gt 0) {
        $details = ($badParents | ForEach-Object {
                "PID=$($_.ProcessId) Name=$($_.Name) Path=$($_.ExecutablePath)"
            }) -join "`r`n"

        throw @"
Refusing to run because this process appears to be launched from inside Hermes.

Detected Hermes parent process:
$details

Use -ScheduleOnly so Windows Task Scheduler runs the destructive update outside Hermes.
"@
    }
}

function Start-InstalledHermesSelfUpdateTask {
    $task = Get-ScheduledTask `
        -TaskPath '\' `
        -TaskName $ScheduledTaskName `
        -ErrorAction SilentlyContinue

    if (-not $task) {
        throw @"
The installed daily task '$ScheduledTaskName' was not found.

Run the elevated installer first:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\scripts\Install-HermesSelfUpdate.ps1"
"@
    }

    $taskPrincipalSid = ConvertTo-SidString $task.Principal.UserId

    if ($taskPrincipalSid -ne $HermesProfileUserSid -or
        $taskPrincipalSid -eq 'S-1-5-18' -or
        $task.Principal.LogonType.ToString() -ne 'S4U' -or
        $task.Principal.RunLevel.ToString() -ne 'Limited') {
        throw "Refusing to start task '$ScheduledTaskName' because its principal is not the configured S4U/Limited Hermes profile user."
    }

    if ($task.State.ToString() -eq 'Disabled' -or
        ($null -ne $task.Settings.Enabled -and -not $task.Settings.Enabled)) {
        throw "Refusing to start disabled task '$ScheduledTaskName'."
    }

    $programData = if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }
    $expectedStatePath = Join-Path $programData 'HermesAgent-SelfUpdate'
    $expectedSupervisor = Join-Path $expectedStatePath 'Invoke-HermesSelfUpdate.ps1'
    $expectedPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $expectedInstallPath = Split-Path -Parent $ScriptPath
    $actions = @($task.Actions)

    if ($actions.Count -ne 1 -or
        $actions[0].Execute -ine $expectedPowerShell -or
        $actions[0].WorkingDirectory -ine $expectedStatePath -or
        $actions[0].Arguments.IndexOf($expectedSupervisor, [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
        $actions[0].Arguments.IndexOf($expectedInstallPath, [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
        $actions[0].Arguments.IndexOf($ManagedRepositoryUrl, [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
        $actions[0].Arguments -match '(?i)Hermes-SelfUpdate\.ps1.*-FromScheduledTask') {
        throw "Refusing task '$ScheduledTaskName' because its action does not use the installed refresh-first supervisor."
    }

    Start-ScheduledTask -TaskPath '\' -TaskName $ScheduledTaskName

    Write-Output 'Hermes self-update task started.'
    Write-Output "Task: $ScheduledTaskName"
    Write-Output 'The supervisor will refresh the repository before running the update.'
}

function Test-IsHermesGatewayProcessShape {
    param([object]$Process)

    if (-not $Process -or
        $Process.Name -notmatch '^(?:hermes|python|pythonw)\.exe$' -or
        [string]::IsNullOrWhiteSpace($Process.CommandLine)) {
        return $false
    }

    $moduleShape = '(?i)(?:^|\s)-m\s+hermes_cli(?:\.main)?(?=\s|$).*?(?:^|\s)gateway\s+run(?=\s|$)'
    $launcherShape = '(?i)(?:^|\s)(?:"[^"]*[\\/])?hermes(?:\.exe)?"?(?=\s|$).*?(?:^|\s)gateway\s+run(?=\s|$)'

    return ($Process.CommandLine -match $moduleShape -or
        $Process.CommandLine -match $launcherShape)
}

function Get-HermesGatewayProcesses {
    return @(
        Get-CimInstance Win32_Process -ErrorAction Stop |
            Where-Object { Test-IsHermesGatewayProcessShape -Process $_ }
    )
}

function Invoke-HermesCommand {
    param(
        [string]$Label,
        [string[]]$Arguments,
        [int]$TimeoutMinutes = 20
    )

    if (-not (Test-Path $HermesPython)) {
        throw "Hermes Python interpreter not found: $HermesPython"
    }

    # Run the CLI as a Python module. This keeps hermes.exe unlocked while
    # uv reinstalls the package during a Windows self-update.
    $moduleArguments = @('-m', $HermesModule) + $Arguments

    $stdoutPath = Join-Path $LogDir "$Label.out.txt"
    $stderrPath = Join-Path $LogDir "$Label.err.txt"

    if (Test-Path $stdoutPath) {
        Remove-Item -Force $stdoutPath
    }

    if (Test-Path $stderrPath) {
        Remove-Item -Force $stderrPath
    }

    $proc = Start-Process `
        -FilePath $HermesPython `
        -WorkingDirectory $HermesRepo `
        -ArgumentList (ConvertTo-CommandLine -Arguments $moduleArguments) `
        -WindowStyle Hidden `
        -PassThru `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath

    $timeoutMs = [int]([TimeSpan]::FromMinutes($TimeoutMinutes).TotalMilliseconds)
    $exitCode = $null

    if (-not $proc.WaitForExit($timeoutMs)) {
        Write-Log "Command $Label timed out after $TimeoutMinutes minutes - killing PID $($proc.Id)"

        $previousErrorActionPreference = $ErrorActionPreference
        $taskkillExitCode = 1

        try {
            $ErrorActionPreference = 'Continue'
            & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null
            $taskkillExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        if ($taskkillExitCode -ne 0) {
            try {
                Stop-Process -Id $proc.Id -Force -ErrorAction Stop
            }
            catch {
                Write-Log "Stop-Process failed for timed-out PID $($proc.Id): $($_.Exception.Message)"
            }
        }

        if (-not $proc.WaitForExit(10000)) {
            $script:UnterminatedHermesCommand = $true
            throw "Timed-out command $Label could not be terminated safely (PID $($proc.Id))."
        }

        $exitCode = 124
    }
    else {
        # A second parameterless wait is required with redirected streams on
        # Windows PowerShell 5.1. Refresh before reading ExitCode.
        $proc.WaitForExit()
        $proc.Refresh()
        $exitCode = [int]$proc.ExitCode
    }

    $stdout = ''
    $stderr = ''

    if (Test-Path $stdoutPath) {
        $stdout = Get-Content -Raw -Encoding UTF8 $stdoutPath

        if ($null -ne $stdout) {
            $stdout = $stdout.TrimEnd("`r", "`n")
        }
        else {
            $stdout = ''
        }
    }

    if (Test-Path $stderrPath) {
        $stderr = Get-Content -Raw -Encoding UTF8 $stderrPath

        if ($null -ne $stderr) {
            $stderr = $stderr.TrimEnd("`r", "`n")
        }
        else {
            $stderr = ''
        }
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        StdOut   = $stdout
        StdErr   = $stderr
        Command  = ($HermesPython + ' -m ' + $HermesModule + ' ' + (ConvertTo-CommandLine -Arguments $Arguments))
    }
}

function Get-HermesGatewayServices {
    $service = Get-Service -Name $GatewayServiceName -ErrorAction SilentlyContinue

    if (-not $service) {
        return @()
    }

    $escapedName = $GatewayServiceName.Replace("'", "''")
    $serviceDefinition = Get-CimInstance `
        -ClassName Win32_Service `
        -Filter "Name='$escapedName'" `
        -ErrorAction Stop

    if (-not $serviceDefinition -or
        [string]::IsNullOrWhiteSpace($serviceDefinition.PathName)) {
        throw "Legacy gateway service definition could not be validated: $GatewayServiceName"
    }

    $escapedHome = [regex]::Escape($HermesHome.TrimEnd('\'))
    $servicePathPattern = '(?i){0}(?:[\\/\s"]|$)' -f $escapedHome

    if ($serviceDefinition.PathName -notmatch $servicePathPattern -or
        $serviceDefinition.PathName -notmatch '(?i)gateway') {
        throw "Legacy gateway service does not point to the configured Hermes installation: $($serviceDefinition.PathName)"
    }

    $expectedProfileUser = Split-Path -Leaf $HermesUserProfile
    $serviceUser = [string]$serviceDefinition.StartName

    if ($serviceUser -notin @('LocalSystem', 'NT AUTHORITY\SYSTEM', '.\LocalSystem') -and
        ($serviceUser -split '\\')[-1] -ine $expectedProfileUser) {
        throw "Legacy gateway service uses an unexpected account: $serviceUser"
    }

    return @($service)
}

function Get-HermesProcesses {
    param(
        [int[]]$ExcludePids = @()
    )

    Get-CimInstance Win32_Process | Where-Object {
        $_.ProcessId -notin $ExcludePids -and
        (Test-IsHermesProcess -Process $_)
    }
}

function Stop-HermesProcesses {
    param([object[]]$TargetProcesses = @())

    $killed = New-Object System.Collections.Generic.List[string]

    if ($TargetProcesses.Count -eq 0) {
        return $killed.ToArray()
    }

    $processChain = @(Get-ProcessChain)
    $protectedPids = @($PID) + @($processChain | ForEach-Object { $_.ProcessId })

    for ($pass = 1; $pass -le 2; $pass++) {
        $targets = New-Object System.Collections.Generic.List[object]

        foreach ($capturedProcess in $TargetProcesses) {
            $capturedProcessId = [int]$capturedProcess.ProcessId

            if ($capturedProcessId -in $protectedPids) {
                throw "Refusing to terminate protected updater process PID $capturedProcessId."
            }

            $currentProcess = Get-CimInstance `
                -ClassName Win32_Process `
                -Filter "ProcessId=$capturedProcessId" `
                -ErrorAction SilentlyContinue

            if (-not $currentProcess) {
                continue
            }

            if ([string]$currentProcess.CreationDate -ne [string]$capturedProcess.CreationDate) {
                throw "Refusing reused gateway PID $capturedProcessId; its creation time changed."
            }

            if (-not (Test-IsHermesGatewayProcessShape -Process $currentProcess)) {
                throw "Refusing PID $capturedProcessId because it no longer has the Hermes gateway command shape."
            }

            [void]$targets.Add($currentProcess)
        }

        if ($targets.Count -eq 0) {
            break
        }

        foreach ($proc in $targets) {
            $entry = "PID=$($proc.ProcessId) Name=$($proc.Name)"
            [void]$killed.Add($entry)
            Write-Event "Killing lingering Hermes process: $entry"

            $previousErrorActionPreference = $ErrorActionPreference
            $taskkillExitCode = 1

            try {
                $ErrorActionPreference = 'Continue'
                & taskkill.exe /PID $proc.ProcessId /T /F 2>&1 | Out-Null
                $taskkillExitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }

            if ($taskkillExitCode -ne 0) {
                try {
                    Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
                }
                catch {
                    Write-Log "Could not terminate PID $($proc.ProcessId); taskkill exit=$taskkillExitCode; Stop-Process error=$($_.Exception.Message)"
                }
            }
        }

        Start-Sleep -Seconds 2
    }

    foreach ($capturedProcess in $TargetProcesses) {
        $capturedProcessId = [int]$capturedProcess.ProcessId
        $remainingProcess = Get-CimInstance `
            -ClassName Win32_Process `
            -Filter "ProcessId=$capturedProcessId" `
            -ErrorAction SilentlyContinue

        if ($remainingProcess -and
            [string]$remainingProcess.CreationDate -eq [string]$capturedProcess.CreationDate) {
            throw "Gateway process PID $capturedProcessId is still running after termination attempts."
        }
    }

    return $killed.ToArray()
}

function Send-DiscordWebhookReport {
    param(
        [string]$Summary = '',
        [object]$Embed = $null,
        [string]$AttachmentPath = ''
    )

    if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
        Write-Event 'Webhook URL not set - skipping Discord delivery.'
        return [pscustomobject]@{
            ExitCode = 0
            Response = 'skipped'
        }
    }

    if ($AttachmentPath -and -not (Test-Path -LiteralPath $AttachmentPath)) {
        throw "Report attachment missing: $AttachmentPath"
    }

    # Omit username so Discord uses the webhook's configured default identity.
    $payloadObject = @{}

    if ($null -ne $Embed) {
        $payloadObject.embeds = @($Embed)
    }
    else {
        $payloadObject.content = $Summary
    }

    $payload = $payloadObject | ConvertTo-Json -Depth 10 -Compress

    $endpoint = if ($WebhookUrl -match '\?') {
        "${WebhookUrl}&wait=true"
    }
    else {
        "${WebhookUrl}?wait=true"
    }

    # Keep the secret webhook URL out of native process command lines. The
    # managed HTTP client supports the same multipart payload and attachment
    # without exposing the endpoint through curl.exe argv or process telemetry.
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop

    $client = $null
    $multipart = $null
    $response = $null

    try {
        $client = New-Object System.Net.Http.HttpClient
        $multipart = New-Object System.Net.Http.MultipartFormDataContent
        $payloadContent = New-Object System.Net.Http.StringContent -ArgumentList @(
            $payload,
            [Text.Encoding]::UTF8,
            'application/json'
        )
        $multipart.Add($payloadContent, 'payload_json')

        if ($AttachmentPath) {
            $fileStream = [IO.File]::Open(
                $AttachmentPath,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::Read
            )
            $fileContent = New-Object System.Net.Http.StreamContent($fileStream)
            $fileContent.Headers.ContentType = New-Object `
                System.Net.Http.Headers.MediaTypeHeaderValue('text/plain')
            $multipart.Add(
                $fileContent,
                'file1',
                'hermes-update-report.txt'
            )
        }

        $response = $client.PostAsync($endpoint, $multipart).GetAwaiter().GetResult()
        $responseText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $responseText = $responseText.TrimEnd()

        if ($responseText) {
            Write-Log "Webhook response: $responseText"
        }

        return [pscustomobject]@{
            ExitCode = if ($response.IsSuccessStatusCode) { 0 } else { 22 }
            Response = $responseText
        }
    }
    finally {
        if ($response) {
            $response.Dispose()
        }

        if ($multipart) {
            # Disposing the multipart content also disposes payload/file
            # content and the attachment stream, if one was created.
            $multipart.Dispose()
        }

        if ($client) {
            $client.Dispose()
        }
    }
}

function Get-HermesGatewayScheduledTasks {
    return @(
        Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue |
            Where-Object {
                $_.TaskName -eq $GatewayScheduledTaskName -or
                $_.TaskName -like "${GatewayScheduledTaskName}_*"
            }
    )
}

function Assert-OfficialHermesGatewayScheduledTask {
    param([Parameter(Mandatory = $true)][object]$Task)

    if ($Task.TaskPath -ne '\') {
        throw "Gateway Scheduled Task is outside the expected root TaskPath: $($Task.TaskPath)$($Task.TaskName)"
    }

    $principalUser = $Task.Principal.UserId
    $principalAccount = $principalUser
    $logonType = $Task.Principal.LogonType.ToString()
    $runLevel = $Task.Principal.RunLevel.ToString()
    $expectedProfileUser = Split-Path -Leaf $HermesUserProfile

    if ($principalUser -in @('SYSTEM', 'NT AUTHORITY\SYSTEM', 'S-1-5-18')) {
        throw "Refusing gateway Scheduled Task configured as LOCAL SYSTEM: $($Task.TaskName)"
    }

    if ($principalUser -match '^S-1-') {
        try {
            $principalAccount = (
                New-Object Security.Principal.SecurityIdentifier($principalUser)
            ).Translate([Security.Principal.NTAccount]).Value
        }
        catch {
            throw "Gateway Scheduled Task user SID could not be resolved: $principalUser"
        }
    }

    if ($logonType -notmatch '(?i)Interactive' -or $runLevel -notmatch '(?i)Limited') {
        throw "Gateway Scheduled Task has an unexpected principal contract: user=$principalUser logon=$logonType runLevel=$runLevel"
    }

    if (($principalAccount -split '\\')[-1] -ine $expectedProfileUser) {
        throw "Gateway Scheduled Task user '$principalUser' does not match HermesUserProfile '$HermesUserProfile'."
    }

    if ($Task.State.ToString() -eq 'Disabled' -or
        ($null -ne $Task.Settings.Enabled -and -not $Task.Settings.Enabled)) {
        throw "Gateway Scheduled Task is disabled: $($Task.TaskName)"
    }

    $actions = @($Task.Actions)

    if ($actions.Count -ne 1) {
        throw "Gateway Scheduled Task must have exactly one action: $($Task.TaskName)"
    }

    $systemWscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $taskExecutable = $actions[0].Execute.Trim('"')

    if (($taskExecutable -ine 'wscript.exe' -and
         $taskExecutable -ine $systemWscript)) {
        throw "Gateway Scheduled Task has an unexpected executable: $($Task.TaskName)"
    }

    $expectedVbs = Join-Path $HermesHome ("gateway-service\{0}.vbs" -f $Task.TaskName)
    $expectedArguments = '//B //Nologo "{0}"' -f $expectedVbs

    if ($actions[0].Arguments.Trim() -ine $expectedArguments) {
        throw "Gateway Scheduled Task does not have the expected wrapper arguments: $expectedArguments"
    }

    if (-not (Test-Path -LiteralPath $expectedVbs -PathType Leaf)) {
        throw "Gateway Scheduled Task wrapper is missing: $expectedVbs"
    }

    $wrapperItem = Get-Item -LiteralPath $expectedVbs -Force

    if (($wrapperItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Gateway Scheduled Task wrapper must not be a reparse point: $expectedVbs"
    }
}

function Restore-HermesGatewayBackend {
    param(
        [string]$Mode,
        [object[]]$Services = @(),
        [object[]]$ScheduledTasks = @()
    )

    $restored = $true

    if ($Mode -eq 'service') {
        foreach ($service in $Services) {
            try {
                $current = Get-Service -Name $service.Name -ErrorAction Stop

                if ($current.Status.ToString() -ne 'Running') {
                    Write-Event "Restoring gateway service $($service.Name)"
                    Start-Service -Name $service.Name -ErrorAction Stop
                }

                $current = Get-Service -Name $service.Name -ErrorAction Stop

                if ($current.Status.ToString() -ne 'Running') {
                    $restored = $false
                    Write-Log "Gateway service did not reach RUNNING during safety restoration: $($service.Name)"
                }
            }
            catch {
                $restored = $false
                Write-Log "Could not restore gateway service $($service.Name): $($_.Exception.Message)"
            }
        }
    }
    elseif ($Mode -eq 'scheduled-task') {
        try {
            $status = Invoke-HermesCommand `
                -Label 'gateway-status-before-finally-restore' `
                -Arguments @('gateway', 'status', '--full') `
                -TimeoutMinutes 2
            $statusText = "$($status.StdOut)`r`n$($status.StdErr)"

            if ($status.ExitCode -eq 0 -and
                (Test-GatewayStatusIndicatesRunning -Text $statusText)) {
                return $true
            }
        }
        catch {
            Write-Log "Could not check gateway before Scheduled Task restoration: $($_.Exception.Message)"
        }

        foreach ($task in $ScheduledTasks) {
            try {
                [void](Get-ScheduledTask `
                    -TaskPath $task.TaskPath `
                    -TaskName $task.TaskName `
                    -ErrorAction Stop)
                Write-Event "Restoring gateway Scheduled Task $($task.TaskPath)$($task.TaskName)"
                Start-ScheduledTask `
                    -TaskPath $task.TaskPath `
                    -TaskName $task.TaskName `
                    -ErrorAction Stop
            }
            catch {
                $restored = $false
                Write-Log "Could not restore gateway Scheduled Task $($task.TaskPath)$($task.TaskName): $($_.Exception.Message)"
            }
        }

        if ($restored) {
            $gatewayConfirmed = $false

            for ($attempt = 1; $attempt -le 3; $attempt++) {
                Start-Sleep -Seconds 5

                try {
                    $status = Invoke-HermesCommand `
                        -Label 'gateway-status-after-finally-restore' `
                        -Arguments @('gateway', 'status', '--full') `
                        -TimeoutMinutes 2
                    $statusText = "$($status.StdOut)`r`n$($status.StdErr)"

                    if ($status.ExitCode -eq 0 -and
                        (Test-GatewayStatusIndicatesRunning -Text $statusText)) {
                        $gatewayConfirmed = $true
                        break
                    }
                }
                catch {
                    Write-Log "Gateway restoration check $attempt failed: $($_.Exception.Message)"
                }
            }

            $restored = $gatewayConfirmed
        }
    }

    return $restored
}

function Get-UvExecutable {
    $command = Get-Command uv.exe -ErrorAction SilentlyContinue

    if ($command) {
        return $command.Source
    }

    $candidates = @(
        (Join-Path $HermesUserProfile '.local\bin\uv.exe'),
        (Join-Path $HermesUserProfile 'AppData\Roaming\uv\uv.exe'),
        (Join-Path $HermesHome 'bin\uv.exe')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

# ============================================================
# Safe scheduling mode
# ============================================================

if ($ScheduleOnly) {
    Start-InstalledHermesSelfUpdateTask
    exit 0
}

# ============================================================
# Main destructive runner
# ============================================================

Assert-SafeExecutionMode

$GitExe = Initialize-HermesTaskEnvironment
$RunStartedAt = Get-Date
$InstallSizeBeforeBytes = Get-DirectorySizeBytes -Path $HermesRepo

Write-Event '=== self-update run started ==='
Write-Event "HermesHome=$HermesHome"
Write-Event "HermesRepo=$HermesRepo"
Write-Event "HermesExe=$HermesExe"
Write-Event "HermesPython=$HermesPython"
Write-Event "ScriptPath=$ScriptPath"
Write-Event "DryRun=$DryRun"
Write-Event "FromScheduledTask=$FromScheduledTask"
Write-Event "GitExe=$GitExe"
Write-Event "HermesEnvironmentHome=$env:HERMES_HOME"

$repairReasons = New-Object System.Collections.Generic.List[string]

if (-not (Test-Path -LiteralPath $HermesExe)) {
    [void]$repairReasons.Add("Hermes command launcher is missing: $HermesExe")
}

$repairRequired = $repairReasons.Count -gt 0
$repairStatusText = 'Not required'

if ($repairRequired) {
    Write-Event "Manual repair required: $($repairReasons -join '; ')"

    if ($DryRun) {
        $repairStatusText = "WOULD BE REQUIRED ($($repairReasons -join '; '))"
        Write-Event 'DryRun: no repair was started.'
    }
    else {
        $repairStatusText = 'REQUIRED - automatic repair disabled'
        Write-Event 'Automatic repair is disabled; update aborted before gateway mutation.'
        Add-ReportSection 'Manual repair required'
        Add-ReportLine ($repairReasons -join '; ')
        Add-ReportLine 'Repair Hermes explicitly, verify the installation, then rerun the scheduled task.'
        Save-Report
        exit 6
    }
}

if (-not (Test-Path -LiteralPath $HermesPython)) {
    Write-Event "Hermes Python interpreter not found; manual repair is required: $HermesPython"

    if ($DryRun) {
        Write-Event 'DryRun: missing Hermes Python was reported without changing the installation.'
    }
    else {
        try {
            $failureSymbol = [char]::ConvertFromUtf32(0x274C)
            $failureText = "$failureSymbol **Hermes Self-Update could not start**`n`nHermes Python interpreter not found:`n``$HermesPython`` `n`nAutomatic repair was not started because ``hermes.exe`` is present.`nHost: ``$env:COMPUTERNAME``"
            [void](Send-DiscordWebhookReport -Summary $failureText)
        }
        catch {
            Write-Log "Startup failure webhook could not be sent: $($_.Exception.Message)"
        }

        Save-Report
        exit 2
    }
}

$EmojiRocket = [char]::ConvertFromUtf32(0x1F680)
$EmojiClock = [char]::ConvertFromUtf32(0x1F552)
$EmojiComputer = [char]::ConvertFromUtf32(0x1F5A5)
$EmojiGear = [char]::ConvertFromUtf32(0x2699)
$EmojiPackage = [char]::ConvertFromUtf32(0x1F4E6)
$EmojiChart = [char]::ConvertFromUtf32(0x1F4CA)
$EmojiCheck = [char]::ConvertFromUtf32(0x2705)
$EmojiCross = [char]::ConvertFromUtf32(0x274C)
$EmojiWarning = [char]::ConvertFromUtf32(0x26A0)
$EmojiStopwatch = [char]::ConvertFromUtf32(0x23F1)
$EmojiBlueCircle = [char]::ConvertFromUtf32(0x1F535)
$EmojiGreenCircle = [char]::ConvertFromUtf32(0x1F7E2)
$EmojiYellowCircle = [char]::ConvertFromUtf32(0x1F7E1)
$EmojiRedCircle = [char]::ConvertFromUtf32(0x1F534)
$EmojiPaperclip = [char]::ConvertFromUtf32(0x1F4CE)

$HermesVersionBefore = 'unknown'

try {
    $versionBeforeResult = Invoke-HermesCommand `
        -Label 'version-before' `
        -Arguments @('--version') `
        -TimeoutMinutes 2

    if ($versionBeforeResult.StdOut) {
        $HermesVersionBefore = ($versionBeforeResult.StdOut -split "`r?`n")[0].Trim()
    }
}
catch {
    Write-Log "Could not determine Hermes version before update: $($_.Exception.Message)"
}

$HermesVersionBeforeInfo = ConvertTo-HermesVersionInfo -VersionText $HermesVersionBefore

$gatewayServiceBefore = Get-Service -Name $GatewayServiceName -ErrorAction SilentlyContinue
$gatewayServiceStatusBefore = if ($null -eq $gatewayServiceBefore) {
    'NOT FOUND'
}
else {
    $gatewayServiceBefore.Status.ToString().ToUpperInvariant()
}

$gatewayServicePidBefore = Get-ServiceProcessId -ServiceName $GatewayServiceName
$gatewayServicePidBeforeText = if ($gatewayServicePidBefore -gt 0) {
    $gatewayServicePidBefore.ToString()
}
else {
    'not available'
}

$runMode = if ($FromScheduledTask) {
    'Windows Task Scheduler (Hermes profile / S4U / Limited)'
}
elseif ($DryRun) {
    'Direct dry run'
}
else {
    'Direct execution'
}

$effectiveScriptArguments = @()

if ($ScheduleOnly) { $effectiveScriptArguments += '-ScheduleOnly' }
if ($FromScheduledTask) { $effectiveScriptArguments += '-FromScheduledTask' }
if ($DryRun) { $effectiveScriptArguments += '-DryRun' }

if ($effectiveScriptArguments.Count -eq 0) {
    $effectiveScriptArguments = @('(none)')
}

$runIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$startEmbed = @{
    title       = "$EmojiBlueCircle Hermes Self-Update Started"
    description = "Hermes update execution has started on **$env:COMPUTERNAME**."
    color       = 3447003
    timestamp   = $RunStartedAt.ToUniversalTime().ToString('o')
    fields      = @(
        @{
            name   = 'Server ID'
            value  = $env:COMPUTERNAME
            inline = $true
        },
        @{
            name   = 'Timestamp'
            value  = $RunStartedAt.ToString('yyyy-MM-ddTHH:mm:ssK')
            inline = $true
        },
        @{
            name   = $GatewayServiceName
            value  = "$gatewayServiceStatusBefore`nPID: $gatewayServicePidBeforeText"
            inline = $true
        },
        @{
            name   = 'Mode'
            value  = $runMode
            inline = $true
        },
        @{
            name   = 'User'
            value  = $runIdentity
            inline = $true
        },
        @{
            name   = 'Installation Size'
            value  = (Format-ByteSize -Bytes $InstallSizeBeforeBytes)
            inline = $true
        },
        @{
            name   = 'Hermes Version'
            value  = $HermesVersionBeforeInfo.Version
            inline = $true
        },
        @{
            name   = 'Release'
            value  = $HermesVersionBeforeInfo.Release
            inline = $true
        },
        @{
            name   = 'Revision'
            value  = $HermesVersionBeforeInfo.Revision
            inline = $true
        },
        @{
            name   = 'Preflight Repair'
            value  = $repairStatusText
            inline = $false
        },
        @{
            name   = 'Command'
            value  = '```powershell' + "`nhermes update --yes --backup --force`n" + '```'
            inline = $false
        },
        @{
            name   = 'Execution Details'
            value  = "**Arguments:** $($effectiveScriptArguments -join ' ')`n**Task:** $ScheduledTaskName`n**Script:** $ScriptPath"
            inline = $false
        },
        @{
            name   = 'Environment'
            value  = "**HERMES_HOME:** $env:HERMES_HOME`n**Git:** $GitExe"
            inline = $false
        }
    )
    footer      = @{
        text = "Hermes Update Observer | Started by $runIdentity"
    }
}

$startWebhookExitCode = 0

try {
    $startWebhookResult = Send-DiscordWebhookReport -Embed $startEmbed
    $startWebhookExitCode = $startWebhookResult.ExitCode
    Write-Event "Start webhook exit=$startWebhookExitCode"
}
catch {
    $startWebhookExitCode = 4
    Write-Event "Start webhook failed: $($_.Exception.Message)"
}

# Persist an initial report immediately so progress is visible while the
# potentially long-running update is still active.
Save-Report

$gatewayStatusBefore = $null
$gatewayServices = @()
$runningGatewayServices = @()
$gatewayScheduledTasks = @()
$capturedGatewayScheduledTasks = @()
$gatewayWasRunning = $false
$gatewayStateKnown = $false
$gatewayStatusState = 'Unknown'
$capturedGatewayPids = @()
$capturedGatewayProcesses = @()
$restartMode = 'none'

try {
    $gatewayStatusBefore = Invoke-HermesCommand `
        -Label 'gateway-status-before' `
        -Arguments @('gateway', 'status', '--full')

    $gatewayStatusBeforeText = $gatewayStatusBefore.StdOut

    if ($gatewayStatusBefore.StdErr) {
        $gatewayStatusBeforeText = $gatewayStatusBeforeText + "`r`n" + $gatewayStatusBefore.StdErr
    }

    Set-Content `
        -Path $GatewayStatusBeforeFile `
        -Value $gatewayStatusBeforeText `
        -Encoding UTF8

    Write-Event "Gateway status before update exit=$($gatewayStatusBefore.ExitCode)"

    if ($gatewayStatusBefore.StdOut) {
        Add-ReportBlock -Title 'Gateway status before update - stdout' -Text $gatewayStatusBefore.StdOut
    }

    if ($gatewayStatusBefore.StdErr) {
        Add-ReportBlock -Title 'Gateway status before update - stderr' -Text $gatewayStatusBefore.StdErr
    }

    if ($gatewayStatusBefore.ExitCode -eq 0) {
        $gatewayStatusCombined = "$($gatewayStatusBefore.StdOut)`r`n$($gatewayStatusBefore.StdErr)"
        $gatewayStatusState = Get-GatewayStatusState -Text $gatewayStatusCombined
        $capturedGatewayPids = @(
            Get-GatewayProcessIdsFromStatus -Text $gatewayStatusCombined
        )

        if ($gatewayStatusState -eq 'Unknown') {
            Write-Event 'Gateway status output did not contain a recognized running/stopped state.'
        }
        else {
            $gatewayWasRunning = $gatewayStatusState -eq 'Running'
            $gatewayStateKnown = $true
        }
    }
    else {
        Write-Event 'Gateway status command failed; service discovery must establish a safe state before the update can continue.'
    }
}
catch {
    Write-Event "Gateway status before update failed: $($_.Exception.Message)"
}

if ($script:UnterminatedHermesCommand) {
    Write-Event 'Gateway status command could not be terminated; refusing all gateway and update mutations.'
    Add-ReportSection 'Safety abort'
    Add-ReportLine 'A timed-out preflight command may still be active.'
    Save-Report
    exit 7
}

try {
    $gatewayProcessInventory = @(Get-HermesGatewayProcesses)
}
catch {
    Write-Event "Gateway process inventory failed: $($_.Exception.Message)"
    Add-ReportSection 'Safety abort'
    Add-ReportLine 'The running gateway process inventory could not be established.'
    Save-Report
    exit 7
}

if ($gatewayStatusState -eq 'Running') {
    $inventoryPids = @($gatewayProcessInventory | ForEach-Object { [int]$_.ProcessId })
    $missingStatusPids = @($capturedGatewayPids | Where-Object { $_ -notin $inventoryPids })
    $uncapturedGatewayPids = @($inventoryPids | Where-Object { $_ -notin $capturedGatewayPids })

    if ($capturedGatewayPids.Count -eq 0 -or
        $missingStatusPids.Count -gt 0 -or
        $uncapturedGatewayPids.Count -gt 0) {
        Write-Event 'Gateway status PIDs and the machine process inventory do not match; refusing to mutate Hermes.'
        Add-ReportSection 'Safety abort'
        Add-ReportLine 'A running gateway must expose every PID and every PID must have the exact Hermes gateway command shape.'
        Save-Report
        exit 7
    }

    $capturedGatewayProcesses = @(
        $gatewayProcessInventory | Where-Object {
            [int]$_.ProcessId -in $capturedGatewayPids
        }
    )
}
elseif ($gatewayStatusState -eq 'Stopped' -and $gatewayProcessInventory.Count -gt 0) {
    Write-Event 'Hermes reports the default gateway stopped, but gateway-shaped processes still exist; refusing to mutate Hermes.'
    Add-ReportSection 'Safety abort'
    Add-ReportLine 'Stop or migrate all gateway profiles before retrying the self-update.'
    Save-Report
    exit 7
}

try {
    $gatewayServices = @(Get-HermesGatewayServices)
}
catch {
    Write-Event "Legacy gateway service validation failed: $($_.Exception.Message)"
    Add-ReportSection 'Safety abort'
    Add-ReportLine $_.Exception.Message
    Save-Report
    exit 7
}

$runningGatewayServices = @(
    $gatewayServices | Where-Object { $_.Status.ToString() -eq 'Running' }
)
$gatewayScheduledTasks = @(Get-HermesGatewayScheduledTasks)

$gatewayServiceDirectory = Join-Path $HermesHome 'gateway-service'
$startupDirectory = Join-Path $HermesUserProfile 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
$unsupportedGatewayArtifacts = @()

if (Test-Path -LiteralPath $gatewayServiceDirectory -PathType Container) {
    $unsupportedGatewayArtifacts += @(
        Get-ChildItem `
            -LiteralPath $gatewayServiceDirectory `
            -File `
            -Force `
            -ErrorAction Stop |
            Where-Object { $_.Name -like "${GatewayScheduledTaskName}_*" }
    )
}

if (Test-Path -LiteralPath $startupDirectory -PathType Container) {
    $unsupportedGatewayArtifacts += @(
        Get-ChildItem `
            -LiteralPath $startupDirectory `
            -File `
            -Force `
            -ErrorAction Stop |
            Where-Object { $_.Name -like "${GatewayScheduledTaskName}*" }
    )
}

$profiledGatewayProcesses = @(
    Get-HermesProcesses | Where-Object {
        $_.CommandLine -and
        $_.CommandLine -match '(?i)(?:^|\s)(?:--profile|-p)(?:=|\s)'
    }
)

if ($unsupportedGatewayArtifacts.Count -gt 0 -or
    $profiledGatewayProcesses.Count -gt 0) {
    Write-Event 'Named-profile or Startup-folder gateway state is present and cannot be restored safely from LOCAL SYSTEM.'
    Add-ReportSection 'Safety abort'
    Add-ReportLine 'Remove or migrate named-profile/Startup gateway backends before enabling fleet self-update.'
    Save-Report
    exit 7
}

$namedProfileGatewayTasks = @(
    $gatewayScheduledTasks | Where-Object {
        $_.TaskName -ne $GatewayScheduledTaskName
    }
)

if ($namedProfileGatewayTasks.Count -gt 0) {
    Write-Event 'Named-profile Hermes gateway tasks are present; per-profile state restoration is not supported safely.'
    Add-ReportSection 'Safety abort'
    Add-ReportLine ('Unsupported named-profile task(s): ' + (($namedProfileGatewayTasks | ForEach-Object {
        "$($_.TaskPath)$($_.TaskName)"
    }) -join ', '))
    Add-ReportLine 'No gateway process was stopped and Hermes was not updated.'
    Save-Report
    exit 7
}

if ($runningGatewayServices.Count -gt 0) {
    # A running Windows service is authoritative even if the Hermes CLI status
    # command was unavailable. A merely installed but stopped service is not:
    # a manually started gateway might still exist alongside it.
    $gatewayStateKnown = $true
}

if (-not $gatewayStateKnown) {
    Write-Event 'Gateway state is unknown and no running gateway service could establish it; refusing to update Hermes.'
    Add-ReportSection 'Safety abort'
    Add-ReportLine 'The pre-update gateway state could not be established reliably.'
    Add-ReportLine 'No services or processes were stopped and Hermes was not updated.'
    Save-Report
    exit 7
}

if ($gatewayWasRunning -and $runningGatewayServices.Count -eq 0) {
    if ($gatewayScheduledTasks.Count -ne 1) {
        Write-Event "A running gateway requires exactly one supported Scheduled Task backend; found $($gatewayScheduledTasks.Count)."
        Add-ReportSection 'Safety abort'
        Add-ReportLine 'Expected exactly one official Hermes_Gateway Scheduled Task for the running gateway.'
        Save-Report
        exit 7
    }

    try {
        Assert-OfficialHermesGatewayScheduledTask -Task $gatewayScheduledTasks[0]
        $capturedGatewayScheduledTasks = @($gatewayScheduledTasks[0])
    }
    catch {
        Write-Event "Gateway Scheduled Task validation failed: $($_.Exception.Message)"
        Add-ReportSection 'Safety abort'
        Add-ReportLine $_.Exception.Message
        Save-Report
        exit 7
    }
}

if ($gatewayWasRunning -and
    $runningGatewayServices.Count -eq 0 -and
    $capturedGatewayScheduledTasks.Count -eq 0) {
    Write-Event 'A running gateway has no supported service or Scheduled Task backend; refusing to restart it as LOCAL SYSTEM.'
    Add-ReportSection 'Safety abort'
    Add-ReportLine 'Register the gateway as a Windows service or the official Hermes_Gateway Scheduled Task, then rerun.'
    Save-Report
    exit 7
}

if ($runningGatewayServices.Count -gt 0) {
    $restartMode = 'service'
}
elseif ($capturedGatewayScheduledTasks.Count -gt 0) {
    $restartMode = 'scheduled-task'
}
else {
    $restartMode = 'none'
}

Write-Event "Gateway restart mode after update: $restartMode"

if ($gatewayServices.Count -gt 0) {
    Write-Event ('Detected gateway service(s): ' + (($gatewayServices | ForEach-Object {
        "$($_.Name) [$($_.Status)]"
    }) -join ', '))
}
else {
    Write-Event 'No gateway service detected.'
}

if ($gatewayScheduledTasks.Count -gt 0) {
    Write-Event ('Detected gateway Scheduled Task(s): ' + (($gatewayScheduledTasks | ForEach-Object {
        "$($_.TaskPath)$($_.TaskName) [$($_.State)]"
    }) -join ', '))
}
else {
    Write-Event 'No gateway Scheduled Task detected.'
}

if ($DryRun) {
    Write-Event 'DryRun requested - no changes were made.'

    Add-ReportSection 'DryRun summary'
    Add-ReportLine 'Would stop only the default gateway via: hermes gateway stop'
    Add-ReportLine "Would stop running service(s): $((@($runningGatewayServices | ForEach-Object { $_.Name }) -join ', '))"
    Add-ReportLine "Would kill Hermes processes under: $HermesHome"
    Add-ReportLine "Would run: hermes update --yes --backup --force"

    if ($restartMode -eq 'service') {
        Add-ReportLine 'Would restart only gateway service(s) that are currently running.'
    }
    elseif ($restartMode -eq 'scheduled-task') {
        Add-ReportLine 'Would restart the captured official Hermes_Gateway Scheduled Task under its registered user.'
    }
    else {
        Add-ReportLine 'Gateway was not running - would leave it stopped.'
    }

    Save-Report
    exit 0
}

$gatewayRestorationRequired = $restartMode -in @('service', 'scheduled-task')
$restartExitCode = 0
$restartResult = $null

try {
# Stop gateway via Hermes CLI first
$gatewayStopResult = $null
$stopPhaseSucceeded = $true

try {
    $gatewayStopResult = Invoke-HermesCommand `
        -Label 'gateway-stop' `
        -Arguments @('gateway', 'stop')

    Set-Content -Path $GatewayStopOut -Value $gatewayStopResult.StdOut -Encoding UTF8
    Set-Content -Path $GatewayStopErr -Value $gatewayStopResult.StdErr -Encoding UTF8

    Write-Event "Gateway stop exit=$($gatewayStopResult.ExitCode)"

    if ($gatewayStopResult.ExitCode -ne 0) {
        $stopPhaseSucceeded = $false
        Write-Event 'Graceful gateway stop failed; the update will not proceed.'
    }

    if ($gatewayStopResult.StdOut) {
        Add-ReportBlock -Title 'Gateway stop - stdout' -Text $gatewayStopResult.StdOut
    }

    if ($gatewayStopResult.StdErr) {
        Add-ReportBlock -Title 'Gateway stop - stderr' -Text $gatewayStopResult.StdErr
    }
}
catch {
    $stopPhaseSucceeded = $false
    Write-Event "Gateway stop command failed: $($_.Exception.Message)"
}

# Stop only gateway services that were running before the update. Services
# that were intentionally stopped must remain stopped.
if ($runningGatewayServices.Count -gt 0) {
    foreach ($svc in $runningGatewayServices) {
        try {
            Write-Event "Stopping service $($svc.Name)"
            Stop-Service -Name $svc.Name -Force -ErrorAction Stop
        }
        catch {
            Write-Log "Stop-Service failed for $($svc.Name): $($_.Exception.Message)"
            Add-ReportLine "Stop-Service failed for $($svc.Name): $($_.Exception.Message)"
        }
    }
}

# Kill lingering Hermes-owned processes
$killedProcesses = @()

try {
    $killedProcesses = @(
        Stop-HermesProcesses -TargetPids $capturedGatewayPids
    )
}
catch {
    $stopPhaseSucceeded = $false
    Write-Event "Hermes process termination failed: $($_.Exception.Message)"
}

Add-ReportSection 'Killed processes'

if ($killedProcesses.Count -gt 0) {
    foreach ($item in $killedProcesses) {
        Add-ReportLine $item
    }
}
else {
    Add-ReportLine 'None found.'
}

$servicesNotStopped = @()

foreach ($svc in $runningGatewayServices) {
    $currentService = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue

    if (-not $currentService) {
        $servicesNotStopped += $svc
    }
    elseif ($currentService.Status.ToString() -ne 'Stopped') {
        $servicesNotStopped += $currentService
    }
}


if ($servicesNotStopped.Count -gt 0) {
    $stopPhaseSucceeded = $false
    $serviceDetails = ($servicesNotStopped | ForEach-Object {
        "$($_.Name) [$($_.Status)]"
    }) -join ', '
    Write-Event "Gateway service(s) still active after stop phase: $serviceDetails"
}

$remainingHermesProcesses = @()

try {
    $processChain = @(Get-ProcessChain)
    $protectedPids = @($PID) + @($processChain | ForEach-Object { $_.ProcessId })
    $remainingHermesProcesses = @(
        Get-HermesProcesses -ExcludePids $protectedPids
    )
}
catch {
    $stopPhaseSucceeded = $false
    Write-Event "Could not verify remaining Hermes processes: $($_.Exception.Message)"
}

if ($remainingHermesProcesses.Count -gt 0) {
    $stopPhaseSucceeded = $false
    $processDetails = ($remainingHermesProcesses | ForEach-Object {
        "PID=$($_.ProcessId) Name=$($_.Name)"
    }) -join ', '
    Write-Event "Hermes process(es) still active after stop phase: $processDetails"
}

# Run update
$updateResult = $null
$updateExitCode = if ($stopPhaseSucceeded) { 0 } else { 8 }

if ($stopPhaseSucceeded) {
    try {
        Write-Event 'Starting hermes update --yes --backup --force'

        $updateResult = Invoke-HermesCommand `
            -Label 'update' `
            -Arguments @('update', '--yes', '--backup', '--force') `
            -TimeoutMinutes $UpdateTimeoutMinutes

        $updateExitCode = $updateResult.ExitCode

        if ($null -eq $updateExitCode) {
            $updateExitCode = 1
            Write-Log 'Hermes update returned no exit code; treating the update as failed.'
        }

        Set-Content -Path $UpdateOut -Value $updateResult.StdOut -Encoding UTF8
        Set-Content -Path $UpdateErr -Value $updateResult.StdErr -Encoding UTF8

        Write-Event "Update exit=$updateExitCode"

        if ($updateResult.StdOut) {
            Add-ReportBlock -Title 'Update - stdout' -Text $updateResult.StdOut
        }

        if ($updateResult.StdErr) {
            Add-ReportBlock -Title 'Update - stderr' -Text $updateResult.StdErr
        }
    }
    catch {
        $updateExitCode = 1
        Write-Log "Update exception: $($_.Exception.Message)"

        Add-ReportSection 'Update exception'
        Add-ReportLine $_.Exception.Message
    }
}
else {
    Write-Event 'Hermes update was skipped because the stop phase could not be verified.'
    Add-ReportSection 'Update skipped'
    Add-ReportLine 'Exit code 8: gateway services or Hermes processes remained active, or verification failed.'
}

$HermesVersionAfter = 'unknown'

if ($updateExitCode -eq 0) {
    if (-not (Test-Path -LiteralPath $HermesExe -PathType Leaf) -or
        -not (Test-Path -LiteralPath $HermesPython -PathType Leaf)) {
        $updateExitCode = 5
        Write-Event 'Update completed, but required Hermes executables are missing.'
    }
    else {
        try {
            $versionAfterResult = Invoke-HermesCommand `
                -Label 'version-after' `
                -Arguments @('--version') `
                -TimeoutMinutes 2

            if ($versionAfterResult.ExitCode -ne 0 -or
                [string]::IsNullOrWhiteSpace($versionAfterResult.StdOut)) {
                $updateExitCode = 5
                Write-Event 'Post-update Hermes health check failed: --version returned no usable version.'
            }
            else {
                $HermesVersionAfter = ($versionAfterResult.StdOut -split "`r?`n")[0].Trim()
                Write-Event "Hermes executables and version verified: $HermesVersionAfter"
            }
        }
        catch {
            $updateExitCode = 5
            Write-Event "Post-update Hermes health check failed: $($_.Exception.Message)"
        }
    }
}

# Restart gateway
if ($script:UnterminatedHermesCommand) {
    $restartExitCode = 3
    Add-ReportSection 'Gateway restart withheld'
    Add-ReportLine 'A timed-out Hermes command could not be confirmed terminated; starting the gateway would be unsafe.'
    Write-Log 'Normal gateway restart was withheld because an unterminated Hermes command may still be active.'
}
elseif ($restartMode -eq 'service') {
    Add-ReportSection 'Gateway restart'

    foreach ($svc in $runningGatewayServices) {
        try {
            Write-Event "Starting service $($svc.Name)"
            Start-Service -Name $svc.Name -ErrorAction Stop
            Add-ReportLine "Started service: $($svc.Name)"
        }
        catch {
            Write-Log "Start-Service failed for $($svc.Name): $($_.Exception.Message)"
            Add-ReportLine "Start-Service failed for $($svc.Name): $($_.Exception.Message)"
            $restartExitCode = 3
        }
    }

    foreach ($svc in $runningGatewayServices) {
        $currentService = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue

        if (-not $currentService -or
            $currentService.Status.ToString() -ne 'Running') {
            Write-Event "Service state was not restored to RUNNING: $($svc.Name)"
            $restartExitCode = 3
        }
    }

    try {
        Start-Sleep -Seconds 5

        $restartResult = Invoke-HermesCommand `
            -Label 'gateway-status-after' `
            -Arguments @('gateway', 'status', '--full')

        $serviceStatusText = "$($restartResult.StdOut)`r`n$($restartResult.StdErr)"

        if ($restartResult.ExitCode -ne 0 -or
            -not (Test-GatewayStatusIndicatesRunning -Text $serviceStatusText)) {
            $restartExitCode = 3
            Write-Event 'Gateway status did not confirm a running service gateway.'
        }

        $gatewayStatusAfterText = $restartResult.StdOut

        if ($restartResult.StdErr) {
            $gatewayStatusAfterText = $gatewayStatusAfterText + "`r`n" + $restartResult.StdErr
        }

        Set-Content `
            -Path $GatewayStatusAfterFile `
            -Value $gatewayStatusAfterText `
            -Encoding UTF8

        if ($restartResult.StdOut) {
            Add-ReportBlock -Title 'Gateway status after restart - stdout' -Text $restartResult.StdOut
        }

        if ($restartResult.StdErr) {
            Add-ReportBlock -Title 'Gateway status after restart - stderr' -Text $restartResult.StdErr
        }
    }
    catch {
        $restartExitCode = 3
        Write-Log "Gateway status check after service restart failed: $($_.Exception.Message)"
        Add-ReportLine "Gateway status check after service restart failed: $($_.Exception.Message)"
    }
}
elseif ($restartMode -eq 'scheduled-task') {
    Add-ReportSection 'Gateway restart'

    foreach ($task in $capturedGatewayScheduledTasks) {
        try {
            Write-Event "Starting Scheduled Task $($task.TaskPath)$($task.TaskName)"
            Start-ScheduledTask `
                -TaskPath $task.TaskPath `
                -TaskName $task.TaskName `
                -ErrorAction Stop
            Add-ReportLine "Started Scheduled Task: $($task.TaskPath)$($task.TaskName)"
        }
        catch {
            $restartExitCode = 3
            Write-Log "Start-ScheduledTask failed for $($task.TaskPath)$($task.TaskName): $($_.Exception.Message)"
            Add-ReportLine "Start-ScheduledTask failed for $($task.TaskPath)$($task.TaskName): $($_.Exception.Message)"
        }
    }

    try {
        Start-Sleep -Seconds $GatewayStartWaitSeconds

        $restartResult = Invoke-HermesCommand `
            -Label 'gateway-status-after' `
            -Arguments @('gateway', 'status', '--full')

        $taskStatusText = "$($restartResult.StdOut)`r`n$($restartResult.StdErr)"

        if ($restartResult.ExitCode -ne 0 -or
            -not (Test-GatewayStatusIndicatesRunning -Text $taskStatusText)) {
            $restartExitCode = 3
            Write-Event 'Gateway status did not confirm a running Scheduled Task gateway.'
        }

        $gatewayStatusAfterText = $restartResult.StdOut

        if ($restartResult.StdErr) {
            $gatewayStatusAfterText = $gatewayStatusAfterText + "`r`n" + $restartResult.StdErr
        }

        Set-Content `
            -Path $GatewayStatusAfterFile `
            -Value $gatewayStatusAfterText `
            -Encoding UTF8

        if ($restartResult.StdOut) {
            Add-ReportBlock -Title 'Gateway status after restart - stdout' -Text $restartResult.StdOut
        }

        if ($restartResult.StdErr) {
            Add-ReportBlock -Title 'Gateway status after restart - stderr' -Text $restartResult.StdErr
        }
    }
    catch {
        $restartExitCode = 3
        Write-Log "Gateway Scheduled Task restart check failed: $($_.Exception.Message)"
        Add-ReportLine "Gateway Scheduled Task restart check failed: $($_.Exception.Message)"
    }
}
else {
    Add-ReportSection 'Gateway restart'
    Add-ReportLine 'Gateway was not running before update, so it was left stopped.'

    try {
        $restartResult = Invoke-HermesCommand `
            -Label 'gateway-status-after' `
            -Arguments @('gateway', 'status', '--full')

        $stoppedStatusText = "$($restartResult.StdOut)`r`n$($restartResult.StdErr)"

        if ($restartResult.ExitCode -ne 0 -or
            (Get-GatewayStatusState -Text $stoppedStatusText) -ne 'Stopped') {
            $restartExitCode = 3
            Write-Event 'Gateway status did not confirm that the previously stopped gateway remained stopped.'
        }

        $gatewayStatusAfterText = $restartResult.StdOut

        if ($restartResult.StdErr) {
            $gatewayStatusAfterText = $gatewayStatusAfterText + "`r`n" + $restartResult.StdErr
        }

        Set-Content `
            -Path $GatewayStatusAfterFile `
            -Value $gatewayStatusAfterText `
            -Encoding UTF8

        if ($restartResult.StdOut) {
            Add-ReportBlock -Title 'Gateway status after update - stdout' -Text $restartResult.StdOut
        }

        if ($restartResult.StdErr) {
            Add-ReportBlock -Title 'Gateway status after update - stderr' -Text $restartResult.StdErr
        }
    }
    catch {
        $restartExitCode = 3
        Write-Log "Gateway status check after update failed: $($_.Exception.Message)"
        Add-ReportLine "Gateway status check after update failed: $($_.Exception.Message)"
    }
}

if ($gatewayRestorationRequired -and $restartExitCode -eq 0) {
    $gatewayRestorationRequired = $false
}
}
finally {
    if ($gatewayRestorationRequired) {
        if ($script:UnterminatedHermesCommand) {
            $restartExitCode = 3
            Write-Log 'Gateway restoration was withheld because a timed-out Hermes command could not be confirmed terminated.'
            Add-ReportLine 'CRITICAL: gateway restoration was withheld because an unterminated Hermes command may still be active.'
        }
        else {
            $restoredInFinally = Restore-HermesGatewayBackend `
                -Mode $restartMode `
                -Services $runningGatewayServices `
                -ScheduledTasks $capturedGatewayScheduledTasks

            if ($restoredInFinally) {
                Write-Log 'Captured gateway backend was restored by the safety finally block.'
                $gatewayRestorationRequired = $false
            }
            else {
                $restartExitCode = 3
                Write-Log 'Safety finally block could not restore every captured gateway backend.'
            }
        }
    }
}

$HermesVersionAfterInfo = ConvertTo-HermesVersionInfo -VersionText $HermesVersionAfter
$revisionDisplay = if ($HermesVersionBeforeInfo.Revision -eq $HermesVersionAfterInfo.Revision) {
    "$($HermesVersionAfterInfo.Revision) (unchanged)"
}
else {
    "$($HermesVersionBeforeInfo.Revision) => $($HermesVersionAfterInfo.Revision)"
}

$commitSummary = 'unknown'
$backupSize = 'not reported'

if ($updateResult -and $updateResult.StdOut) {
    if ($updateResult.StdOut -match '(?i)Found\s+(\d+)\s+new commit') {
        $commitSummary = "$($Matches[1]) new commit(s)"
    }
    elseif ($updateResult.StdOut -match '(?i)Already up to date') {
        $commitSummary = '0 (already current)'
    }

    if ($updateResult.StdOut -match '(?im)^\s*Saved:\s+.*\(([\d\.,]+\s+(?:KB|MB|GB|TB)),\s*[\d\.,]+s\)') {
        $backupSize = $Matches[1]
    }
}

$RunFinishedAt = Get-Date
$RunDuration = $RunFinishedAt - $RunStartedAt
$InstallSizeAfterBytes = Get-DirectorySizeBytes -Path $HermesRepo
$InstallSizeDeltaBytes = $InstallSizeAfterBytes - $InstallSizeBeforeBytes

$gatewayServiceAfter = Get-Service -Name $GatewayServiceName -ErrorAction SilentlyContinue
$gatewayServiceStatus = if ($null -eq $gatewayServiceAfter) {
    'NOT FOUND'
}
else {
    $gatewayServiceAfter.Status.ToString().ToUpperInvariant()
}

$gatewayServicePidAfter = Get-ServiceProcessId -ServiceName $GatewayServiceName

if ($gatewayServicePidAfter -le 0 -and $null -ne $restartResult) {
    $gatewayStatusPidText = "$($restartResult.StdOut)`n$($restartResult.StdErr)"

    if ($gatewayStatusPidText -match '(?i)PID:\s*(\d+)') {
        $gatewayServicePidAfter = [int]$Matches[1]
    }
}

$gatewayServicePidAfterText = if ($gatewayServicePidAfter -gt 0) {
    $gatewayServicePidAfter.ToString()
}
else {
    'not available'
}

$installationStatus = if ($updateExitCode -eq 0) {
    'SUCCESS'
}
else {
    "FAILED (exit $updateExitCode)"
}

$gatewayStatusCheckExit = if ($null -ne $restartResult -and $null -ne $restartResult.ExitCode) {
    $restartResult.ExitCode
}
else {
    'not available'
}

$gatewayExpectedState = if ($restartMode -eq 'none') { 'Stopped' } else { 'Running' }
$gatewayObservedState = if ($null -ne $restartResult) {
    Get-GatewayStatusState -Text "$($restartResult.StdOut)`r`n$($restartResult.StdErr)"
}
else {
    'Unknown'
}
$gatewayBackendDisplay = switch ($restartMode) {
    'service' { 'Windows service' }
    'scheduled-task' { 'official Hermes_Gateway Scheduled Task' }
    default { 'intentionally stopped' }
}

$overallStatus = if ($updateExitCode -ne 0) {
    'FAILED'
}
elseif ($restartExitCode -ne 0) {
    'WARNING'
}
else {
    'SUCCESS'
}

# Summary
Add-ReportSection 'Summary'
Add-ReportLine "Update exit code: $updateExitCode"
Add-ReportLine "Gateway restart mode: $restartMode"
Add-ReportLine "Gateway backend: $gatewayBackendDisplay"
Add-ReportLine "Gateway expected state: $gatewayExpectedState"
Add-ReportLine "Gateway observed state: $gatewayObservedState"
Add-ReportLine "Restart exit code: $restartExitCode"
Add-ReportLine "Overall status: $overallStatus"
Add-ReportLine "Start webhook exit code: $startWebhookExitCode"
Add-ReportLine "Preflight repair: $repairStatusText"
Add-ReportLine "Update started: $($RunStartedAt.ToString('yyyy-MM-dd HH:mm:ss K'))"
Add-ReportLine "Update finished: $($RunFinishedAt.ToString('yyyy-MM-dd HH:mm:ss K'))"
Add-ReportLine "Update duration: $(Format-Duration -Duration $RunDuration)"
Add-ReportLine "Hermes version before: $HermesVersionBefore"
Add-ReportLine "Hermes version after: $HermesVersionAfter"
Add-ReportLine "Commits: $commitSummary"
Add-ReportLine "Backup size: $backupSize"
Add-ReportLine "Installation size before: $(Format-ByteSize -Bytes $InstallSizeBeforeBytes)"
Add-ReportLine "Installation size after: $(Format-ByteSize -Bytes $InstallSizeAfterBytes)"
Add-ReportLine "Installation size delta: $(Format-ByteDelta -Bytes $InstallSizeDeltaBytes)"
Add-ReportLine "Legacy Windows service status after update: $gatewayServiceStatus"
Add-ReportLine "Gateway PID after update: $gatewayServicePidAfterText"
Add-ReportLine "Gateway status before file: $GatewayStatusBeforeFile"
Add-ReportLine "Gateway status after file: $GatewayStatusAfterFile"
Add-ReportLine "Update stdout file: $UpdateOut"
Add-ReportLine "Update stderr file: $UpdateErr"
Add-ReportLine "Gateway stop stdout file: $GatewayStopOut"
Add-ReportLine "Gateway stop stderr file: $GatewayStopErr"
Add-ReportLine "Log file: $LogFile"

Save-Report

# Final webhook report
$overallEmoji = if ($overallStatus -eq 'SUCCESS') {
    $EmojiCheck
}
elseif ($overallStatus -eq 'WARNING') {
    $EmojiWarning
}
else {
    $EmojiCross
}

$installationEmoji = if ($updateExitCode -eq 0) { $EmojiCheck } else { $EmojiCross }
$gatewayEmoji = if ($gatewayObservedState -eq $gatewayExpectedState -and
    $restartExitCode -eq 0) { $EmojiCheck } else { $EmojiWarning }
$statusCircle = if ($overallStatus -eq 'SUCCESS') {
    $EmojiGreenCircle
}
elseif ($overallStatus -eq 'WARNING') {
    $EmojiYellowCircle
}
else {
    $EmojiRedCircle
}

$finalColor = if ($overallStatus -eq 'SUCCESS') {
    5763719
}
elseif ($overallStatus -eq 'WARNING') {
    16705372
}
else {
    15548997
}

$finalDescription = if ($overallStatus -eq 'SUCCESS') {
    if ($restartMode -eq 'none') {
        'Hermes was updated successfully and the gateway remained intentionally stopped.'
    }
    else {
        "Hermes was updated successfully and the gateway was restored through its $gatewayBackendDisplay."
    }
}
elseif ($overallStatus -eq 'WARNING') {
    'The update completed, but the gateway or restart result requires attention.'
}
else {
    'The Hermes installation update failed. Review the attached report.'
}

$finalEmbed = @{
    title       = "$statusCircle Hermes Self-Update $overallStatus"
    description = $finalDescription
    color       = $finalColor
    timestamp   = $RunFinishedAt.ToUniversalTime().ToString('o')
    fields      = @(
        @{
            name   = 'Server ID'
            value  = $env:COMPUTERNAME
            inline = $true
        },
        @{
            name   = 'Result'
            value  = "$overallEmoji $overallStatus"
            inline = $true
        },
        @{
            name   = 'Duration'
            value  = "$(Format-Duration -Duration $RunDuration)"
            inline = $true
        },
        @{
            name   = 'Started'
            value  = $RunStartedAt.ToString('yyyy-MM-ddTHH:mm:ssK')
            inline = $true
        },
        @{
            name   = 'Finished'
            value  = $RunFinishedAt.ToString('yyyy-MM-ddTHH:mm:ssK')
            inline = $true
        },
        @{
            name   = 'Gateway backend'
            value  = "$gatewayEmoji $gatewayBackendDisplay`nExpected: $gatewayExpectedState | Observed: $gatewayObservedState`nPID: $gatewayServicePidAfterText"
            inline = $true
        },
        @{
            name   = 'Version Before'
            value  = $HermesVersionBeforeInfo.Version
            inline = $true
        },
        @{
            name   = 'Version After'
            value  = $HermesVersionAfterInfo.Version
            inline = $true
        },
        @{
            name   = 'Revision'
            value  = $revisionDisplay
            inline = $true
        },
        @{
            name   = 'Changes'
            value  = $commitSummary
            inline = $true
        },
        @{
            name   = 'Backup'
            value  = $backupSize
            inline = $true
        },
        @{
            name   = 'Size Change'
            value  = (Format-ByteDelta -Bytes $InstallSizeDeltaBytes)
            inline = $true
        },
        @{
            name   = 'Installation Size'
            value  = "**Before:** $(Format-ByteSize -Bytes $InstallSizeBeforeBytes) | **After:** $(Format-ByteSize -Bytes $InstallSizeAfterBytes)"
            inline = $false
        },
        @{
            name   = 'Update Exit'
            value  = "$updateExitCode"
            inline = $true
        },
        @{
            name   = 'Restart Exit'
            value  = "$restartExitCode"
            inline = $true
        },
        @{
            name   = 'Gateway Check'
            value  = "$gatewayStatusCheckExit"
            inline = $true
        },
        @{
            name   = 'Restart Mode'
            value  = $restartMode
            inline = $false
        },
        @{
            name   = 'Preflight Repair'
            value  = $repairStatusText
            inline = $false
        }
    )
    footer      = @{
        text = 'Hermes Update Observer | Detailed report follows below'
    }
}

$webhookResult = $null
$reportWebhookResult = $null
$webhookExitCode = 0

try {
    # Send the result embed first. Discord places attachments above embeds
    # when both share one message, so the report is deliberately sent as a
    # second message after a short ordering delay.
    $webhookResult = Send-DiscordWebhookReport -Embed $finalEmbed

    Write-Event "Final status webhook exit=$($webhookResult.ExitCode)"

    Start-Sleep -Milliseconds 750

    $reportWebhookResult = Send-DiscordWebhookReport `
        -Summary "$EmojiPaperclip **Detailed update report - $env:COMPUTERNAME**" `
        -AttachmentPath $ReportFile

    Write-Event "Final report webhook exit=$($reportWebhookResult.ExitCode)"

    if ($webhookResult.ExitCode -ne 0) {
        $webhookExitCode = $webhookResult.ExitCode
    }
    elseif ($reportWebhookResult.ExitCode -ne 0) {
        $webhookExitCode = $reportWebhookResult.ExitCode
    }

    Write-Event "Combined final webhook exit=$webhookExitCode"

    if ($webhookResult.Response) {
        Add-ReportSection 'Final status webhook response'
        Add-ReportLine $webhookResult.Response
    }

    if ($reportWebhookResult.Response) {
        Add-ReportSection 'Final report webhook response'
        Add-ReportLine $reportWebhookResult.Response
    }
}
catch {
    $webhookExitCode = 4
    Write-Log "Final webhook send failed: $($_.Exception.Message)"

    Add-ReportSection 'Webhook error'
    Add-ReportLine $_.Exception.Message
}

Save-Report

Write-Event '=== self-update run finished ==='

$finalExitCode = $updateExitCode

if ($restartExitCode -ne 0 -and $finalExitCode -eq 0) {
    $finalExitCode = $restartExitCode
}

if ($webhookExitCode -ne 0) {
    Write-Log "Notification failed with exit $webhookExitCode; maintenance exit remains $finalExitCode."
}

exit $finalExitCode
