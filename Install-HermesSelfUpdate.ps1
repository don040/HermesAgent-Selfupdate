#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$InstallPath = 'C:\scripts',

    [ValidateNotNullOrEmpty()]
    [string]$RepositoryUrl = 'https://github.com/don040/HermesAgent-Selfupdate.git',

    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$Branch = 'main',

    [string]$StatePath = '',

    [ValidateNotNullOrEmpty()]
    [string]$HermesUserProfile = 'C:\Users\Administrator',

    [ValidatePattern('^[^\\/:*?"<>|]+$')]
    [string]$TaskName = 'Hermes-Agent-SelfUpdate-Daily',

    [ValidatePattern('^(?:[01][0-9]|2[0-3]):[0-5][0-9]$')]
    [string]$DailyAt = '04:00',

    [switch]$RunNow
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$SupervisorFileName = 'Invoke-HermesSelfUpdate.ps1'
$MainScriptFileName = 'Hermes-SelfUpdate.ps1'
$LegacyBackupPath = $null
$script:GitExe = $null
$script:HermesUserSid = $null

function Get-NormalizedFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    return [IO.Path]::GetFullPath($expanded).TrimEnd('\')
}

function Assert-SafeDirectoryPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $root = [IO.Path]::GetPathRoot($Path)

    if ([string]::IsNullOrWhiteSpace($root) -or
        $Path.TrimEnd('\') -eq $root.TrimEnd('\')) {
        throw "$Label must not be a filesystem root: $Path"
    }

    $currentPath = $Path

    while (-not [string]::IsNullOrWhiteSpace($currentPath)) {
        if (Test-Path -LiteralPath $currentPath) {
            $currentItem = Get-Item -LiteralPath $currentPath -Force

            if (($currentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Label path chain must not contain a reparse point: $currentPath"
            }
        }

        $parentPath = Split-Path -Parent $currentPath

        if ([string]::IsNullOrWhiteSpace($parentPath) -or
            $parentPath -eq $currentPath) {
            break
        }

        $currentPath = $parentPath
    }

    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force

        if (-not $item.PSIsContainer) {
            throw "$Label is not a directory: $Path"
        }

        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label must not be a reparse point: $Path"
        }
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

    [void]$candidates.Add((Join-Path $HermesUserProfile 'AppData\Local\hermes\git\cmd\git.exe'))
    [void]$candidates.Add((Join-Path $HermesUserProfile 'AppData\Local\hermes\git\bin\git.exe'))

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Get-Item -LiteralPath $candidate).FullName
        }
    }

    throw 'git.exe was not found on PATH, in Program Files, or in the default Hermes Portable Git installation.'
}

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $previousErrorActionPreference = $ErrorActionPreference

    try {
        # Windows PowerShell 5.1 turns native stderr redirected with 2>&1 into
        # ErrorRecord objects. Git writes normal progress to stderr, so native
        # success must be decided from the process exit code instead.
        $ErrorActionPreference = 'Continue'
        $output = @(& $script:GitExe @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $text = (($output | ForEach-Object { $_.ToString() }) -join "`r`n").Trim()

    if ($exitCode -ne 0) {
        $detail = if ($text) { "`r`n$text" } else { '' }
        throw "git failed with exit code $exitCode.$detail"
    }

    return $text
}

function Get-RepositoryArguments {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $safeDirectory = $RepositoryPath.Replace('\', '/')
    return @('-c', "safe.directory=$safeDirectory", '-C', $RepositoryPath) + $Arguments
}

function Get-NormalizedRepositoryUrl {
    param([Parameter(Mandatory = $true)][string]$Url)

    $normalized = $Url.Trim().Replace('\', '/').TrimEnd('/')
    $normalized = $normalized -replace '(?i)\.git$', ''
    return $normalized.ToLowerInvariant()
}

function Test-PowerShellFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required PowerShell file is missing: $Path"
    }

    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$parseErrors
    )

    if ($parseErrors.Count -gt 0) {
        $details = ($parseErrors | ForEach-Object { $_.Message }) -join '; '
        throw "PowerShell validation failed for ${Path}: $details"
    }
}

