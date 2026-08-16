#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$InstallPath = 'C:\scripts',

    [ValidateNotNullOrEmpty()]
    [string]$StatePath = 'C:\ProgramData\HermesAgent-SelfUpdate',

    [ValidatePattern('^[^\\/:*?"<>|]+$')]
    [string]$TaskName = 'Hermes-Agent-SelfUpdate-Daily',

    [ValidateNotNullOrEmpty()]
    [string]$RepositoryUrl = 'https://github.com/don040/HermesAgent-Selfupdate.git',

    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$Branch = 'main',

    [ValidateNotNullOrEmpty()]
    [string]$HermesUserProfile = 'C:\Users\Administrator',

    [ValidatePattern('^(?:[01][0-9]|2[0-3]):[0-5][0-9]$')]
    [string]$DailyAt = '04:00'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$SupervisorFileName = 'Invoke-HermesSelfUpdate.ps1'
$script:FailureCount = 0
$script:WarningCount = 0
$script:GitExe = $null
$script:LocalHead = $null
$script:TaskEnabled = $null
$script:TaskState = 'Unavailable'
$script:NextRunTime = $null

function Add-Pass {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Output (('[PASS] {0}') -f $Message)
}

function Add-Failure {
    param([Parameter(Mandatory = $true)][string]$Message)

    $script:FailureCount++
    Write-Output (('[FAIL] {0}') -f $Message)
}

function Add-Warning {
    param([Parameter(Mandatory = $true)][string]$Message)

    $script:WarningCount++
    Write-Output (('[WARN] {0}') -f $Message)
}

function Get-NormalizedFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    $fullPath = [IO.Path]::GetFullPath($expanded)
    $root = [IO.Path]::GetPathRoot($fullPath)

    if ($fullPath.Length -gt $root.Length) {
        return $fullPath.TrimEnd('\', '/')
    }

    return $fullPath
}

function Test-PathsEqual {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Left,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -or
        [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }

    try {
        $normalizedLeft = Get-NormalizedFullPath -Path $Left
        $normalizedRight = Get-NormalizedFullPath -Path $Right
        return $normalizedLeft.Equals(
            $normalizedRight,
            [StringComparison]::OrdinalIgnoreCase
        )
    }
    catch {
        return $false
    }
}

function Get-NormalizedRepositoryUrl {
    param([Parameter(Mandatory = $true)][string]$Url)

    $normalized = $Url.Trim().Replace('\', '/').TrimEnd('/')
    $normalized = $normalized -replace '(?i)\.git$', ''
    return $normalized.ToLowerInvariant()
}

function Test-PowerShellScriptFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            Add-Failure "$Label is missing."
            return
        }

        $tokens = $null
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $Path,
            [ref]$tokens,
            [ref]$parseErrors
        )

        if ($parseErrors.Count -gt 0) {
            Add-Failure "$Label contains PowerShell parser errors."
            return
        }

        Add-Pass "$Label exists and parses successfully."
    }
    catch {
        Add-Failure "$Label could not be read or parsed."
    }
}

