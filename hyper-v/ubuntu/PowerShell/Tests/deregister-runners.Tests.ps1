<#
.SYNOPSIS
    Structural wiring checks for the thin deregister-runners.ps1 entry script.

.DESCRIPTION
    See register-runners.Tests.ps1 for the rationale. After feature 88 D3-C,
    deregister-runners.ps1 is a thin entry point over the shared
    Invoke-RunnerReconcileRun orchestrator; it supplies the deregistration
    operation phases (no tarball prefetch, so two stages to the up path's three)
    and a -Body that probes reachability and removes each runner. The checks
    mirror the register suite with the down-direction phases and verbs.
#>

BeforeAll {
    $script:scriptPath = Join-Path $PSScriptRoot '..\deregister-runners.ps1'
    $script:scriptText = Get-Content -LiteralPath $script:scriptPath -Raw

    $tokens    = $null
    $parseErrs = $null
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:scriptPath, [ref] $tokens, [ref] $parseErrs)
    if ($parseErrs.Count -gt 0) {
        throw "deregister-runners.ps1 has parse errors: $($parseErrs -join '; ')"
    }

    $script:commands = $script:ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true)

    function Get-BoundArgFor {
        param(
            [System.Management.Automation.Language.CommandAst] $Call,
            [string] $ParameterName
        )
        for ($i = 1; $i -lt $Call.CommandElements.Count - 1; $i++) {
            $cur  = $Call.CommandElements[$i]
            $next = $Call.CommandElements[$i + 1]
            if ($cur -is [System.Management.Automation.Language.CommandParameterAst] -and
                $cur.ParameterName -eq $ParameterName) {
                return $next
            }
        }
        return $null
    }

    function Get-StringLiteralsUnder {
        param([System.Management.Automation.Language.Ast] $Node)
        $Node.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }, $true) | ForEach-Object { $_.Value }
    }

    function Get-PhaseTimerName {
        param([System.Management.Automation.Language.CommandAst] $Call)
        for ($i = 1; $i -lt $Call.CommandElements.Count - 1; $i++) {
            $cur  = $Call.CommandElements[$i]
            $next = $Call.CommandElements[$i + 1]
            if ($cur -is [System.Management.Automation.Language.CommandParameterAst] -and
                $cur.ParameterName -eq 'Name' -and
                $next -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                return $next.Value
            }
        }
        return $null
    }

    # The down-direction operation phases, in run order. The down path has no
    # tarball prefetch, so it times two stages to the up path's three.
    $script:expectedOperationPhases = @(
        'Match + probe reachable VMs',
        'Deregister runners'
    )
}

Describe 'deregister-runners.ps1 - SecretSuffix parameter contract' {

    It 'declares -SecretSuffix as a script parameter' {
        $param = $script:ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'SecretSuffix' } |
            Select-Object -First 1
        $param | Should -Not -BeNullOrEmpty
    }

    It 'marks -SecretSuffix Mandatory' {
        $param = $script:ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'SecretSuffix' } |
            Select-Object -First 1
        $hasMandatory = $param.Attributes | Where-Object {
            $_.TypeName.Name -eq 'Parameter' -and
            ($_.NamedArguments | Where-Object {
                $_.ArgumentName -eq 'Mandatory'
            })
        }
        $hasMandatory | Should -Not -BeNullOrEmpty
    }

    It 'marks -SecretSuffix ValidateNotNullOrEmpty' {
        $param = $script:ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'SecretSuffix' } |
            Select-Object -First 1
        $hasValidator = $param.Attributes | Where-Object {
            $_.TypeName.Name -eq 'ValidateNotNullOrEmpty'
        }
        $hasValidator | Should -Not -BeNullOrEmpty
    }
}