function Test-RepositoryLayout {
    param([Parameter(Mandatory = $true)][string]$RepositoryPath)

    if (-not (Test-Path -LiteralPath (Join-Path $RepositoryPath '.git') -PathType Container)) {
        throw "Git metadata is missing below: $RepositoryPath"
    }

    Assert-SafeDirectoryPath `
        -Path (Join-Path $RepositoryPath '.git') `
        -Label 'Git metadata directory'

    Test-PowerShellFile -Path (Join-Path $RepositoryPath $SupervisorFileName)
    Test-PowerShellFile -Path (Join-Path $RepositoryPath $MainScriptFileName)

    $actualRemote = Invoke-Git -Arguments (
        Get-RepositoryArguments $RepositoryPath @('remote', 'get-url', 'origin')
    )

    if ((Get-NormalizedRepositoryUrl $actualRemote) -ne
        (Get-NormalizedRepositoryUrl $RepositoryUrl)) {
        throw "Refusing checkout with unexpected origin '$actualRemote'. Expected '$RepositoryUrl'."
    }

    $currentBranch = Invoke-Git -Arguments (
        Get-RepositoryArguments $RepositoryPath @('rev-parse', '--abbrev-ref', 'HEAD')
    )

    if ($currentBranch -ne $Branch) {
        throw "Refusing checkout on branch '$currentBranch'. Expected '$Branch'."
    }
}

function Update-ExistingRepository {
    Test-RepositoryLayout -RepositoryPath $InstallPath

    $trackedChanges = Invoke-Git -Arguments (
        Get-RepositoryArguments $InstallPath @('status', '--porcelain', '--untracked-files=no')
    )

    if ($trackedChanges) {
        throw "Refusing to overwrite tracked local changes in ${InstallPath}:`r`n$trackedChanges"
    }

    Write-Host "Fetching $RepositoryUrl ($Branch)."
    $fetchRefSpec = "refs/heads/${Branch}:refs/remotes/origin/${Branch}"
    [void](Invoke-Git -Arguments (
        Get-RepositoryArguments $InstallPath @(
            'fetch', '--prune', '--no-tags', 'origin', $fetchRefSpec
        )
    ))
    [void](Invoke-Git -Arguments (
        Get-RepositoryArguments $InstallPath @('merge', '--ff-only', "origin/$Branch")
    ))

    $headCommit = Invoke-Git -Arguments (
        Get-RepositoryArguments $InstallPath @('rev-parse', 'HEAD')
    )
    $remoteCommit = Invoke-Git -Arguments (
        Get-RepositoryArguments $InstallPath @('rev-parse', "origin/$Branch")
    )

    if ($headCommit -ne $remoteCommit) {
        throw "Checkout did not converge to origin/$Branch. HEAD=$headCommit origin=$remoteCommit"
    }

    Test-RepositoryLayout -RepositoryPath $InstallPath
    return $headCommit
}

function Test-IsRecognizedLegacyInstall {
    param([Parameter(Mandatory = $true)][string]$Path)

    $entries = @(Get-ChildItem -LiteralPath $Path -Force)

    if ($entries.Count -eq 0) {
        return $true
    }

    return (
        $entries.Count -eq 1 -and
        -not $entries[0].PSIsContainer -and
        $entries[0].Name -ieq $MainScriptFileName
    )
}

function Remove-SafeStagingDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $stagingRoot = (Get-NormalizedFullPath (Join-Path $StatePath 'Staging')) + '\'
    $candidate = Get-NormalizedFullPath $Path

    if (-not $candidate.StartsWith($stagingRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing unsafe staging cleanup path: $candidate"
    }

    Remove-Item -LiteralPath $candidate -Recurse -Force
}