function Test-SecureFileSystemPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label,

        [ValidateSet('Any', 'Container', 'Leaf')]
        [string]$ExpectedType = 'Any',

        [switch]$Optional,

        [switch]$RequireProtectedDacl
    )

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            if (-not $Optional) {
                Add-Failure "$Label is missing; reparse-point and ACL checks were not possible."
            }

            return
        }

        $item = Get-Item -LiteralPath $Path -Force
    }
    catch {
        Add-Failure "$Label could not be inspected for reparse-point and ACL safety."
        return
    }

    if (($ExpectedType -eq 'Container' -and -not $item.PSIsContainer) -or
        ($ExpectedType -eq 'Leaf' -and $item.PSIsContainer)) {
        Add-Failure "$Label has the wrong filesystem item type."
        return
    }

    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Add-Failure "$Label is a reparse point."
        return
    }

    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $ownerSid = $acl.GetOwner(
            [Security.Principal.SecurityIdentifier]
        ).Value
        $accessRules = @($acl.GetAccessRules(
            $true,
            $true,
            [Security.Principal.SecurityIdentifier]
        ))
    }
    catch {
        Add-Failure "$Label ACL or owner could not be read."
        return
    }

    $systemSid = 'S-1-5-18'
    $administratorsSid = 'S-1-5-32-544'
    $approvedWriterSids = @($systemSid, $administratorsSid)
    $hasSecurityFailure = $false

    if ($RequireProtectedDacl -and -not $acl.AreAccessRulesProtected) {
        Add-Failure "$Label DACL is not protected from inheritance."
        $hasSecurityFailure = $true
    }

    if ($ownerSid -notin $approvedWriterSids) {
        Add-Failure "$Label owner is neither SYSTEM nor BUILTIN\Administrators."
        $hasSecurityFailure = $true
    }

    $writeMask = [int64](
        [Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::AppendData -bor
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    )
    $fullControlMask = [int64][Security.AccessControl.FileSystemRights]::FullControl
    $allowedRightsBySid = @{}
    $deniedRightsBySid = @{}

    foreach ($approvedSid in $approvedWriterSids) {
        $allowedRightsBySid[$approvedSid] = [int64]0
        $deniedRightsBySid[$approvedSid] = [int64]0
    }

    $unauthorizedWriterCount = 0

    foreach ($accessRule in $accessRules) {
        $identitySid = $accessRule.IdentityReference.Value
        $rights = [int64]$accessRule.FileSystemRights
        $grantsWrite = ($rights -band $writeMask) -ne 0

        if ($accessRule.AccessControlType -eq
            [Security.AccessControl.AccessControlType]::Allow) {
            if ($identitySid -in $approvedWriterSids) {
                $allowedRightsBySid[$identitySid] = (
                    [int64]$allowedRightsBySid[$identitySid] -bor $rights
                )
            }
            elseif ($grantsWrite) {
                $unauthorizedWriterCount++
            }
        }
        elseif ($identitySid -in $approvedWriterSids) {
            $deniedRightsBySid[$identitySid] = (
                [int64]$deniedRightsBySid[$identitySid] -bor $rights
            )
        }
    }

    if ($unauthorizedWriterCount -gt 0) {
        Add-Failure "$Label grants write-capable rights outside SYSTEM and BUILTIN\Administrators."
        $hasSecurityFailure = $true
    }

    foreach ($approvedSid in $approvedWriterSids) {
        $effectiveRights = (
            [int64]$allowedRightsBySid[$approvedSid] -band
            (-bnot [int64]$deniedRightsBySid[$approvedSid])
        )

        if (($effectiveRights -band $fullControlMask) -ne $fullControlMask) {
            $identityLabel = if ($approvedSid -eq $systemSid) {
                'SYSTEM'
            }
            else {
                'BUILTIN\Administrators'
            }

            Add-Failure "$Label does not grant effective FullControl to $identityLabel."
            $hasSecurityFailure = $true
        }
    }

    if (-not $hasSecurityFailure) {
        $daclDescription = if ($RequireProtectedDacl) {
            'protected owner/DACL'
        }
        else {
            'owner/DACL'
        }

        Add-Pass "$Label is not a reparse point and has the expected $daclDescription."
    }
}

function Get-GitExecutable {
    $candidates = New-Object System.Collections.Generic.List[string]
    $gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue

    if ($gitCommand -and $gitCommand.Source) {
        [void]$candidates.Add($gitCommand.Source)
    }

    if ($env:ProgramFiles) {
        [void]$candidates.Add((Join-Path $env:ProgramFiles 'Git\cmd\git.exe'))
        [void]$candidates.Add((Join-Path $env:ProgramFiles 'Git\bin\git.exe'))
    }

    if (${env:ProgramFiles(x86)}) {
        [void]$candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.exe'))
    }

    [void]$candidates.Add((
        Join-Path $HermesUserProfile 'AppData\Local\hermes\git\cmd\git.exe'
    ))
    [void]$candidates.Add((
        Join-Path $HermesUserProfile 'AppData\Local\hermes\git\bin\git.exe'
    ))

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Get-Item -LiteralPath $candidate).FullName
        }
    }

    return $null
}

function Invoke-ReadOnlyGit {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $safeDirectory = $InstallPath.Replace('\', '/')
    $gitArguments = @(
        '--no-optional-locks',
        '-c', "safe.directory=$safeDirectory",
        '-C', $InstallPath
    ) + $Arguments

    $previousErrorActionPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $script:GitExe @gitArguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0) {
        throw "Git read operation failed with exit code $exitCode."
    }

    return (($output | ForEach-Object { $_.ToString() }) -join "`r`n").Trim()
}

