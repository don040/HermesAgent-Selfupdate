$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:AnalysisCache = @{}

function Get-StaticScriptAnalysis {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)

    if (-not $script:AnalysisCache.ContainsKey($fullPath)) {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $fullPath,
            [ref]$tokens,
            [ref]$parseErrors
        )

        $script:AnalysisCache[$fullPath] = [pscustomobject]@{
            Path        = $fullPath
            Text        = [IO.File]::ReadAllText($fullPath)
            Ast         = $ast
            Tokens      = @($tokens)
            ParseErrors = @($parseErrors)
        }
    }

    return $script:AnalysisCache[$fullPath]
}

function Get-StaticFunctionAst {
    param(
        [Parameter(Mandatory = $true)]$Ast,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $wantedName = $Name
    return @($Ast.FindAll({
        param($node)

        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ieq $wantedName
    }, $true))
}

function Get-StaticCommandAst {
    param(
        [Parameter(Mandatory = $true)]$Ast,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $wantedName = $Name
    return @($Ast.FindAll({
        param($node)

        if ($node -isnot [Management.Automation.Language.CommandAst]) {
            return $false
        }

        $commandName = $node.GetCommandName()
        return $null -ne $commandName -and $commandName -ieq $wantedName
    }, $true))
}

function Get-StaticStringNodes {
    param([Parameter(Mandatory = $true)]$Ast)

    return @($Ast.FindAll({
        param($node)

        $node -is [Management.Automation.Language.StringConstantExpressionAst] -or
        $node -is [Management.Automation.Language.ExpandableStringExpressionAst]
    }, $true))
}

function Get-StaticStringValues {
    param([Parameter(Mandatory = $true)]$Ast)

    return @(Get-StaticStringNodes -Ast $Ast | ForEach-Object { $_.Value })
}

function Get-StaticParameterAst {
    param(
        [Parameter(Mandatory = $true)]$Ast,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Ast.ParamBlock) {
        return @()
    }

    $wantedName = $Name
    return @($Ast.ParamBlock.Parameters | Where-Object {
        $_.Name.VariablePath.UserPath -ieq $wantedName
    })
}

function Get-StaticLiteralValue {
    param($Ast)

    if ($null -eq $Ast) {
        return $null
    }

    if ($Ast -is [Management.Automation.Language.StringConstantExpressionAst] -or
        $Ast -is [Management.Automation.Language.ExpandableStringExpressionAst]) {
        return $Ast.Value
    }

    if ($Ast -is [Management.Automation.Language.CommandExpressionAst]) {
        return Get-StaticLiteralValue -Ast $Ast.Expression
    }

    return $Ast.Extent.Text.Trim()
}

function Get-StaticParameterDefault {
    param(
        [Parameter(Mandatory = $true)]$Ast,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $parameters = @(Get-StaticParameterAst -Ast $Ast -Name $Name)

    if ($parameters.Count -ne 1) {
        return $null
    }

    return Get-StaticLiteralValue -Ast $parameters[0].DefaultValue
}

function Get-StaticAssignmentAst {
    param(
        [Parameter(Mandatory = $true)]$Ast,
        [Parameter(Mandatory = $true)][string]$VariableName
    )

    $wantedName = $VariableName
    return @($Ast.FindAll({
        param($node)

        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -ieq $wantedName
    }, $true))
}

function Get-StaticCommandParameterNames {
    param([Parameter(Mandatory = $true)]$CommandAst)

    return @($CommandAst.CommandElements | Where-Object {
        $_ -is [Management.Automation.Language.CommandParameterAst]
    } | ForEach-Object { $_.ParameterName })
}

function Get-StaticCommandParameterArgument {
    param(
        [Parameter(Mandatory = $true)]$CommandAst,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $elements = @($CommandAst.CommandElements)

    for ($index = 0; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]

        if ($element -isnot [Management.Automation.Language.CommandParameterAst] -or
            $element.ParameterName -ine $Name) {
            continue
        }

        if ($null -ne $element.Argument) {
            return Get-StaticLiteralValue -Ast $element.Argument
        }

        if ($index + 1 -lt $elements.Count -and
            $elements[$index + 1] -isnot [Management.Automation.Language.CommandParameterAst]) {
            return Get-StaticLiteralValue -Ast $elements[$index + 1]
        }

        return $null
    }

    return $null
}

function Test-StaticAstIsInsideFunction {
    param([Parameter(Mandatory = $true)]$Ast)

    $parent = $Ast.Parent

    while ($null -ne $parent) {
        if ($parent -is [Management.Automation.Language.FunctionDefinitionAst]) {
            return $true
        }

        $parent = $parent.Parent
    }

    return $false
}

function Get-StaticContainingIfAst {
    param([Parameter(Mandatory = $true)]$Ast)

    $parent = $Ast.Parent

    while ($null -ne $parent) {
        if ($parent -is [Management.Automation.Language.IfStatementAst]) {
            return $parent
        }

        $parent = $parent.Parent
    }

    return $null
}

$script:PowerShellFiles = @(
    Get-ChildItem -LiteralPath $script:RepositoryRoot -Recurse -File -Filter '*.ps1' |
        Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
        Sort-Object FullName
)

$script:Installer = Get-StaticScriptAnalysis -Path (
    Join-Path $script:RepositoryRoot 'Install-HermesSelfUpdate.ps1'
)
$script:Supervisor = Get-StaticScriptAnalysis -Path (
    Join-Path $script:RepositoryRoot 'Invoke-HermesSelfUpdate.ps1'
)
$script:Main = Get-StaticScriptAnalysis -Path (
    Join-Path $script:RepositoryRoot 'Hermes-SelfUpdate.ps1'
)

Describe 'PowerShell source integrity' {
    It 'finds PowerShell scripts in the repository' {
        ($script:PowerShellFiles.Count -gt 0) | Should Be $true
    }

    It 'parses every repository PowerShell script without errors' {
        $failures = @()

        foreach ($file in $script:PowerShellFiles) {
            $analysis = Get-StaticScriptAnalysis -Path $file.FullName

            foreach ($parseError in $analysis.ParseErrors) {
                $relativePath = $file.FullName.Substring($script:RepositoryRoot.Length).TrimStart('\')
                $failures += '{0}:{1}:{2}: {3}' -f (
                    $relativePath,
                    $parseError.Extent.StartLineNumber,
                    $parseError.Extent.StartColumnNumber,
                    $parseError.Message
                )
            }
        }

        ($failures -join [Environment]::NewLine) | Should BeNullOrEmpty
    }

    It 'contains no hard-coded Discord webhook URL in any PowerShell source file' {
        $webhookPattern = '(?i)https?://(?:canary\.|ptb\.)?discord(?:app)?\.com/api/webhooks(?:/|\b)'
        $matches = @()

        foreach ($file in $script:PowerShellFiles) {
            $analysis = Get-StaticScriptAnalysis -Path $file.FullName

            if ($analysis.Text -match $webhookPattern) {
                $matches += $file.FullName.Substring($script:RepositoryRoot.Length).TrimStart('\')
            }
        }

        ($matches -join ', ') | Should BeNullOrEmpty
    }
}

Describe 'Installer defaults and daily Scheduled Task contract' {
    It 'defaults to C:\scripts and the daily 04:00 task' {
        (Get-StaticParameterDefault -Ast $script:Installer.Ast -Name 'InstallPath') |
            Should Be 'C:\scripts'
        (Get-StaticParameterDefault -Ast $script:Installer.Ast -Name 'TaskName') |
            Should Be 'Hermes-Agent-SelfUpdate-Daily'
        (Get-StaticParameterDefault -Ast $script:Installer.Ast -Name 'DailyAt') |
            Should Be '04:00'
    }

    It 'registers a daily trigger' {
        $commands = @(Get-StaticCommandAst -Ast $script:Installer.Ast -Name 'New-ScheduledTaskTrigger')
        $commands.Count | Should Be 1

        $parameters = @(Get-StaticCommandParameterNames -CommandAst $commands[0])
        ($parameters -contains 'Daily') | Should Be $true
        ($parameters -contains 'At') | Should Be $true
    }

    It 'sets the first 04:00 occurrence in the future instead of starting during install' {
        $script:Installer.Text | Should Match '(?is)\$firstRun\s*=.*TimeOfDay'
        $script:Installer.Text | Should Match '(?is)if\s*\(\s*\$firstRun\s+-le\s+\(Get-Date\)\s*\).*AddDays\(1\)'
    }

    It 'uses the SYSTEM service account at highest run level' {
        $commands = @(Get-StaticCommandAst -Ast $script:Installer.Ast -Name 'New-ScheduledTaskPrincipal')
        $commands.Count | Should Be 1

        (Get-StaticCommandParameterArgument -CommandAst $commands[0] -Name 'UserId') |
            Should Be 'SYSTEM'
        (Get-StaticCommandParameterArgument -CommandAst $commands[0] -Name 'LogonType') |
            Should Be 'ServiceAccount'
        (Get-StaticCommandParameterArgument -CommandAst $commands[0] -Name 'RunLevel') |
            Should Be 'Highest'
    }

    It 'starts missed runs and prevents overlapping task instances' {
        $commands = @(Get-StaticCommandAst -Ast $script:Installer.Ast -Name 'New-ScheduledTaskSettingsSet')
        $commands.Count | Should Be 1

        $parameters = @(Get-StaticCommandParameterNames -CommandAst $commands[0])
        ($parameters -contains 'StartWhenAvailable') | Should Be $true
        (Get-StaticCommandParameterArgument -CommandAst $commands[0] -Name 'MultipleInstances') |
            Should Be 'IgnoreNew'
    }

    It 'registers the task with its action, trigger, principal, and settings' {
        $commands = @(Get-StaticCommandAst -Ast $script:Installer.Ast -Name 'Register-ScheduledTask')
        $commands.Count | Should Be 1

        $parameters = @(Get-StaticCommandParameterNames -CommandAst $commands[0])

        foreach ($requiredParameter in @('TaskName', 'Action', 'Trigger', 'Principal', 'Settings')) {
            ($parameters -contains $requiredParameter) | Should Be $true
        }
    }

    It 'shares the global supervisor mutex with the installer' {
        $script:Installer.Text | Should Match "Global\\HermesAgentSelfUpdate"
        $script:Supervisor.Text | Should Match "Global\\HermesAgentSelfUpdate"
        $script:Installer.Text | Should Match '(?is)WaitOne\(0\).*finally.*ReleaseMutex'
    }
}

Describe 'Repository refresh supervisor contract' {
    It 'handles successful native Git progress on stderr by checking the exit code' {
        foreach ($analysis in @($script:Installer, $script:Supervisor)) {
            $functions = @(Get-StaticFunctionAst -Ast $analysis.Ast -Name 'Invoke-Git')
            $functions.Count | Should Be 1
            $functions[0].Extent.Text | Should Match '(?is)ErrorActionPreference\s*=\s*''Continue''.*\$LASTEXITCODE'
            $functions[0].Extent.Text | Should Match '(?is)finally\s*\{\s*\$ErrorActionPreference\s*=\s*\$previousErrorActionPreference'
        }
    }

    It 'validates origin against the configured repository URL' {
        $functions = @(Get-StaticFunctionAst -Ast $script:Supervisor.Ast -Name 'Sync-ManagedRepository')
        $functions.Count | Should Be 1

        $functionText = $functions[0].Extent.Text
        $strings = @(Get-StaticStringValues -Ast $functions[0])

        ($strings -contains 'remote') | Should Be $true
        ($strings -contains 'get-url') | Should Be $true
        ($strings -contains 'origin') | Should Be $true
        $functionText | Should Match '(?is)Get-NormalizedRepositoryUrl\s+\$actualRemote.*-ne.*Get-NormalizedRepositoryUrl\s+\$RepositoryUrl'
    }

    It 'requires a tracked-clean checkout before fetching' {
        $functions = @(Get-StaticFunctionAst -Ast $script:Supervisor.Ast -Name 'Sync-ManagedRepository')
        $stringNodes = @(Get-StaticStringNodes -Ast $functions[0])
        $statusNodes = @($stringNodes | Where-Object { $_.Value -eq 'status' })
        $fetchNodes = @($stringNodes | Where-Object { $_.Value -eq 'fetch' })
        $strings = @($stringNodes | ForEach-Object { $_.Value })

        ($statusNodes.Count -gt 0) | Should Be $true
        ($fetchNodes.Count -gt 0) | Should Be $true
        ($strings -contains '--porcelain') | Should Be $true
        ($strings -contains '--untracked-files=no') | Should Be $true
        ($statusNodes[0].Extent.StartOffset -lt $fetchNodes[0].Extent.StartOffset) | Should Be $true
        $functions[0].Extent.Text | Should Match '(?is)if\s*\(\s*\$trackedChanges\s*\)\s*\{[^}]*throw'
    }

    It 'updates only by fast-forward and verifies the remote commit' {
        $functions = @(Get-StaticFunctionAst -Ast $script:Supervisor.Ast -Name 'Sync-ManagedRepository')
        $strings = @(Get-StaticStringValues -Ast $functions[0])

        ($strings -contains '--ff-only') | Should Be $true
        ($strings -contains 'HEAD') | Should Be $true
        $functions[0].Extent.Text | Should Match '(?is)\$headCommit\s+-ne\s+\$remoteCommit'
    }

    It 'fetches main into the matching remote-tracking ref without allowing a forced rewind' {
        $functions = @(Get-StaticFunctionAst -Ast $script:Supervisor.Ast -Name 'Sync-ManagedRepository')
        $functionText = $functions[0].Extent.Text

        $functionText | Should Match 'refs/heads/\$\{Branch\}:refs/remotes/origin/\$\{Branch\}'
        $functionText | Should Not Match '\+refs/heads/'
    }

    It 'creates an executable snapshot from the exact commit' {
        $functions = @(Get-StaticFunctionAst -Ast $script:Supervisor.Ast -Name 'New-CommitSnapshot')
        $functions.Count | Should Be 1

        $parameters = @(Get-StaticParameterAst -Ast $functions[0].Body -Name 'Commit')
        $strings = @(Get-StaticStringValues -Ast $functions[0])
        $expandCommands = @(Get-StaticCommandAst -Ast $functions[0] -Name 'Expand-Archive')

        $parameters.Count | Should Be 1
        ($strings -contains 'archive') | Should Be $true
        ($strings -contains '--format=zip') | Should Be $true
        $functions[0].Extent.Text | Should Match '(?is)Get-RepositoryArguments\s+@\([^)]*\$Commit'
        $expandCommands.Count | Should Be 1
    }

    It 'syncs, snapshots, and then launches the core in a new Windows PowerShell process' {
        $syncCommands = @(Get-StaticCommandAst -Ast $script:Supervisor.Ast -Name 'Sync-ManagedRepository' |
            Where-Object { -not (Test-StaticAstIsInsideFunction -Ast $_) })
        $snapshotCommands = @(Get-StaticCommandAst -Ast $script:Supervisor.Ast -Name 'New-CommitSnapshot' |
            Where-Object { -not (Test-StaticAstIsInsideFunction -Ast $_) })
        $startCommands = @(Get-StaticCommandAst -Ast $script:Supervisor.Ast -Name 'Start-Process' |
            Where-Object { -not (Test-StaticAstIsInsideFunction -Ast $_) })

        $syncCommands.Count | Should Be 1
        $snapshotCommands.Count | Should Be 1
        $startCommands.Count | Should Be 1
        ($syncCommands[0].Extent.StartOffset -lt $snapshotCommands[0].Extent.StartOffset) | Should Be $true
        ($snapshotCommands[0].Extent.StartOffset -lt $startCommands[0].Extent.StartOffset) | Should Be $true

        $startParameters = @(Get-StaticCommandParameterNames -CommandAst $startCommands[0])
        (Get-StaticCommandParameterArgument -CommandAst $startCommands[0] -Name 'FilePath') |
            Should Be '$powershellExe'
        (Get-StaticCommandParameterArgument -CommandAst $startCommands[0] -Name 'WorkingDirectory') |
            Should Be '$snapshotPath'
        ($startParameters -contains 'Wait') | Should Be $true
        ($startParameters -contains 'PassThru') | Should Be $true

        $supervisorStrings = @(Get-StaticStringValues -Ast $script:Supervisor.Ast)
        ($supervisorStrings -contains 'System32\WindowsPowerShell\v1.0\powershell.exe') |
            Should Be $true
        ($supervisorStrings -contains '-File') | Should Be $true
        ($supervisorStrings -contains '-FromScheduledTask') | Should Be $true
        $script:Supervisor.Text | Should Match '(?is)\$mainScriptPath\s*=\s*Join-Path\s+\$snapshotPath\s+\$MainScriptFileName'
    }

    It 'attests the exact snapshot contract to the fresh core' {
        foreach ($name in @(
            'HERMES_SELFUPDATE_SUPERVISOR_PATH',
            'HERMES_SELFUPDATE_SNAPSHOT_PATH',
            'HERMES_SELFUPDATE_COMMIT'
        )) {
            $script:Supervisor.Text | Should Match ([regex]::Escape($name))
            $script:Main.Text | Should Match ([regex]::Escape($name))
        }
    }
}

Describe 'Core scheduling and execution safety contract' {
    It 'declares ScheduleOnly, FromScheduledTask, and DryRun switches' {
        foreach ($parameterName in @('ScheduleOnly', 'FromScheduledTask', 'DryRun')) {
            $parameters = @(Get-StaticParameterAst -Ast $script:Main.Ast -Name $parameterName)
            $parameters.Count | Should Be 1
            $parameters[0].StaticType.FullName | Should Be 'System.Management.Automation.SwitchParameter'
        }
    }

    It 'uses the installed daily task name and starts that existing task in ScheduleOnly mode' {
        $taskAssignments = @(Get-StaticAssignmentAst -Ast $script:Main.Ast -VariableName 'ScheduledTaskName')
        $taskAssignments.Count | Should Be 1
        (Get-StaticLiteralValue -Ast $taskAssignments[0].Right) |
            Should Be 'Hermes-Agent-SelfUpdate-Daily'

        $functions = @(Get-StaticFunctionAst -Ast $script:Main.Ast -Name 'Start-InstalledHermesSelfUpdateTask')
        $functions.Count | Should Be 1

        $getCommands = @(Get-StaticCommandAst -Ast $functions[0] -Name 'Get-ScheduledTask')
        $startCommands = @(Get-StaticCommandAst -Ast $functions[0] -Name 'Start-ScheduledTask')
        $getCommands.Count | Should Be 1
        $startCommands.Count | Should Be 1
        (Get-StaticCommandParameterArgument -CommandAst $startCommands[0] -Name 'TaskName') |
            Should Be '$ScheduledTaskName'

        $scheduleCalls = @(Get-StaticCommandAst -Ast $script:Main.Ast -Name 'Start-InstalledHermesSelfUpdateTask' |
            Where-Object { -not (Test-StaticAstIsInsideFunction -Ast $_) })
        $scheduleCalls.Count | Should Be 1

        $scheduleIf = Get-StaticContainingIfAst -Ast $scheduleCalls[0]
        ($null -ne $scheduleIf) | Should Be $true
        $scheduleIf.Extent.Text | Should Match '(?is)if\s*\(\s*\$ScheduleOnly\s*\)'
        $scheduleIf.Extent.Text | Should Match '(?im)^\s*exit\s+0\s*$'
    }

    It 'never unregisters or removes a Scheduled Task from the core script' {
        @(Get-StaticCommandAst -Ast $script:Main.Ast -Name 'Unregister-ScheduledTask').Count |
            Should Be 0
        @(Get-StaticCommandAst -Ast $script:Main.Ast -Name 'Remove-ScheduledTask').Count |
            Should Be 0
    }

    It 'rejects unsafe combinations with ScheduleOnly' {
        $script:Main.Text | Should Match '(?is)if\s*\(\s*\$ScheduleOnly\s+-and\s+\$FromScheduledTask\s*\)\s*\{\s*throw'
        $script:Main.Text | Should Match '(?is)if\s*\(\s*\$ScheduleOnly\s+-and\s+\$DryRun\s*\)\s*\{\s*throw'
    }

    It 'allows destructive execution only with FromScheduledTask under LOCAL SYSTEM' {
        $functions = @(Get-StaticFunctionAst -Ast $script:Main.Ast -Name 'Assert-SafeExecutionMode')
        $functions.Count | Should Be 1

        $functionText = $functions[0].Extent.Text
        $functionText | Should Match '(?is)if\s*\(\s*-not\s+\$FromScheduledTask\s*\)\s*\{\s*throw'
        $functionText | Should Match 'S-1-5-18'
        $functionText | Should Match 'WindowsIdentity'

        $assertCommands = @(Get-StaticCommandAst -Ast $script:Main.Ast -Name 'Assert-SafeExecutionMode' |
            Where-Object { -not (Test-StaticAstIsInsideFunction -Ast $_) })
        $assertCommands.Count | Should Be 1

        $mutatingCommands = @()

        foreach ($commandName in @('Stop-HermesProcesses', 'Stop-Service', 'Start-Service')) {
            $mutatingCommands += @(Get-StaticCommandAst -Ast $script:Main.Ast -Name $commandName |
                Where-Object { -not (Test-StaticAstIsInsideFunction -Ast $_) })
        }

        ($mutatingCommands.Count -gt 0) | Should Be $true

        foreach ($command in $mutatingCommands) {
            ($assertCommands[0].Extent.StartOffset -lt $command.Extent.StartOffset) | Should Be $true
        }
    }

    It 'keeps automatic upstream repair out of SYSTEM execution' {
        @(Get-StaticFunctionAst -Ast $script:Main.Ast -Name 'Repair-HermesInstallation').Count |
            Should Be 0
        @(Get-StaticCommandAst -Ast $script:Main.Ast -Name 'Repair-HermesInstallation').Count |
            Should Be 0
        $script:Main.Text | Should Match '(?is)Automatic SYSTEM repair is disabled.*exit\s+6'
    }

    It 'recognizes official gateway process liveness without trusting task state text' {
        $functions = @(Get-StaticFunctionAst -Ast $script:Main.Ast -Name 'Get-GatewayStatusState')
        $functions.Count | Should Be 1
        Invoke-Expression $functions[0].Extent.Text

        (Get-GatewayStatusState -Text "Gateway process running (PID: 123)") |
            Should Be 'Running'
        (Get-GatewayStatusState -Text "Task Status: Running`r`nNo gateway process detected") |
            Should Be 'Stopped'
        (Get-GatewayStatusState -Text "Task Status: Running") |
            Should Be 'Unknown'
    }

    It 'restores only captured service or official Scheduled Task backends in finally' {
        $script:Main.Text | Should Match '(?is)finally\s*\{.*Restore-HermesGatewayBackend'
        $script:Main.Text | Should Match "restartMode\s*=\s*'scheduled-task'"
        $script:Main.Text | Should Not Match "restartMode\s*-eq\s*'manual'"
        $script:Main.Text | Should Not Match "gateway',\s*'run'"
    }

    It 'exits the DryRun path before gateway stop, process kill, update, or restart mutations' {
        $dryRunExitIfs = @($script:Main.Ast.FindAll({
            param($node)

            if ($node -isnot [Management.Automation.Language.IfStatementAst]) {
                return $false
            }

            foreach ($clause in $node.Clauses) {
                if ($clause.Item1.Extent.Text -notmatch '^\s*\$DryRun\s*$') {
                    continue
                }

                $exitsInDryRunBody = @($clause.Item2.FindAll({
                    param($child)
                    $child -is [Management.Automation.Language.ExitStatementAst]
                }, $true))

                if ($exitsInDryRunBody.Count -gt 0) {
                    return $true
                }
            }

            return $false
        }, $true))

        $dryRunExitIfs.Count | Should Be 1

        $mutatingCommands = @()

        foreach ($commandName in @(
            'Stop-HermesProcesses',
            'Stop-Service',
            'Start-Service',
            'Stop-Process'
        )) {
            $mutatingCommands += @(Get-StaticCommandAst -Ast $script:Main.Ast -Name $commandName |
                Where-Object { -not (Test-StaticAstIsInsideFunction -Ast $_) })
        }

        ($mutatingCommands.Count -gt 0) | Should Be $true

        foreach ($command in $mutatingCommands) {
            ($dryRunExitIfs[0].Extent.EndOffset -lt $command.Extent.StartOffset) | Should Be $true
        }

        $dryRunExitIfs[0].Extent.Text | Should Match '(?im)^\s*exit\s+0\s*$'
    }
}