function Install-NewRepository {
    $stagingRoot = Join-Path $StatePath 'Staging'
    $migrationRoot = Join-Path $StatePath 'MigrationBackup'
    New-Item -ItemType Directory -Force -Path $stagingRoot, $migrationRoot | Out-Null
    Assert-SafeDirectoryPath -Path $stagingRoot -Label 'Staging directory'
    Assert-SafeDirectoryPath -Path $migrationRoot -Label 'Migration backup directory'

    $stagingPath = Join-Path $stagingRoot ([guid]::NewGuid().ToString('N'))
    $activated = $false
    $movedExistingInstall = $false

    try {
        Write-Host "Cloning $RepositoryUrl to a staging directory."
        [void](Invoke-Git -Arguments @(
            'clone',
            '--branch', $Branch,
            '--single-branch',
            '--no-tags',
            $RepositoryUrl,
            $stagingPath
        ))

        Test-RepositoryLayout -RepositoryPath $stagingPath

        if (Test-Path -LiteralPath $InstallPath) {
            if (-not (Test-IsRecognizedLegacyInstall -Path $InstallPath)) {
                $entries = @(
                    Get-ChildItem -LiteralPath $InstallPath -Force |
                        Select-Object -ExpandProperty Name
                )
                throw "Existing non-Git directory is not a recognized legacy install: $InstallPath. Contents: $($entries -join ', ')"
            }

            $backupName = 'Scripts-{0}-{1}' -f (
                Get-Date -Format 'yyyyMMdd-HHmmss'
            ), ([guid]::NewGuid().ToString('N').Substring(0, 8))
            $script:LegacyBackupPath = Join-Path $migrationRoot $backupName
            Move-Item -LiteralPath $InstallPath -Destination $script:LegacyBackupPath
            $movedExistingInstall = $true
            Set-SecureDirectoryAcl -Path $script:LegacyBackupPath
            Write-Host "Existing legacy directory preserved at: $script:LegacyBackupPath"
        }

        $installParent = Split-Path -Parent $InstallPath

        if (-not (Test-Path -LiteralPath $installParent -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $installParent | Out-Null
        }

        Move-Item -LiteralPath $stagingPath -Destination $InstallPath
        $activated = $true
        Test-RepositoryLayout -RepositoryPath $InstallPath
    }
    catch {
        if (-not $activated -and
            $movedExistingInstall -and
            -not (Test-Path -LiteralPath $InstallPath) -and
            (Test-Path -LiteralPath $script:LegacyBackupPath)) {
            Move-Item -LiteralPath $script:LegacyBackupPath -Destination $InstallPath
            $script:LegacyBackupPath = $null
        }

        throw
    }
    finally {
        if (-not $activated -and (Test-Path -LiteralPath $stagingPath)) {
            Remove-SafeStagingDirectory -Path $stagingPath
        }
    }

    return (Invoke-Git -Arguments (
        Get-RepositoryArguments $InstallPath @('rev-parse', 'HEAD')
    ))
}

function Set-SecureDirectoryAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    $items = New-Object System.Collections.Generic.List[object]
    $pendingDirectories = New-Object System.Collections.Generic.Stack[string]
    $pendingDirectories.Push($Path)

    while ($pendingDirectories.Count -gt 0) {
        $currentDirectory = $pendingDirectories.Pop()

        foreach ($item in @(Get-ChildItem -LiteralPath $currentDirectory -Force)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to secure a tree containing a reparse point: $($item.FullName)"
            }

            [void]$items.Add($item)

            if ($item.PSIsContainer) {
                $pendingDirectories.Push($item.FullName)
            }
        }
    }

    # Protected, exact DACLs: LOCAL SYSTEM (SY), the built-in local
    # Administrators group (BA), and the Hermes profile user retain access.
    # This removes inherited and pre-existing explicit ACEs from a
    # pre-created/squatted directory while allowing the least-privileged S4U
    # task to refresh the checkout and write its state.
    $userDirectoryAce = if ($script:HermesUserSid) {
        "(A;OICI;FA;;;$($script:HermesUserSid))"
    }
    else {
        ''
    }
    $userFileAce = if ($script:HermesUserSid) {
        "(A;;FA;;;$($script:HermesUserSid))"
    }
    else {
        ''
    }
    $directorySddl = 'O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)' + $userDirectoryAce
    $fileSddl = 'O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)' + $userFileAce

    $rootSecurity = New-Object Security.AccessControl.DirectorySecurity
    $rootSecurity.SetSecurityDescriptorSddlForm($directorySddl)
    [IO.Directory]::SetAccessControl($Path, $rootSecurity)

    foreach ($item in $items) {
        if ($item.PSIsContainer) {
            $security = New-Object Security.AccessControl.DirectorySecurity
            $security.SetSecurityDescriptorSddlForm($directorySddl)
            [IO.Directory]::SetAccessControl($item.FullName, $security)
        }
        else {
            $security = New-Object Security.AccessControl.FileSecurity
            $security.SetSecurityDescriptorSddlForm($fileSddl)
            [IO.File]::SetAccessControl($item.FullName, $security)
        }
    }
}

function Get-HermesProfileUserSid {
    $normalizedProfile = Get-NormalizedFullPath $HermesUserProfile

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

            $candidateProfile = Get-NormalizedFullPath $profileImagePath

            if ($candidateProfile.Equals($normalizedProfile, [StringComparison]::OrdinalIgnoreCase) -and
                $profileKey.PSChildName -match '^S-1-5-21-') {
                return $profileKey.PSChildName
            }
        }
    }
    catch {
        # Continue with ACL/account resolution for hosts without a readable
        # ProfileList registry key.
    }

    try {
        $profileAcl = Get-Acl -LiteralPath $HermesUserProfile -ErrorAction Stop
        $ownerSid = $profileAcl.GetOwner(
            [Security.Principal.SecurityIdentifier]
        ).Value

        if ($ownerSid -notin @('S-1-5-18', 'S-1-5-32-544') -and
            $ownerSid -match '^S-1-5-21-') {
            return $ownerSid
        }
    }
    catch {
        # Fall back to resolving the profile directory name as a local user.
    }

    $profileUser = Split-Path -Leaf $HermesUserProfile
    $account = New-Object Security.Principal.NTAccount(
        $env:COMPUTERNAME,
        $profileUser
    )
    return $account.Translate(
        [Security.Principal.SecurityIdentifier]
    ).Value
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