function ConvertTo-CommandLine {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $escaped = foreach ($argument in $Arguments) {
        if ($null -eq $argument -or $argument.Length -eq 0) {
            '""'
            continue
        }

        if ($argument -notmatch '[\s"]') {
            $argument
            continue
        }

        $value = $argument -replace '(\\*)"', '$1$1\"'
        $value = $value -replace '(\\+)$', '$1$1'
        '"' + $value + '"'
    }

    return ($escaped -join ' ')
}

function Test-RepositoryState {
    $gitMetadataPath = Join-Path $InstallPath '.git'

    if (-not (Test-Path -LiteralPath $gitMetadataPath -PathType Container)) {
        Add-Failure 'The install directory is not a managed Git checkout (.git is missing).'
        return
    }

    Add-Pass 'The install directory contains Git metadata.'

    try {
        $script:GitExe = Get-GitExecutable
    }
    catch {
        $script:GitExe = $null
    }

    if (-not $script:GitExe) {
        Add-Failure 'git.exe was not found on PATH, in Program Files, or in Hermes Portable Git.'
        return
    }

    Add-Pass 'git.exe is available (including Hermes Portable Git locations).'
    Add-Pass 'Git checks use a per-command safe.directory override and disable optional locks.'

    try {
        $actualRemote = Invoke-ReadOnlyGit -Arguments @(
            'remote', 'get-url', 'origin'
        )

        if ((Get-NormalizedRepositoryUrl -Url $actualRemote) -eq
            (Get-NormalizedRepositoryUrl -Url $RepositoryUrl)) {
            Add-Pass 'The origin remote matches the configured repository.'
        }
        else {
            Add-Failure 'The origin remote does not match the configured repository.'
        }
    }
    catch {
        Add-Failure 'The origin remote could not be read.'
    }

    try {
        $currentBranch = Invoke-ReadOnlyGit -Arguments @(
            'rev-parse', '--abbrev-ref', 'HEAD'
        )

        if ($currentBranch -ceq $Branch) {
            Add-Pass 'The checked-out branch matches the configured branch.'
        }
        else {
            Add-Failure 'The checked-out branch does not match the configured branch.'
        }
    }
    catch {
        Add-Failure 'The checked-out branch could not be determined.'
    }

    $localHead = $null
    $remoteHead = $null

    try {
        $localHead = Invoke-ReadOnlyGit -Arguments @(
            'rev-parse', '--verify', 'HEAD^{commit}'
        )

        if ($localHead -match '^[0-9a-f]{40}$') {
            $script:LocalHead = $localHead
            Add-Pass "Local HEAD commit: $localHead"
        }
        else {
            Add-Failure 'The local HEAD did not resolve to a valid commit.'
            $localHead = $null
        }
    }
    catch {
        Add-Failure 'The local HEAD commit could not be read.'
    }

    try {
        $remoteReference = "refs/remotes/origin/${Branch}^{commit}"
        $remoteHead = Invoke-ReadOnlyGit -Arguments @(
            'rev-parse', '--verify', $remoteReference
        )

        if ($remoteHead -match '^[0-9a-f]{40}$') {
            Add-Pass "The existing origin/$Branch reference is available locally (no fetch performed)."
        }
        else {
            Add-Failure "The existing origin/$Branch reference is not a valid commit."
            $remoteHead = $null
        }
    }
    catch {
        Add-Failure "The existing origin/$Branch reference is unavailable; no fetch was performed."
    }

    if ($localHead -and $remoteHead) {
        if ($localHead -ceq $remoteHead) {
            Add-Pass "The local HEAD matches the existing origin/$Branch reference."
        }
        else {
            Add-Failure "The local HEAD differs from the existing origin/$Branch reference."
        }
    }

    try {
        $trackedStatus = Invoke-ReadOnlyGit -Arguments @(
            'status', '--porcelain=v1', '--untracked-files=no'
        )

        if ([string]::IsNullOrWhiteSpace($trackedStatus)) {
            Add-Pass 'No tracked local changes are present.'
        }
        else {
            $changeCount = @(
                $trackedStatus -split "`r?`n" |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            ).Count
            Add-Failure "Tracked local changes are present ($changeCount status entries)."
        }
    }
    catch {
        Add-Failure 'Tracked local changes could not be inspected.'
    }
}