Describe 'deregister-runners.ps1 - delegates to the shared orchestrator' {

    BeforeAll {
        $script:orchestratorCalls = @($script:commands |
            Where-Object { $_.GetCommandName() -eq 'Invoke-RunnerReconcileRun' })
    }

    It 'dot-sources the shared orchestrator helper' {
        $script:scriptText | Should -Match 'registration\\common\\Invoke-RunnerReconcileRun\.ps1'
    }

    It 'calls Invoke-RunnerReconcileRun exactly once' {
        $script:orchestratorCalls.Count | Should -Be 1
    }

    It 'binds -SecretSuffix to the script $SecretSuffix parameter' {
        $arg = Get-BoundArgFor -Call $script:orchestratorCalls[0] -ParameterName 'SecretSuffix'
        $arg | Should -BeOfType `
            ([System.Management.Automation.Language.VariableExpressionAst])
        $arg.VariablePath.UserPath | Should -Be 'SecretSuffix'
    }

    It 'passes the deregistration operation phases, in order' {
        $arg    = Get-BoundArgFor -Call $script:orchestratorCalls[0] -ParameterName 'OperationPhase'
        $phases = @(Get-StringLiteralsUnder -Node $arg)
        $phases | Should -Be $script:expectedOperationPhases
    }

    It 'wires -Body as a scriptblock timing exactly those phases, in order' {
        $arg = Get-BoundArgFor -Call $script:orchestratorCalls[0] -ParameterName 'Body'
        $arg | Should -BeOfType `
            ([System.Management.Automation.Language.ScriptBlockExpressionAst])

        $timerCalls = @($script:commands |
            Where-Object { $_.GetCommandName() -eq 'Invoke-WithPhaseTimer' })
        $names = @($timerCalls | ForEach-Object { Get-PhaseTimerName -Call $_ })
        $names | Should -Be $script:expectedOperationPhases
    }

    It 'the -Body deregisters runners (owns the down-direction verb)' {
        $arg  = Get-BoundArgFor -Call $script:orchestratorCalls[0] -ParameterName 'Body'
        $arg.Extent.Text | Should -Match 'Invoke-VmDeregisterGroup'
    }
}

Describe 'deregister-runners.ps1 - shared opening not leaked back in' {

    BeforeAll {
        $script:stringLiterals = $script:ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }, $true)
    }

    It 'no longer reads the runner-config vaults directly' {
        $reads = @($script:commands | Where-Object {
            $_.GetCommandName() -in @('Read-GitHubRunnersConfig', 'Read-VmDeployPasswords')
        })
        $reads.Count | Should -Be 0
    }

    It 'no longer reads the provisioner vault or discovers the router IP directly' {
        $calls = @($script:commands | Where-Object {
            $_.GetCommandName() -in @('Get-InfrastructureSecret', 'Get-VmKvpIpAddress')
        })
        $calls.Count | Should -Be 0
    }

    It 'no longer declares its own timing stages or exports the tree' {
        $timing = @($script:commands | Where-Object {
            $_.GetCommandName() -in @(
                'Initialize-PhaseTimings',
                'Export-PhaseTimingTree',
                'Export-PhaseTimingTreeIfRequested')
        })
        $timing.Count | Should -Be 0
    }

    It 'has no bare "VmProvisionerConfig" string literal' {
        $offenders = $script:stringLiterals | Where-Object {
            $_.Value -eq 'VmProvisionerConfig'
        }
        @($offenders).Count | Should -Be 0 `
            -Because 'the secret name lives in the orchestrator and always carries the suffix'
    }
}

Describe 'deregister-runners.ps1 - per-VM SSH wiring retained in the body' {

    # The down path opens an SSH session per reachable VM and runs no host file
    # server, so New-VmSshClientWithJump stays but the Get-VmSwitchHostIp leg is
    # intentionally absent. The script must never construct a raw SshClient.

    It 'reaches workloads via the jump-aware New-VmSshClientWithJump' {
        $call = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'New-VmSshClientWithJump' } |
            Select-Object -First 1
        $call | Should -Not -BeNullOrEmpty
    }

    It 'never constructs Renci.SshNet.SshClient directly' {
        $script:scriptText | Should -Not -Match '\[Renci\.SshNet\.SshClient\]::new'
    }
}

Describe 'deregister-runners.ps1 - Common.PowerShell floor' {

    It 'raises the Common.PowerShell floor to the Export-PhaseTimingTreeIfRequested release (>= 9.3.0)' {
        $depsPath = Join-Path (Split-Path $script:scriptPath -Parent) `
            '..\shared\Install-ModuleDependencies.ps1'
        $depsText = Get-Content -Path $depsPath -Raw
        $depsText | Should -Match "MinimumVersion '(9\.(?:[3-9]|\d\d+)\.\d+|[1-9]\d+\.\d+\.\d+)'"
    }
}
