#Requires -Version 5.1

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

    [ValidateRange(1, 10)]
    [int]$FetchAttempts = 3,

    [ValidateRange(0, 300)]
    [int]$FetchRetrySeconds = 15,

    [ValidateRange(1, 100)]
    [int]$RetainedRunCount = 14
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$SupervisorFileName = 'Invoke-HermesSelfUpdate.ps1'
$MainScriptFileName = 'Hermes-SelfUpdate.ps1'
$script:LogFile = $null
$script:GitExe = $null

function Get-NormalizedFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    return [IO.Path]::GetFullPath($expanded).TrimEnd('\')
}

function Get-HermesProfileUserSid {
    param([Parameter(Mandatory = $true)][string]$ProfilePath)

    $normalizedProfile = Get-NormalizedFullPath $ProfilePath

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

            if ((Get-NormalizedFullPath $profileImagePath).Equals(
                    $normalizedProfile,
                    [StringComparison]::OrdinalIgnoreCase
                ) -and $profileKey.PSChildName -match '^S-1-5-21-') {
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

function Write-SupervisorLog {
    param([Parameter(Mandatory = $true)][string]$Message)

    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff K'), $Message
    # Keep log messages out of the success pipeline. Several orchestration
    # functions return a commit/path value that must not become a mixed array.
    Write-Host $line

    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
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
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $safeDirectory = $InstallPath.Replace('\', '/')
    return @('-c', "safe.directory=$safeDirectory", '-C', $InstallPath) + $Arguments
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

function Sync-ManagedRepository {
    if (-not (Test-Path -LiteralPath (Join-Path $InstallPath '.git') -PathType Container)) {
        throw "Managed Git checkout is missing at $InstallPath. Run Install-HermesSelfUpdate.ps1 again."
    }

    Assert-SafeDirectoryPath `
        -Path (Join-Path $InstallPath '.git') `
        -Label 'Git metadata directory'

    $actualRemote = Invoke-Git -Arguments (Get-RepositoryArguments @('remote', 'get-url', 'origin'))

    if ((Get-NormalizedRepositoryUrl $actualRemote) -ne
        (Get-NormalizedRepositoryUrl $RepositoryUrl)) {
        throw "Refusing checkout with unexpected origin '$actualRemote'. Expected '$RepositoryUrl'."
    }

    $currentBranch = Invoke-Git -Arguments (Get-RepositoryArguments @('rev-parse', '--abbrev-ref', 'HEAD'))

    if ($currentBranch -ne $Branch) {
        throw "Refusing checkout on branch '$currentBranch'. Expected '$Branch'."
    }

    $trackedChanges = Invoke-Git -Arguments (
        Get-RepositoryArguments @('status', '--porcelain', '--untracked-files=no')
    )

    if ($trackedChanges) {
        throw "Refusing to overwrite tracked local changes in ${InstallPath}:`r`n$trackedChanges"
    }

    $fetchError = $null
    $fetchRefSpec = "refs/heads/${Branch}:refs/remotes/origin/${Branch}"

    for ($attempt = 1; $attempt -le $FetchAttempts; $attempt++) {
        try {
            Write-SupervisorLog "Fetching origin/$Branch (attempt $attempt of $FetchAttempts)."
            [void](Invoke-Git -Arguments (
                Get-RepositoryArguments @(
                    'fetch', '--prune', '--no-tags', 'origin', $fetchRefSpec
                )
            ))
            $fetchError = $null
            break
        }
        catch {
            $fetchError = $_

            if ($attempt -lt $FetchAttempts) {
                Write-SupervisorLog "Fetch attempt failed: $($_.Exception.Message)"

                if ($FetchRetrySeconds -gt 0) {
                    Start-Sleep -Seconds $FetchRetrySeconds
                }
            }
        }
    }

    if ($fetchError) {
        throw $fetchError
    }

    [void](Invoke-Git -Arguments (
        Get-RepositoryArguments @('merge', '--ff-only', "origin/$Branch")
    ))

    $headCommit = Invoke-Git -Arguments (Get-RepositoryArguments @('rev-parse', 'HEAD'))
    $remoteCommit = Invoke-Git -Arguments (Get-RepositoryArguments @('rev-parse', "origin/$Branch"))

    if ($headCommit -ne $remoteCommit) {
        throw "Checkout did not converge to origin/$Branch. HEAD=$headCommit origin=$remoteCommit"
    }

    if ($headCommit -notmatch '^[0-9a-f]{40}$') {
        throw "Git returned an invalid commit id: $headCommit"
    }

    $trackedChangesAfter = Invoke-Git -Arguments (
        Get-RepositoryArguments @('status', '--porcelain', '--untracked-files=no')
    )

    if ($trackedChangesAfter) {
        throw "Checkout became dirty during synchronization:`r`n$trackedChangesAfter"
    }

    return $headCommit
}

function New-CommitSnapshot {
    param([Parameter(Mandatory = $true)][string]$Commit)

    $runId = '{0}-{1}-{2}' -f (
        Get-Date -Format 'yyyyMMdd-HHmmss'
    ), $Commit.Substring(0, 12), ([guid]::NewGuid().ToString('N').Substring(0, 8))

    $runPath = Join-Path $RunsPath $runId
    $archivePath = Join-Path $TemporaryPath "$runId.zip"

    New-Item -ItemType Directory -Path $runPath | Out-Null

    try {
        [void](Invoke-Git -Arguments (
            Get-RepositoryArguments @('archive', '--format=zip', "--output=$archivePath", $Commit)
        ))
        Expand-Archive -LiteralPath $archivePath -DestinationPath $runPath
    }
    catch {
        throw "Could not create executable snapshot for commit ${Commit}: $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
            Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        }
    }

    return $runPath
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

function Update-InstalledSupervisor {
    param([Parameter(Mandatory = $true)][string]$SnapshotPath)

    $source = Join-Path $SnapshotPath $SupervisorFileName
    $destination = Join-Path $StatePath $SupervisorFileName
    Test-PowerShellFile -Path $source

    $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $destinationHash = if (Test-Path -LiteralPath $destination -PathType Leaf) {
        (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    }
    else {
        ''
    }

    if ($sourceHash -ne $destinationHash) {
        $temporaryDestination = Join-Path $TemporaryPath (
            "$SupervisorFileName.$([guid]::NewGuid().ToString('N')).new"
        )

        Copy-Item -LiteralPath $source -Destination $temporaryDestination

        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            [IO.File]::Replace($temporaryDestination, $destination, $null, $true)
        }
        else {
            Move-Item -LiteralPath $temporaryDestination -Destination $destination
        }

        Write-SupervisorLog 'Installed supervisor refreshed for the next invocation.'
    }
}

function Remove-OldRunSnapshots {
    $runsRoot = (Get-NormalizedFullPath $RunsPath) + '\'
    $oldRuns = @(
        Get-ChildItem -LiteralPath $RunsPath -Directory -Force |
            Sort-Object CreationTimeUtc -Descending |
            Select-Object -Skip $RetainedRunCount
    )

    foreach ($oldRun in $oldRuns) {
        $candidate = Get-NormalizedFullPath $oldRun.FullName

        if (($oldRun.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Write-SupervisorLog "Refused reparse-point run cleanup path: $candidate"
            continue
        }

        if (-not $candidate.StartsWith($runsRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Write-SupervisorLog "Refused unsafe run cleanup path: $candidate"
            continue
        }

        Remove-Item -LiteralPath $candidate -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$mutex = $null
$hasMutex = $false
$exitCode = 100
$startedAt = Get-Date
$LogsPath = $null
$RunsPath = $null
$TemporaryPath = $null

try {
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
$expectedHermesUserSid = Get-HermesProfileUserSid -ProfilePath $HermesUserProfile

if ($InstallPath.StartsWith($StatePath + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $StatePath.StartsWith($InstallPath + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $InstallPath.Equals($StatePath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'InstallPath and StatePath must be separate, non-overlapping directories.'
}

$LogsPath = Join-Path $StatePath 'Logs'
$RunsPath = Join-Path $StatePath 'Runs'
$TemporaryPath = Join-Path $StatePath 'Temp'
New-Item -ItemType Directory -Force -Path $LogsPath, $RunsPath, $TemporaryPath | Out-Null
Assert-SafeDirectoryPath -Path $LogsPath -Label 'LogsPath'
Assert-SafeDirectoryPath -Path $RunsPath -Label 'RunsPath'
Assert-SafeDirectoryPath -Path $TemporaryPath -Label 'TemporaryPath'
$script:LogFile = Join-Path $LogsPath 'supervisor.log'
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    if (-not $identity.User -or
        $identity.User.Value -eq 'S-1-5-18' -or
        $identity.User.Value -ne $expectedHermesUserSid) {
        throw 'The supervisor must run as the configured Hermes profile user. Start the installed Scheduled Task instead of invoking this file directly.'
    }

    $mutex = New-Object Threading.Mutex($false, 'Global\HermesAgentSelfUpdate')

    try {
        $hasMutex = $mutex.WaitOne(0)
    }
    catch [Threading.AbandonedMutexException] {
        $hasMutex = $true
    }

    if (-not $hasMutex) {
        $exitCode = 102
        throw 'Another Hermes self-update supervisor is already running.'
    }

    Write-SupervisorLog "Supervisor started. InstallPath=$InstallPath"
    $script:GitExe = Get-GitExecutable
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GCM_INTERACTIVE = 'Never'
    Write-SupervisorLog "Using Git: $script:GitExe"

    $commit = Sync-ManagedRepository
    Write-SupervisorLog "Repository synchronized to commit $commit."

    $snapshotPath = New-CommitSnapshot -Commit $commit
    $mainScriptPath = Join-Path $snapshotPath $MainScriptFileName
    Test-PowerShellFile -Path $mainScriptPath
    Update-InstalledSupervisor -SnapshotPath $snapshotPath
    Write-SupervisorLog "Validated executable snapshot: $snapshotPath"

    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) {
        throw "Windows PowerShell executable is missing: $powershellExe"
    }

    $childArguments = ConvertTo-CommandLine @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', $mainScriptPath,
        '-FromScheduledTask',
        '-HermesUserProfile', $HermesUserProfile
    )

    $stdoutPath = Join-Path $snapshotPath 'runner.stdout.log'
    $stderrPath = Join-Path $snapshotPath 'runner.stderr.log'
    $env:HERMES_SELFUPDATE_SUPERVISOR_PATH = $PSCommandPath
    $env:HERMES_SELFUPDATE_SNAPSHOT_PATH = $snapshotPath
    $env:HERMES_SELFUPDATE_COMMIT = $commit
    Write-SupervisorLog "Starting Hermes updater from commit $commit."

    $child = Start-Process `
        -FilePath $powershellExe `
        -ArgumentList $childArguments `
        -WorkingDirectory $snapshotPath `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -Wait `
        -PassThru

    $exitCode = $child.ExitCode
    Write-SupervisorLog "Hermes updater finished with exit code $exitCode."
}
catch {
    try {
        Write-SupervisorLog "Supervisor failed: $($_.Exception.Message)"
    }
    catch {
        Write-Error $_.Exception.Message
    }
}
finally {
    if ($hasMutex -and $RunsPath -and
        (Test-Path -LiteralPath $RunsPath -PathType Container)) {
        try {
            Remove-OldRunSnapshots
        }
        catch {
            try {
                Write-SupervisorLog "Run snapshot retention failed: $($_.Exception.Message)"
            }
            catch {
                # Retention is best effort and must not hide the run result.
            }
        }
    }

    if ($hasMutex -and $mutex) {
        [void]$mutex.ReleaseMutex()
    }

    if ($mutex) {
        $mutex.Dispose()
    }

    $duration = (Get-Date) - $startedAt

    try {
        Write-SupervisorLog ('Supervisor finished after {0:c}; exit code {1}.' -f $duration, $exitCode)
    }
    catch {
        # The original error and process exit code are more important than a
        # secondary logging failure during shutdown.
    }
}

exit $exitCode
