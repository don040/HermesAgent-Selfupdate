param(
    [switch]$ScheduleOnly,
    [switch]$FromScheduledTask,
    [switch]$DryRun,
    [string]$WebhookUrl = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

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
# Hermes Self Update - Safe Single File Runner
#
# Hermes should run only:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\scripts\Hermes-SelfUpdate.ps1" -ScheduleOnly
#
# Optional dry run:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\scripts\Hermes-SelfUpdate.ps1" -DryRun
#
# Destructive mode:
#   Only allowed through Windows Task Scheduler with -FromScheduledTask
# ============================================================

$HermesHome = 'C:\Users\Administrator\AppData\Local\hermes'
$HermesRepo = Join-Path $HermesHome 'hermes-agent'
$HermesExe = Join-Path $HermesRepo 'venv\Scripts\hermes.exe'
$HermesPython = Join-Path $HermesRepo 'venv\Scripts\python.exe'
$HermesModule = 'hermes_cli.main'
$HermesUserProfile = 'C:\Users\Administrator'

function Initialize-HermesTaskEnvironment {
    # Scheduled tasks run as SYSTEM. Point Hermes and its child processes at
    # the Administrator installation and profile explicitly.
    $env:USERPROFILE = $HermesUserProfile
    $env:HOME = $HermesUserProfile
    $env:HOMEDRIVE = 'C:'
    $env:HOMEPATH = '\Users\Administrator'
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
$LogFile = Join-Path $LogDir 'weekly-self-update.log'
$ReportFile = Join-Path $LogDir 'weekly-self-update.report.txt'

$UpdateOut = Join-Path $LogDir 'weekly-self-update.hermes.out.log'
$UpdateErr = Join-Path $LogDir 'weekly-self-update.hermes.err.log'

$GatewayStopOut = Join-Path $LogDir 'weekly-self-update.gateway-stop.out.log'
$GatewayStopErr = Join-Path $LogDir 'weekly-self-update.gateway-stop.err.log'

$GatewayStartOut = Join-Path $LogDir 'weekly-self-update.gateway-start.out.log'
$GatewayStartErr = Join-Path $LogDir 'weekly-self-update.gateway-start.err.log'

$GatewayStatusBeforeFile = Join-Path $LogDir 'weekly-self-update.gateway-status-before.log'
$GatewayStatusAfterFile = Join-Path $LogDir 'weekly-self-update.gateway-status-after.log'

$UpdateTimeoutMinutes = 20
$GatewayStartWaitSeconds = 15
$ScheduledTaskName = 'Hermes-OneShot-SelfUpdate'
$GatewayServiceName = 'Hermes_Gateway'

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

    if ($Process.ExecutablePath -and $Process.ExecutablePath -like "$HermesHome*") {
        return $true
    }

    if ($Process.CommandLine -and $Process.CommandLine -like "*$HermesHome*") {
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

function Register-HermesSelfUpdateTask {
    if (-not $ScriptPath -or -not (Test-Path $ScriptPath)) {
        throw "Cannot determine script path. Save this script as a .ps1 file before using -ScheduleOnly."
    }

    $runAt = (Get-Date).AddSeconds(30)

    $taskArgs = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$ScriptPath`"",
        '-FromScheduledTask'
    ) -join ' '

    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument $taskArgs

    $trigger = New-ScheduledTaskTrigger `
        -Once `
        -At $runAt

    $principal = New-ScheduledTaskPrincipal `
        -UserId 'SYSTEM' `
        -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 45)

    $task = New-ScheduledTask `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings

    Register-ScheduledTask `
        -TaskName $ScheduledTaskName `
        -InputObject $task `
        -Force | Out-Null

    Start-ScheduledTask -TaskName $ScheduledTaskName

    Write-Output "Hermes self-update scheduled."
    Write-Output "Task: $ScheduledTaskName"
    Write-Output "RunAt: $runAt"
    Write-Output "Script: $ScriptPath"
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

        try {
            & taskkill.exe /PID $proc.Id /T /F | Out-Null
        }
        catch {
            try {
                Stop-Process -Id $proc.Id -Force -ErrorAction Stop
            }
            catch {
                Write-Log "Stop-Process failed for PID $($proc.Id): $($_.Exception.Message)"
            }
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
    Get-Service | Where-Object {
        ($_.Name -match 'hermes.*gateway|gateway.*hermes') -or
        ($_.DisplayName -match 'hermes.*gateway|gateway.*hermes')
    }
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
    $killed = New-Object System.Collections.Generic.List[string]

    $processChain = @(Get-ProcessChain)
    $protectedPids = @($PID) + @($processChain | ForEach-Object { $_.ProcessId })

    for ($pass = 1; $pass -le 2; $pass++) {
        $targets = @(Get-HermesProcesses -ExcludePids $protectedPids)

        if ($targets.Count -eq 0) {
            break
        }

        foreach ($proc in $targets) {
            $entry = "PID=$($proc.ProcessId) Name=$($proc.Name)"
            [void]$killed.Add($entry)
            Write-Event "Killing lingering Hermes process: $entry"

            try {
                & taskkill.exe /PID $proc.ProcessId /T /F | Out-Null
            }
            catch {
                try {
                    Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
                }
                catch {
                    Write-Log "Stop-Process failed for PID $($proc.ProcessId): $($_.Exception.Message)"
                }
            }
        }

        Start-Sleep -Seconds 2
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

    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        # Passing inline JSON to a native executable loses embedded quotes in
        # Windows PowerShell 5.1. Let curl read UTF-8 JSON from a temporary
        # file so Discord receives valid multipart payload_json data.
        $payloadFile = Join-Path `
        ([IO.Path]::GetTempPath()) `
        ("hermes-webhook-" + [guid]::NewGuid().ToString('N') + '.json')

        try {
            [IO.File]::WriteAllText(
                $payloadFile,
                $payload,
                (New-Object Text.UTF8Encoding($false))
            )

            $curlArgs = @(
                '--silent',
                '--show-error',
                '--fail-with-body',
                '-F', "payload_json=<$payloadFile;type=application/json"
            )

            if ($AttachmentPath) {
                $curlArgs += @(
                    '-F',
                    "file1=@$AttachmentPath;filename=hermes-update-report.txt;type=text/plain"
                )
            }

            $curlArgs += $endpoint

            $response = & curl.exe @curlArgs 2>&1
            $exitCode = $LASTEXITCODE

            $responseText = (($response | ForEach-Object {
                        $_.ToString()
                    }) -join "`r`n").TrimEnd()

            if ($responseText) {
                Write-Log "Webhook response: $responseText"
            }

            return [pscustomobject]@{
                ExitCode = $exitCode
                Response = $responseText
            }
        }
        finally {
            Remove-Item `
                -LiteralPath $payloadFile `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    $fallbackBody = @{}

    if ($null -ne $Embed) {
        $fallbackBody.embeds = @($Embed)
    }
    else {
        $fallbackBody.content = $Summary
    }

    $fallbackBody = $fallbackBody | ConvertTo-Json -Depth 10

    $fallback = Invoke-RestMethod `
        -Uri $endpoint `
        -Method Post `
        -ContentType 'application/json' `
        -Body $fallbackBody

    return [pscustomobject]@{
        ExitCode = 0
        Response = ($fallback | Out-String).TrimEnd()
    }
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

function Repair-HermesInstallation {
    param([string[]]$Reasons)

    $started = Get-Date
    $yellow = [char]::ConvertFromUtf32(0x1F7E1)
    $green = [char]::ConvertFromUtf32(0x1F7E2)
    $red = [char]::ConvertFromUtf32(0x1F534)
    $check = [char]::ConvertFromUtf32(0x2705)
    $cross = [char]::ConvertFromUtf32(0x274C)
    $installerUrl = 'https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.ps1'
    $reasonText = ($Reasons | Where-Object { $_ }) -join "`n"

    $startEmbed = @{
        title       = "$yellow Hermes Repair Started"
        description = 'A clean Hermes installation will be built in an isolated temporary directory.'
        color       = 16705372
        timestamp   = $started.ToUniversalTime().ToString('o')
        fields      = @(
            @{ name = 'Detected Issue'; value = $reasonText; inline = $false },
            @{ name = 'Official Source'; value = 'NousResearch/hermes-agent Windows installer (main branch)'; inline = $false },
            @{ name = 'Safety Policy'; value = 'Existing installation files are never overwritten. Only missing source files are added. User data and configuration are outside the repair copy scope.'; inline = $false },
            @{ name = 'Launcher Handling'; value = 'The launcher is regenerated for the existing target venv; a launcher from the temporary venv is never copied.'; inline = $false }
        )
        footer      = @{ text = "$env:COMPUTERNAME | Hermes Repair Observer" }
    }

    try {
        [void](Send-DiscordWebhookReport -Embed $startEmbed)
        Write-Event 'Repair start webhook sent.'
    }
    catch {
        Write-Event "Repair start webhook failed: $($_.Exception.Message)"
    }

    $added = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]
    $stages = New-Object System.Collections.Generic.List[string]
    $launcherExit = $null
    $version = 'not available'
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $tempRoot = Join-Path $tempBase ("HermesRepair-" + [guid]::NewGuid().ToString('N'))
    $tempHome = Join-Path $tempRoot 'home'
    $tempInstall = Join-Path $tempRoot 'hermes-agent'
    $installer = Join-Path $tempRoot 'install.ps1'

    try {
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        Write-Event "Downloading official Hermes installer to: $installer"
        Invoke-WebRequest -Uri $installerUrl -OutFile $installer -UseBasicParsing -ErrorAction Stop

        # The official stage runner refreshes PATH from the registry. Under a
        # SYSTEM task that hides the already configured portable Git and uv
        # paths inherited from this script. Patch only the disposable Temp
        # copy so it appends registry PATH instead of discarding inherited PATH.
        $installerText = [IO.File]::ReadAllText($installer)
        $syncPathPattern = 'function\s+Sync-EnvPath\s*\{\s*\$env:Path\s*=\s*\[Environment\]::GetEnvironmentVariable\("Path",\s*"User"\)\s*\+\s*";"\s*\+\s*\[Environment\]::GetEnvironmentVariable\("Path",\s*"Machine"\)\s*\}'
        $syncPathReplacement = 'function Sync-EnvPath { $registryPath = [Environment]::GetEnvironmentVariable("Path", "User") + ";" + [Environment]::GetEnvironmentVariable("Path", "Machine"); $env:Path = $env:Path + ";" + $registryPath }'
        $syncPathRegex = [regex]::new($syncPathPattern)
        $syncPathMatches = $syncPathRegex.Matches($installerText)

        if ($syncPathMatches.Count -ne 1) {
            throw 'Official installer Sync-EnvPath implementation changed; refusing an unverified compatibility patch.'
        }

        $installerText = $syncPathRegex.Replace(
            $installerText,
            { param($match) $syncPathReplacement },
            1
        )
        [IO.File]::WriteAllText(
            $installer,
            $installerText,
            (New-Object Text.UTF8Encoding($false))
        )
        Write-Event 'Applied Temp-only SYSTEM PATH compatibility patch to official installer.'

        foreach ($stage in @('repository', 'venv', 'dependencies')) {
            $outFile = Join-Path $tempRoot "$stage.out.log"
            $errFile = Join-Path $tempRoot "$stage.err.log"
            $arguments = @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass',
                '-File', $installer,
                '-Stage', $stage,
                '-NonInteractive', '-SkipSetup',
                '-HermesHome', $tempHome,
                '-InstallDir', $tempInstall
            )

            Write-Event "Running official installer stage in temp: $stage"
            $process = Start-Process `
                -FilePath 'powershell.exe' `
                -ArgumentList (ConvertTo-CommandLine -Arguments $arguments) `
                -WorkingDirectory $tempRoot `
                -WindowStyle Hidden `
                -RedirectStandardOutput $outFile `
                -RedirectStandardError $errFile `
                -PassThru -Wait
            $process.Refresh()
            $exitCode = [int]$process.ExitCode
            [void]$stages.Add("$stage=$exitCode")

            foreach ($path in @($outFile, $errFile)) {
                if (Test-Path -LiteralPath $path) {
                    foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
                        Write-Log "Repair installer [$stage]: $line"
                    }
                }
            }

            if ($exitCode -ne 0) {
                $stageDetails = @()

                foreach ($path in @($outFile, $errFile)) {
                    if (Test-Path -LiteralPath $path) {
                        $stageDetails += Get-Content -LiteralPath $path -Encoding UTF8
                    }
                }

                $stageDetailText = ($stageDetails -join "`n").Trim()

                if ($stageDetailText.Length -gt 1200) {
                    $stageDetailText = $stageDetailText.Substring($stageDetailText.Length - 1200)
                }

                throw "Official installer stage '$stage' failed with exit code $exitCode. Details: $stageDetailText"
            }
        }

        if (-not (Test-Path -LiteralPath $tempInstall -PathType Container)) {
            throw "Temporary Hermes installation missing: $tempInstall"
        }

        $prefixLength = $tempInstall.TrimEnd('\').Length

        foreach ($source in Get-ChildItem -LiteralPath $tempInstall -Recurse -File -Force) {
            $relative = $source.FullName.Substring($prefixLength).TrimStart('\')

            if ($relative -like '.git\*' -or $relative -like 'venv\*' -or $relative -like 'node_modules\*') {
                continue
            }

            $destination = Join-Path $HermesRepo $relative

            if (Test-Path -LiteralPath $destination) {
                continue
            }

            $parent = Split-Path $destination -Parent
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }

            # The false overwrite flag guarantees an existing file is never replaced.
            [IO.File]::Copy($source.FullName, $destination, $false)
            [void]$added.Add($relative)
            Write-Event "Added missing Hermes source file: $relative"
        }

        if (-not (Test-Path -LiteralPath $HermesPython)) {
            throw "Existing target venv Python is missing: $HermesPython"
        }

        $uv = Get-UvExecutable
        if (-not $uv) {
            throw 'uv.exe was not found; launcher regeneration cannot continue.'
        }

        $launcherOut = Join-Path $tempRoot 'launcher.out.log'
        $launcherErr = Join-Path $tempRoot 'launcher.err.log'
        $launcherArgs = @(
            'pip', 'install',
            '--python', $HermesPython,
            '--reinstall-package', 'hermes-agent',
            '--no-deps',
            '--editable', $HermesRepo
        )

        Write-Event 'Regenerating hermes.exe for the existing target venv.'
        $launcherProcess = Start-Process `
            -FilePath $uv `
            -ArgumentList (ConvertTo-CommandLine -Arguments $launcherArgs) `
            -WorkingDirectory $HermesRepo `
            -WindowStyle Hidden `
            -RedirectStandardOutput $launcherOut `
            -RedirectStandardError $launcherErr `
            -PassThru -Wait
        $launcherProcess.Refresh()
        $launcherExit = [int]$launcherProcess.ExitCode

        foreach ($path in @($launcherOut, $launcherErr)) {
            if (Test-Path -LiteralPath $path) {
                foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
                    Write-Log "Repair launcher: $line"
                }
            }
        }

        if ($launcherExit -ne 0) {
            throw "Launcher regeneration failed with exit code $launcherExit."
        }
        if (-not (Test-Path -LiteralPath $HermesExe)) {
            throw "Launcher is still missing: $HermesExe"
        }

        $versionOut = Join-Path $tempRoot 'version.out.log'
        $versionErr = Join-Path $tempRoot 'version.err.log'
        $versionProcess = Start-Process `
            -FilePath $HermesPython `
            -ArgumentList (ConvertTo-CommandLine -Arguments @('-m', $HermesModule, '--version')) `
            -WorkingDirectory $HermesRepo `
            -WindowStyle Hidden `
            -RedirectStandardOutput $versionOut `
            -RedirectStandardError $versionErr `
            -PassThru -Wait
        $versionProcess.Refresh()

        if ($versionProcess.ExitCode -eq 0 -and (Test-Path -LiteralPath $versionOut)) {
            $line = Get-Content -LiteralPath $versionOut -Encoding UTF8 | Select-Object -First 1
            if ($line) { $version = $line.Trim() }
        }
    }
    catch {
        [void]$errors.Add($_.Exception.Message)
        Write-Event "Hermes repair failed: $($_.Exception.Message)"
    }
    finally {
        try {
            $resolved = [IO.Path]::GetFullPath($tempRoot)
            $safePrefix = $tempBase.TrimEnd('\') + '\'

            if (
                $resolved.StartsWith($safePrefix, [StringComparison]::OrdinalIgnoreCase) -and
                (Split-Path $resolved -Leaf) -like 'HermesRepair-*'
            ) {
                Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
                Write-Log "Removed isolated repair temp directory: $resolved"
            }
            else {
                Write-Log "Refused unsafe temp cleanup path: $resolved"
            }
        }
        catch {
            Write-Log "Could not remove repair temp directory: $($_.Exception.Message)"
        }
    }

    $success = $errors.Count -eq 0 -and (Test-Path -LiteralPath $HermesExe)
    $finished = Get-Date
    $duration = Format-Duration -Duration ($finished - $started)
    $preview = if ($added.Count -eq 0) { 'None required' } else { $added -join "`n" }
    if ($preview.Length -gt 900) { $preview = $preview.Substring(0, 897) + '...' }
    $symbol = if ($success) { $green } else { $red }
    $word = if ($success) { 'SUCCESS' } else { 'FAILED' }
    $result = if ($success) { "$check SUCCESS" } else { "$cross FAILED" }
    $errorText = if ($errors.Count -eq 0) { 'None' } else { $errors -join "`n" }
    $launcher = if (Test-Path -LiteralPath $HermesExe) { 'PRESENT' } else { 'MISSING' }

    $resultEmbed = @{
        title       = "$symbol Hermes Repair $word"
        description = if ($success) {
            'The isolated repair completed successfully. The normal update will now continue.'
        }
        else {
            'The isolated repair failed. The update has been stopped to protect the installation.'
        }
        color       = if ($success) { 5763719 } else { 15548997 }
        timestamp   = $finished.ToUniversalTime().ToString('o')
        fields      = @(
            @{ name = 'Result'; value = $result; inline = $true },
            @{ name = 'Duration'; value = $duration; inline = $true },
            @{ name = 'Launcher'; value = $launcher; inline = $true },
            @{ name = 'Missing Source Files Added'; value = "$($added.Count)"; inline = $true },
            @{ name = 'Existing Files Overwritten'; value = '0'; inline = $true },
            @{ name = 'Launcher Exit'; value = if ($null -eq $launcherExit) { 'not run' } else { "$launcherExit" }; inline = $true },
            @{ name = 'Installer Stages'; value = if ($stages.Count -eq 0) { 'not run' } else { $stages -join ' | ' }; inline = $false },
            @{ name = 'Files Added'; value = $preview; inline = $false },
            @{ name = 'Hermes Version'; value = $version; inline = $false },
            @{ name = 'Errors'; value = $errorText; inline = $false }
        )
        footer      = @{ text = "$env:COMPUTERNAME | Hermes Repair Observer" }
    }

    try {
        [void](Send-DiscordWebhookReport -Embed $resultEmbed)
        Write-Event "Repair result webhook sent; success=$success"
    }
    catch {
        Write-Event "Repair result webhook failed: $($_.Exception.Message)"
    }

    Add-ReportSection 'Preflight repair'
    Add-ReportLine "Success: $success"
    Add-ReportLine "Reasons: $($Reasons -join '; ')"
    Add-ReportLine "Official installer: $installerUrl"
    Add-ReportLine "Installer stages: $($stages -join '; ')"
    Add-ReportLine "Missing source files added: $($added.Count)"
    Add-ReportLine 'Existing source files overwritten: 0'
    Add-ReportLine "Launcher: $launcher"
    Add-ReportLine "Launcher exit: $launcherExit"
    Add-ReportLine "Version after repair: $version"
    Add-ReportLine "Errors: $errorText"
    Save-Report

    return [pscustomobject]@{
        Success        = $success
        RestoredFiles  = $added.ToArray()
        LauncherStatus = $launcher
        Version        = $version
        Errors         = $errors.ToArray()
    }
}
# ============================================================
# Safe scheduling mode
# ============================================================

if ($ScheduleOnly) {
    Register-HermesSelfUpdateTask
    exit 0
}

# ============================================================
# Main destructive runner
# ============================================================

Assert-SafeExecutionMode

$GitExe = Initialize-HermesTaskEnvironment
$RunStartedAt = Get-Date
$InstallSizeBeforeBytes = Get-DirectorySizeBytes -Path $HermesRepo

Write-Event '=== weekly update run started ==='
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

$repairPerformed = $repairReasons.Count -gt 0
$repairStatusText = 'Not required'

if ($repairPerformed) {
    Write-Event "Preflight repair required: $($repairReasons -join '; ')"
    $repairResult = Repair-HermesInstallation -Reasons $repairReasons.ToArray()

    if (-not $repairResult.Success) {
        $repairStatusText = 'FAILED'
        Write-Event 'Preflight repair failed; update aborted.'
        Save-Report
        exit 6
    }

    $repairStatusText = "SUCCESS ($($repairResult.RestoredFiles.Count) missing source file(s) added)"
    Write-Event "Preflight repair succeeded: $repairStatusText"
}

if (-not (Test-Path -LiteralPath $HermesPython)) {
    Write-Event "Hermes Python interpreter not found; automatic repair was not started because hermes.exe exists: $HermesPython"

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
    'Windows Task Scheduler (SYSTEM)'
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
$gatewayWasRunning = $false
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

    $gatewayWasRunning = ($gatewayStatusBefore.StdOut -match '(?i)running') -or ($gatewayStatusBefore.StdErr -match '(?i)running')
}
catch {
    Write-Event "Gateway status before update failed: $($_.Exception.Message)"
}

$gatewayServices = @(Get-HermesGatewayServices)

if ($gatewayServices.Count -gt 0) {
    $restartMode = 'service'
}
elseif ($gatewayWasRunning) {
    $restartMode = 'manual'
}
else {
    $restartMode = 'none'
}

Write-Event "Gateway restart mode after update: $restartMode"

if ($gatewayServices.Count -gt 0) {
    Write-Event ('Detected gateway service(s): ' + (($gatewayServices | ForEach-Object { $_.Name }) -join ', '))
}
else {
    Write-Event 'No gateway service detected - manual gateway restart will be used if the gateway was running before update.'
}

if ($DryRun) {
    Write-Event 'DryRun requested - no changes were made.'

    Add-ReportSection 'DryRun summary'
    Add-ReportLine "Would stop gateway via: hermes gateway stop --all"
    Add-ReportLine "Would stop detected service(s): $((@($gatewayServices | ForEach-Object { $_.Name }) -join ', '))"
    Add-ReportLine "Would kill Hermes processes under: $HermesHome"
    Add-ReportLine "Would run: hermes update --yes --backup --force"

    if ($restartMode -eq 'service') {
        Add-ReportLine 'Would restart detected gateway service(s).'
    }
    elseif ($restartMode -eq 'manual') {
        Add-ReportLine 'Would restart gateway manually with: hermes gateway run'
    }
    else {
        Add-ReportLine 'Gateway was not running - would leave it stopped.'
    }

    Save-Report
    exit 0
}

# Stop gateway via Hermes CLI first
$gatewayStopResult = $null

try {
    $gatewayStopResult = Invoke-HermesCommand `
        -Label 'gateway-stop' `
        -Arguments @('gateway', 'stop', '--all')

    Set-Content -Path $GatewayStopOut -Value $gatewayStopResult.StdOut -Encoding UTF8
    Set-Content -Path $GatewayStopErr -Value $gatewayStopResult.StdErr -Encoding UTF8

    Write-Event "Gateway stop exit=$($gatewayStopResult.ExitCode)"

    if ($gatewayStopResult.StdOut) {
        Add-ReportBlock -Title 'Gateway stop - stdout' -Text $gatewayStopResult.StdOut
    }

    if ($gatewayStopResult.StdErr) {
        Add-ReportBlock -Title 'Gateway stop - stderr' -Text $gatewayStopResult.StdErr
    }
}
catch {
    Write-Event "Gateway stop command failed: $($_.Exception.Message)"
}

# Stop gateway services if detected
if ($gatewayServices.Count -gt 0) {
    foreach ($svc in $gatewayServices) {
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
$killedProcesses = @(Stop-HermesProcesses)

Add-ReportSection 'Killed processes'

if ($killedProcesses.Count -gt 0) {
    foreach ($item in $killedProcesses) {
        Add-ReportLine $item
    }
}
else {
    Add-ReportLine 'None found.'
}

# Run update
$updateResult = $null
$updateExitCode = 0

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

if ($updateExitCode -eq 0 -and -not (Test-Path $HermesExe)) {
    $updateExitCode = 5
    Write-Event "Update completed, but the Hermes launcher is still missing: $HermesExe"
}
elseif (Test-Path $HermesExe) {
    Write-Event "Hermes launcher verified: $HermesExe"
}

# Restart gateway
$restartExitCode = 0
$restartResult = $null

if ($restartMode -eq 'service') {
    Add-ReportSection 'Gateway restart'

    foreach ($svc in $gatewayServices) {
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

    try {
        Start-Sleep -Seconds 5

        $restartResult = Invoke-HermesCommand `
            -Label 'gateway-status-after' `
            -Arguments @('gateway', 'status', '--full')

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
        Write-Log "Gateway status check after service restart failed: $($_.Exception.Message)"
        Add-ReportLine "Gateway status check after service restart failed: $($_.Exception.Message)"
    }
}
elseif ($restartMode -eq 'manual') {
    Add-ReportSection 'Gateway restart'

    try {
        Write-Event 'Starting gateway manually with hermes gateway run'

        if (Test-Path $GatewayStartOut) {
            Remove-Item -Force $GatewayStartOut
        }

        if (Test-Path $GatewayStartErr) {
            Remove-Item -Force $GatewayStartErr
        }

        $startProc = Start-Process `
            -FilePath $HermesPython `
            -WorkingDirectory $HermesRepo `
            -ArgumentList (ConvertTo-CommandLine -Arguments @('-m', $HermesModule, 'gateway', 'run')) `
            -WindowStyle Hidden `
            -PassThru `
            -RedirectStandardOutput $GatewayStartOut `
            -RedirectStandardError $GatewayStartErr

        $restartExitCode = 0

        Add-ReportLine "Manual gateway start PID=$($startProc.Id)"

        Start-Sleep -Seconds $GatewayStartWaitSeconds

        if (Test-Path $GatewayStartOut) {
            Add-ReportBlock -Title 'Gateway manual start - stdout' -Text (Get-Content -Raw -Encoding UTF8 $GatewayStartOut)
        }

        if (Test-Path $GatewayStartErr) {
            Add-ReportBlock -Title 'Gateway manual start - stderr' -Text (Get-Content -Raw -Encoding UTF8 $GatewayStartErr)
        }

        $restartResult = Invoke-HermesCommand `
            -Label 'gateway-status-after' `
            -Arguments @('gateway', 'status', '--full')

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
        Write-Log "Manual gateway restart failed: $($_.Exception.Message)"
        Add-ReportLine $_.Exception.Message
    }
}
else {
    Add-ReportSection 'Gateway restart'
    Add-ReportLine 'Gateway was not running before update, so it was left stopped.'

    try {
        $restartResult = Invoke-HermesCommand `
            -Label 'gateway-status-after' `
            -Arguments @('gateway', 'status', '--full')

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
        Write-Log "Gateway status check after update failed: $($_.Exception.Message)"
        Add-ReportLine "Gateway status check after update failed: $($_.Exception.Message)"
    }
}

$HermesVersionAfter = 'unknown'

try {
    $versionAfterResult = Invoke-HermesCommand `
        -Label 'version-after' `
        -Arguments @('--version') `
        -TimeoutMinutes 2

    if ($versionAfterResult.StdOut) {
        $HermesVersionAfter = ($versionAfterResult.StdOut -split "`r?`n")[0].Trim()
    }
}
catch {
    Write-Log "Could not determine Hermes version after update: $($_.Exception.Message)"
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

$overallStatus = if ($updateExitCode -ne 0) {
    'FAILED'
}
elseif ($restartExitCode -ne 0 -or $gatewayServiceStatus -ne 'RUNNING') {
    'WARNING'
}
else {
    'SUCCESS'
}

# Summary
Add-ReportSection 'Summary'
Add-ReportLine "Update exit code: $updateExitCode"
Add-ReportLine "Gateway restart mode: $restartMode"
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
Add-ReportLine "$GatewayServiceName status after update: $gatewayServiceStatus"
Add-ReportLine "$GatewayServiceName PID after update: $gatewayServicePidAfterText"
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
$gatewayEmoji = if ($gatewayServiceStatus -eq 'RUNNING') { $EmojiCheck } else { $EmojiWarning }
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
    'Hermes was updated successfully and the gateway service is running.'
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
            name   = $GatewayServiceName
            value  = "$gatewayEmoji $gatewayServiceStatus`nPID: $gatewayServicePidAfterText"
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

Write-Event '=== weekly update run finished ==='

# Cleanup one-shot task after execution
if ($FromScheduledTask) {
    try {
        Unregister-ScheduledTask -TaskName $ScheduledTaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log "Removed scheduled task: $ScheduledTaskName"
    }
    catch {
        Write-Log "Could not remove scheduled task ${ScheduledTaskName}: $($_.Exception.Message)"
    }
}

$finalExitCode = $updateExitCode

if ($restartExitCode -ne 0 -and $finalExitCode -eq 0) {
    $finalExitCode = $restartExitCode
}

if ($webhookExitCode -ne 0 -and $finalExitCode -eq 0) {
    $finalExitCode = $webhookExitCode
}

exit $finalExitCode