function Assert-TaskIsNotRunning {
    param([Parameter(Mandatory = $true)][string]$Name)

    $task = Get-ScheduledTask `
        -TaskPath '\' `
        -TaskName $Name `
        -ErrorAction SilentlyContinue

    if ($task -and $task.State.ToString() -in @('Running', 'Queued')) {
        throw "Scheduled Task '$Name' is running or queued. Wait for it to finish before reinstalling."
    }
}

function Remove-ObsoleteOneShotTask {
    $legacyTaskName = 'Hermes-OneShot-SelfUpdate'
    $legacyTask = Get-ScheduledTask `
        -TaskPath '\' `
        -TaskName $legacyTaskName `
        -ErrorAction SilentlyContinue

    if ($legacyTask) {
        Unregister-ScheduledTask `
            -TaskPath '\' `
            -TaskName $legacyTaskName `
            -Confirm:$false `
            -ErrorAction Stop
        Write-Output "Removed obsolete one-shot task: $legacyTaskName"
    }
}

function Register-DailyTask {
    $supervisorPath = Join-Path $StatePath $SupervisorFileName
    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) {
        throw "Windows PowerShell executable is missing: $powershellExe"
    }

    $taskArguments = ConvertTo-CommandLine @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', $supervisorPath,
        '-InstallPath', $InstallPath,
        '-RepositoryUrl', $RepositoryUrl,
        '-Branch', $Branch,
        '-StatePath', $StatePath,
        '-HermesUserProfile', $HermesUserProfile
    )

    $action = New-ScheduledTaskAction `
        -Execute $powershellExe `
        -Argument $taskArguments `
        -WorkingDirectory $StatePath

    $parsedTime = [datetime]::ParseExact(
        $DailyAt,
        'HH:mm',
        [Globalization.CultureInfo]::InvariantCulture
    )
    $firstRun = [datetime]::Today.Add($parsedTime.TimeOfDay)

    if ($firstRun -le (Get-Date)) {
        $firstRun = $firstRun.AddDays(1)
    }

    $trigger = New-ScheduledTaskTrigger `
        -Daily `
        -At $firstRun

    $principal = New-ScheduledTaskPrincipal `
        -UserId $script:HermesUserSid `
        -LogonType S4U `
        -RunLevel Limited

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours 2)

    Register-ScheduledTask `
        -TaskPath '\' `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description 'Refreshes the managed repository and updates Hermes as its least-privileged profile user.' `
        -Force | Out-Null
}

function Test-InstalledTask {
    $task = Get-ScheduledTask `
        -TaskPath '\' `
        -TaskName $TaskName `
        -ErrorAction Stop
    $expectedSupervisor = Join-Path $StatePath $SupervisorFileName
    $expectedPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    $taskPrincipalSid = ConvertTo-SidString $task.Principal.UserId

    if ($taskPrincipalSid -ne $script:HermesUserSid) {
        throw "Task principal does not match the Hermes profile user: $($task.Principal.UserId)"
    }

    if ($task.Principal.RunLevel.ToString() -ne 'Limited') {
        throw "Task does not use the Limited run level: $($task.Principal.RunLevel)"
    }

    if ($task.Principal.LogonType.ToString() -ne 'S4U') {
        throw "Task does not use S4U logon: $($task.Principal.LogonType)"
    }

    if ($task.State.ToString() -eq 'Disabled' -or
        ($null -ne $task.Settings.Enabled -and -not $task.Settings.Enabled)) {
        throw 'The installed daily task is disabled.'
    }

    $action = @($task.Actions)[0]
    $expectedArguments = ConvertTo-CommandLine @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', $expectedSupervisor,
        '-InstallPath', $InstallPath,
        '-RepositoryUrl', $RepositoryUrl,
        '-Branch', $Branch,
        '-StatePath', $StatePath,
        '-HermesUserProfile', $HermesUserProfile
    )

    if ($action.Execute -ine $expectedPowerShell -or
        $action.Arguments -ine $expectedArguments -or
        $action.WorkingDirectory -ine $StatePath) {
        throw 'Task action does not point to the installed supervisor.'
    }

    $trigger = @($task.Triggers)[0]
    $startBoundary = [datetime]$trigger.StartBoundary

    if ($startBoundary.ToString('HH:mm') -ne $DailyAt) {
        throw "Task trigger is not scheduled for ${DailyAt}: $($trigger.StartBoundary)"
    }

    if (-not $task.Settings.StartWhenAvailable -or
        $task.Settings.MultipleInstances.ToString() -ne 'IgnoreNew') {
        throw 'Task settings do not enforce StartWhenAvailable and IgnoreNew.'
    }

    return $task
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Installation requires an elevated Administrator PowerShell session.'
}

$InstallPath = Get-NormalizedFullPath $InstallPath
$HermesUserProfile = Get-NormalizedFullPath $HermesUserProfile

if ([string]::IsNullOrWhiteSpace($StatePath)) {
    $programData = if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }
    $StatePath = Join-Path $programData 'HermesAgent-SelfUpdate'
}

$StatePath = Get-NormalizedFullPath $StatePath
Assert-SafeDirectoryPath -Path $InstallPath -Label 'InstallPath'
Assert-SafeDirectoryPath -Path $StatePath -Label 'StatePath'
Assert-SafeDirectoryPath -Path $HermesUserProfile -Label 'HermesUserProfile'
$script:HermesUserSid = Get-HermesProfileUserSid

if ($InstallPath.StartsWith($StatePath + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $StatePath.StartsWith($InstallPath + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $InstallPath.Equals($StatePath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'InstallPath and StatePath must be separate, non-overlapping directories.'
}

$installMutex = New-Object Threading.Mutex($false, 'Global\HermesAgentSelfUpdate')
$hasInstallMutex = $false

try {
    try {
        $hasInstallMutex = $installMutex.WaitOne(0)
    }
    catch [Threading.AbandonedMutexException] {
        $hasInstallMutex = $true
    }

    if (-not $hasInstallMutex) {
        throw 'Another Hermes self-update supervisor or installer is already running.'
    }

Assert-TaskIsNotRunning -Name $TaskName
Assert-TaskIsNotRunning -Name 'Hermes-OneShot-SelfUpdate'
Remove-ObsoleteOneShotTask

New-Item -ItemType Directory -Force -Path $StatePath | Out-Null
Set-SecureDirectoryAcl -Path $StatePath
$script:GitExe = Get-GitExecutable
$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE = 'Never'
Write-Output "Using Git: $script:GitExe"

$isGitCheckout = Test-Path -LiteralPath (Join-Path $InstallPath '.git') -PathType Container
$commit = if ($isGitCheckout) {
    Update-ExistingRepository
}
else {
    Install-NewRepository
}

$installedSupervisor = Join-Path $StatePath $SupervisorFileName
Copy-Item `
    -LiteralPath (Join-Path $InstallPath $SupervisorFileName) `
    -Destination $installedSupervisor `
    -Force