function Test-SupervisorCopy {
    $repositorySupervisor = Join-Path $InstallPath $SupervisorFileName
    $installedSupervisor = Join-Path $StatePath $SupervisorFileName

    if (-not (Test-Path -LiteralPath $repositorySupervisor -PathType Leaf) -or
        -not (Test-Path -LiteralPath $installedSupervisor -PathType Leaf)) {
        Add-Failure 'The repository and installed supervisor copies are both required for hash comparison.'
        return
    }

    try {
        $repositoryHash = (
            Get-FileHash -LiteralPath $repositorySupervisor -Algorithm SHA256
        ).Hash
        $installedHash = (
            Get-FileHash -LiteralPath $installedSupervisor -Algorithm SHA256
        ).Hash

        if ($repositoryHash -ceq $installedHash) {
            Add-Pass 'The installed supervisor is byte-identical to the repository copy (SHA-256).'
        }
        else {
            Add-Failure 'The installed supervisor does not match the repository copy (SHA-256).'
        }
    }
    catch {
        Add-Failure 'The supervisor copies could not be hashed.'
    }
}

function Test-ScheduledTaskConfiguration {
    $scheduledTaskCommand = Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue

    if (-not $scheduledTaskCommand) {
        Add-Failure 'The ScheduledTasks module is unavailable; the task could not be inspected.'
        return
    }

    try {
        $matchingTasks = @(
            Get-ScheduledTask `
                -TaskPath '\' `
                -TaskName $TaskName `
                -ErrorAction Stop
        )
    }
    catch {
        Add-Failure 'The scheduled task is missing or could not be read.'
        return
    }

    if ($matchingTasks.Count -ne 1) {
        Add-Failure 'Exactly one matching scheduled task is required in the root task folder.'
        return
    }

    $task = $matchingTasks[0]
    Add-Pass 'The scheduled task exists in the root task folder.'

    try {
        $taskStateText = $task.State.ToString()

        switch ($taskStateText) {
            'Ready' {
                $script:TaskEnabled = $true
                $script:TaskState = 'Ready'
                Add-Pass 'The scheduled task is enabled (state: Ready).'
                break
            }
            'Running' {
                $script:TaskEnabled = $true
                $script:TaskState = 'Running'
                Add-Pass 'The scheduled task is enabled (state: Running).'
                break
            }
            'Queued' {
                $script:TaskEnabled = $true
                $script:TaskState = 'Queued'
                Add-Pass 'The scheduled task is enabled (state: Queued).'
                break
            }
            'Disabled' {
                $script:TaskEnabled = $false
                $script:TaskState = 'Disabled'
                Add-Failure 'The scheduled task is disabled.'
                break
            }
            default {
                $script:TaskEnabled = $null
                $script:TaskState = 'Unknown'
                Add-Failure 'The scheduled task enabled state could not be confirmed.'
            }
        }
    }
    catch {
        $script:TaskEnabled = $null
        $script:TaskState = 'Unavailable'
        Add-Failure 'The scheduled task enabled state could not be read.'
    }

    $scheduledTaskInfoCommand = Get-Command `
        Get-ScheduledTaskInfo `
        -ErrorAction SilentlyContinue

    if (-not $scheduledTaskInfoCommand) {
        Add-Failure 'Get-ScheduledTaskInfo is unavailable; NextRunTime could not be checked.'
    }
    else {
        try {
            $taskInfo = Get-ScheduledTaskInfo `
                -TaskPath '\' `
                -TaskName $TaskName `
                -ErrorAction Stop
            $nextRunTime = [datetime]$taskInfo.NextRunTime

            if ($nextRunTime -le [datetime]::MinValue.AddDays(1)) {
                Add-Failure 'The scheduled task does not report a valid NextRunTime.'
            }
            else {
                $script:NextRunTime = $nextRunTime
                $nextRunDisplay = $nextRunTime.ToString('yyyy-MM-dd HH:mm:ss')

                if ($nextRunTime -gt (Get-Date)) {
                    Add-Pass "Next scheduled run: $nextRunDisplay local time."
                }
                else {
                    Add-Failure "NextRunTime is not in the future: $nextRunDisplay local time."
                }
            }
        }
        catch {
            Add-Failure 'Scheduled task runtime information or NextRunTime could not be read.'
        }
    }

    try {
        if ($task.Principal.UserId -in @(
            'SYSTEM',
            'NT AUTHORITY\SYSTEM',
            'S-1-5-18'
        )) {
            Add-Pass 'The scheduled task runs as LOCAL SYSTEM.'
        }
        else {
            Add-Failure 'The scheduled task does not run as LOCAL SYSTEM.'
        }
    }
    catch {
        Add-Failure 'The scheduled task principal could not be read.'
    }

    try {
        if ($task.Principal.RunLevel.ToString() -eq 'Highest') {
            Add-Pass 'The scheduled task uses the Highest run level.'
        }
        else {
            Add-Failure 'The scheduled task does not use the Highest run level.'
        }
    }
    catch {
        Add-Failure 'The scheduled task run level could not be read.'
    }

    try {
        if ($task.Principal.LogonType.ToString() -eq 'ServiceAccount') {
            Add-Pass 'The scheduled task uses the ServiceAccount logon type.'
        }
        else {
            Add-Failure 'The scheduled task does not use the ServiceAccount logon type.'
        }
    }
    catch {
        Add-Failure 'The scheduled task logon type could not be read.'
    }

    $actions = @($task.Actions)

    if ($actions.Count -ne 1) {
        Add-Failure 'The scheduled task must contain exactly one action.'
    }
    else {
        $action = $actions[0]
        $installedSupervisor = Join-Path $StatePath $SupervisorFileName
        $systemRoot = $env:SystemRoot

        if ([string]::IsNullOrWhiteSpace($systemRoot)) {
            Add-Failure 'The expected Windows PowerShell executable could not be determined.'
        }
        else {
            $expectedPowerShell = Join-Path $systemRoot (
                'System32\WindowsPowerShell\v1.0\powershell.exe'
            )

            if (Test-PathsEqual -Left $action.Execute -Right $expectedPowerShell) {
                Add-Pass 'The task action launches Windows PowerShell 5.1.'
            }
            else {
                Add-Failure 'The task action does not launch the expected Windows PowerShell executable.'
            }
        }

        $expectedArguments = ConvertTo-CommandLine -Arguments @(
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy', 'Bypass',
            '-File', $installedSupervisor,
            '-InstallPath', $InstallPath,
            '-RepositoryUrl', $RepositoryUrl,
            '-Branch', $Branch,
            '-StatePath', $StatePath,
            '-HermesUserProfile', $HermesUserProfile
        )

        if ($action.Arguments -ieq $expectedArguments) {
            Add-Pass 'The task action targets the installed supervisor with the current parameter interface.'
        }
        else {
            Add-Failure 'The task action does not match the installed supervisor parameter interface.'
        }

        if (Test-PathsEqual -Left $action.WorkingDirectory -Right $StatePath) {
            Add-Pass 'The task working directory matches the state directory.'
        }
        else {
            Add-Failure 'The task working directory does not match the state directory.'
        }
    }

    $triggers = @($task.Triggers)

    if ($triggers.Count -ne 1) {
        Add-Failure 'The scheduled task must contain exactly one trigger.'
    }
    else {
        $trigger = $triggers[0]
        $triggerClassName = ''

        try {
            if ($trigger.CimClass -and $trigger.CimClass.CimClassName) {
                $triggerClassName = $trigger.CimClass.CimClassName
            }
        }
        catch {
            $triggerClassName = ''
        }

        if ($triggerClassName -eq 'MSFT_TaskDailyTrigger') {
            Add-Pass 'The scheduled task uses a daily trigger.'
        }
        else {
            Add-Failure 'The scheduled task trigger is not a daily trigger.'
        }

        $daysIntervalProperty = $trigger.PSObject.Properties['DaysInterval']

        if ($null -eq $daysIntervalProperty -or
            $null -eq $daysIntervalProperty.Value) {
            Add-Warning 'The daily trigger interval is not readable on this system.'
        }
        elseif ([int]$daysIntervalProperty.Value -eq 1) {
            Add-Pass 'The daily trigger repeats every day.'
        }
        else {
            Add-Failure 'The daily trigger does not repeat every day.'
        }

        try {
            $startBoundary = [datetime]$trigger.StartBoundary

            if ($startBoundary.ToString('HH:mm') -eq $DailyAt) {
                Add-Pass "The daily trigger starts at $DailyAt local time."
            }
            else {
                Add-Failure "The daily trigger is not configured for $DailyAt local time."
            }
        }
        catch {
            Add-Failure 'The daily trigger start time could not be read.'
        }
    }

    $settings = $null

    try {
        $settings = $task.Settings
    }
    catch {
        $settings = $null
    }

    if ($null -eq $settings) {
        Add-Warning 'Task settings are not readable; StartWhenAvailable and IgnoreNew were not evaluated.'
        return
    }

    try {
        $startWhenAvailableProperty = $settings.PSObject.Properties[
            'StartWhenAvailable'
        ]

        if ($null -eq $startWhenAvailableProperty -or
            $null -eq $startWhenAvailableProperty.Value) {
            Add-Warning 'StartWhenAvailable is not readable on this system.'
        }
        elseif ([Convert]::ToBoolean($startWhenAvailableProperty.Value)) {
            Add-Pass 'StartWhenAvailable is enabled.'
        }
        else {
            Add-Failure 'StartWhenAvailable is not enabled.'
        }
    }
    catch {
        Add-Warning 'StartWhenAvailable is not readable on this system.'
    }

    try {
        $multipleInstancesProperty = $settings.PSObject.Properties[
            'MultipleInstances'
        ]

        if ($null -eq $multipleInstancesProperty -or
            $null -eq $multipleInstancesProperty.Value) {
            Add-Warning 'The multiple-instance policy is not readable on this system.'
        }
        elseif ($multipleInstancesProperty.Value.ToString() -eq 'IgnoreNew') {
            Add-Pass 'The multiple-instance policy is IgnoreNew.'
        }
        else {
            Add-Failure 'The multiple-instance policy is not IgnoreNew.'
        }
    }
    catch {
        Add-Warning 'The multiple-instance policy is not readable on this system.'
    }
}

function Write-FinalSummary {
    $headSummary = if ($script:LocalHead) {
        $script:LocalHead
    }
    else {
        'Unavailable'
    }

    $taskSummary = if ($null -eq $script:TaskEnabled) {
        $script:TaskState
    }
    elseif ($script:TaskEnabled) {
        "Enabled ($($script:TaskState))"
    }
    else {
        'Disabled'
    }

    $nextRunSummary = if ($script:NextRunTime) {
        $script:NextRunTime.ToString('yyyy-MM-dd HH:mm:ss') + ' local time'
    }
    else {
        'Unavailable'
    }

    Write-Output ''
    Write-Output 'Final summary'
    Write-Output "  HEAD commit: $headSummary"
    Write-Output "  Scheduled task: $taskSummary"
    Write-Output "  Next run: $nextRunSummary"
    Write-Output "  Failed checks: $($script:FailureCount)"
    Write-Output "  Warnings: $($script:WarningCount)"
}

Write-Output 'Hermes self-update installation check (read-only)'
Write-Output 'No repository fetch, task start, or configuration change will be performed.'
Write-Output ''

try {
    $InstallPath = Get-NormalizedFullPath -Path $InstallPath
    $StatePath = Get-NormalizedFullPath -Path $StatePath
    $HermesUserProfile = Get-NormalizedFullPath -Path $HermesUserProfile
}
catch {
    Add-Failure 'One or more configured paths are invalid.'
    Write-FinalSummary
    Write-Output 'RESULT: FAILED (1 failed check)'
    exit 1
}

$repositoryFiles = @(
    'Hermes-SelfUpdate.ps1',
    'Invoke-HermesSelfUpdate.ps1',
    'Install-HermesSelfUpdate.ps1',
    'Test-HermesSelfUpdateInstallation.ps1'
)

foreach ($fileName in $repositoryFiles) {
    Test-PowerShellScriptFile `
        -Path (Join-Path $InstallPath $fileName) `
        -Label "Repository file '$fileName'"
}

Test-PowerShellScriptFile `
    -Path (Join-Path $StatePath $SupervisorFileName) `
    -Label 'Installed supervisor copy'

$securityTargets = @(
    [pscustomobject]@{
        Path          = $InstallPath
        Label         = 'Install directory'
        ExpectedType  = 'Container'
        Optional      = $false
        ProtectedDacl = $true
    },
    [pscustomobject]@{
        Path          = $StatePath
        Label         = 'State directory'
        ExpectedType  = 'Container'
        Optional      = $false
        ProtectedDacl = $true
    },
    [pscustomobject]@{
        Path          = (Join-Path $InstallPath '.git')
        Label         = 'Git metadata directory'
        ExpectedType  = 'Container'
        Optional      = $false
        ProtectedDacl = $false
    },
    [pscustomobject]@{
        Path          = (Join-Path $InstallPath '.git\config')
        Label         = 'Git configuration file'
        ExpectedType  = 'Leaf'
        Optional      = $false
        ProtectedDacl = $false
    },
    [pscustomobject]@{
        Path          = (Join-Path $InstallPath '.git\HEAD')
        Label         = 'Git HEAD file'
        ExpectedType  = 'Leaf'
        Optional      = $false
        ProtectedDacl = $false
    },
    [pscustomobject]@{
        Path          = (Join-Path $InstallPath '.git\index')
        Label         = 'Git index file'
        ExpectedType  = 'Leaf'
        Optional      = $false
        ProtectedDacl = $false
    },
    [pscustomobject]@{
        Path          = (Join-Path $InstallPath '.git\objects')
        Label         = 'Git objects directory'
        ExpectedType  = 'Container'
        Optional      = $false
        ProtectedDacl = $false
    },
    [pscustomobject]@{
        Path          = (Join-Path $InstallPath '.git\refs')
        Label         = 'Git refs directory'
        ExpectedType  = 'Container'
        Optional      = $false
        ProtectedDacl = $false
    },
    [pscustomobject]@{
        Path          = (Join-Path $InstallPath '.git\hooks')
        Label         = 'Git hooks directory'
        ExpectedType  = 'Container'
        Optional      = $false
        ProtectedDacl = $false
    }
)

foreach ($fileName in $repositoryFiles) {
    $securityTargets += [pscustomobject]@{
        Path          = (Join-Path $InstallPath $fileName)
        Label         = "Repository file '$fileName'"
        ExpectedType  = 'Leaf'
        Optional      = $false
        ProtectedDacl = $false
    }
}

$securityTargets += [pscustomobject]@{
    Path          = (Join-Path $StatePath $SupervisorFileName)
    Label         = 'Installed supervisor copy'
    ExpectedType  = 'Leaf'
    Optional      = $false
    ProtectedDacl = $false
}

$optionalStateDirectories = @(
    'Logs',
    'Runs',
    'Temp',
    'Staging',
    'MigrationBackup'
)

foreach ($directoryName in $optionalStateDirectories) {
    $securityTargets += [pscustomobject]@{
        Path          = (Join-Path $StatePath $directoryName)
        Label         = "State child directory '$directoryName'"
        ExpectedType  = 'Container'
        Optional      = $true
        ProtectedDacl = $false
    }
}

foreach ($securityTarget in $securityTargets) {
    Test-SecureFileSystemPath `
        -Path $securityTarget.Path `
        -Label $securityTarget.Label `
        -ExpectedType $securityTarget.ExpectedType `
        -Optional:$securityTarget.Optional `
        -RequireProtectedDacl:$securityTarget.ProtectedDacl
}

try {
    Test-RepositoryState
}
catch {
    Add-Failure 'The repository checks could not be completed.'
}

try {
    Test-SupervisorCopy
}
catch {
    Add-Failure 'The supervisor copy checks could not be completed.'
}

try {
    Test-ScheduledTaskConfiguration
}
catch {
    Add-Failure 'The scheduled task checks could not be completed.'
}

Write-FinalSummary

if ($script:FailureCount -gt 0) {
    Write-Output (
        'RESULT: FAILED ({0} failed check(s), {1} warning(s))' -f `
            $script:FailureCount,
            $script:WarningCount
    )
    exit 1
}

Write-Output (
    'RESULT: OK (0 failed checks, {0} warning(s))' -f $script:WarningCount
)
exit 0