Test-PowerShellFile -Path $installedSupervisor

Set-SecureDirectoryAcl -Path $InstallPath
Set-SecureDirectoryAcl -Path $StatePath
Register-DailyTask
$task = Test-InstalledTask
$taskInfo = Get-ScheduledTaskInfo -TaskPath '\' -TaskName $TaskName -ErrorAction Stop

if ([datetime]$taskInfo.NextRunTime -le (Get-Date)) {
    throw "Installed task does not report a future NextRunTime: $($taskInfo.NextRunTime)"
}

Write-Output ''
Write-Output 'Hermes self-update installation completed.'
Write-Output "Repository: $InstallPath"
Write-Output "Commit: $commit"
Write-Output "Supervisor: $installedSupervisor"
Write-Output "Scheduled Task: $TaskName"
Write-Output "Schedule: daily at $DailyAt local VM time"
Write-Output "Next run: $(([datetime]$taskInfo.NextRunTime).ToString('yyyy-MM-dd HH:mm:ss')) local VM time"
Write-Output "Run as: $($task.Principal.UserId) / S4U / $($task.Principal.RunLevel)"

if ($LegacyBackupPath) {
    Write-Output "Legacy backup: $LegacyBackupPath"
}

}
finally {
    if ($hasInstallMutex) {
        [void]$installMutex.ReleaseMutex()
    }

    $installMutex.Dispose()
}

if ($RunNow) {
    Start-ScheduledTask -TaskPath '\' -TaskName $TaskName
    Write-Output 'The Scheduled Task was started. Check task status and supervisor logs for the result.'
}
else {
    Write-Output "Manual start: Start-ScheduledTask -TaskName '$TaskName'"
}
