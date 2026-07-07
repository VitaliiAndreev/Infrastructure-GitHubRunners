<#
.SYNOPSIS
    Structural wiring checks for the thin register-runners.ps1 entry script.

.DESCRIPTION
    After feature 88 D3-C, register-runners.ps1 is a thin entry point: it
    bootstraps modules, dot-sources its registration-direction helpers plus the
    shared orchestrator, and makes a single call to Invoke-RunnerReconcileRun
    with the registration operation phases and a -Body that joins credentials,
    probes reachability, prefetches the tarball, and installs/registers each
    runner. All the shared opening (the two vault reads, the router resolution,
    the phase-timing setup, and the timing export) moved into the orchestrator,
    which is behaviourally tested under
    registration/common/Invoke-RunnerReconcileRun.Tests.ps1.

    The script still has top-level side effects (module install/import) that make
    it impractical to dot-source, so these AST checks pin only what the thin
    entry script itself owns: the SecretSuffix parameter contract, the single
    orchestrator call carrying the suffix and the registration phases, the -Body
    wired to the install verbs, and the absence of any shared-opening behaviour
    (bare secret literals, direct vault reads, router stamping, timing setup)
    that would signal a partial revert of the extraction.
#>

BeforeAll {
    $script:scriptPath = Join-Path $PSScriptRoot '..\register-runners.ps1'
    $script:scriptText = Get-Content -LiteralPath $script:scriptPath -Raw

    $tokens    = $null
    $parseErrs = $null
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:scriptPath, [ref] $tokens, [ref] $parseErrs)
    if ($parseErrs.Count -gt 0) {
        throw "register-runners.ps1 has parse errors: $($parseErrs -join '; ')"
    }

    $script:commands = $script:ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true)

    # Returns the value-expression AST bound to the named parameter in a
    # CommandAst. Walks CommandElements in pairs looking for `-Name <value>`.
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

    # Every string-literal value nested under an AST node, in document order.
    function Get-StringLiteralsUnder {
        param([System.Management.Automation.Language.Ast] $Node)
        $Node.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }, $true) | ForEach-Object { $_.Value }
    }

    # Returns the string literal bound to -Name on an Invoke-WithPhaseTimer call.
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

    # This entry script's registration-direction operation phases, in run order.
    # Pinned so a rename silently reshaping the tree the E2E graft (C2) attaches
    # under the runner part fails loudly.
    $script:expectedOperationPhases = @(
        'Match + probe reachable VMs',
        'Resolve + prefetch runner tarball',
        'Install + register runners'
    )
}

Describe 'register-runners.ps1 - SecretSuffix parameter contract' {

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

Describe 'register-runners.ps1 - delegates to the shared orchestrator' {

    BeforeAll {
        $script:orchestratorCalls = @($script:commands |
            Where-Object { $_.GetCommandName() -eq 'Invoke-RunnerReconcileRun' })
    }

    It 'dot-sources the shared orchestrator helper' {
        # The single call below resolves only if the orchestrator is dot-sourced
        # first; pin the dot-source so a dropped import fails here, not at runtime.
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

    It 'passes the registration operation phases, in order' {
        $arg    = Get-BoundArgFor -Call $script:orchestratorCalls[0] -ParameterName 'OperationPhase'
        $phases = @(Get-StringLiteralsUnder -Node $arg)
        $phases | Should -Be $script:expectedOperationPhases
    }

    It 'wires -Body as a scriptblock timing exactly those phases, in order' {
        $arg = Get-BoundArgFor -Call $script:orchestratorCalls[0] -ParameterName 'Body'
        $arg | Should -BeOfType `
            ([System.Management.Automation.Language.ScriptBlockExpressionAst])

        # Every Invoke-WithPhaseTimer in the file lives inside this -Body, so the
        # phase names it times must match the declared operation phases exactly.
        $timerCalls = @($script:commands |
            Where-Object { $_.GetCommandName() -eq 'Invoke-WithPhaseTimer' })
        $names = @($timerCalls | ForEach-Object { Get-PhaseTimerName -Call $_ })
        $names | Should -Be $script:expectedOperationPhases
    }

    It 'the -Body installs and registers runners (owns the up-direction verbs)' {
        $arg  = Get-BoundArgFor -Call $script:orchestratorCalls[0] -ParameterName 'Body'
        $text = $arg.Extent.Text
        $text | Should -Match 'Invoke-VmRunnerGroup'
        $text | Should -Match 'Invoke-WithVmFileServer'
    }
}

Describe 'register-runners.ps1 - shared opening not leaked back in' {

    # Regression guards for a partial revert of the D3-C extraction. Everything
    # below moved into Invoke-RunnerReconcileRun; a reappearance here means the
    # thin entry script grew a second, drifting copy of the shared opening.

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

Describe 'register-runners.ps1 - per-VM SSH wiring retained in the body' {

    # The install loop stays here (it is registration-specific), so the
    # jump-aware session and host-file-server binding must remain, and the
    # script must never construct a raw Renci.SshNet.SshClient.

    It 'reaches workloads via the jump-aware New-VmSshClientWithJump' {
        $call = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'New-VmSshClientWithJump' } |
            Select-Object -First 1
        $call | Should -Not -BeNullOrEmpty
    }

    It 'binds the file server via Get-VmSwitchHostIp on the router upstream when router present' {
        $call = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Get-VmSwitchHostIp' } |
            Select-Object -First 1
        $call | Should -Not -BeNullOrEmpty
    }

    It 'never constructs Renci.SshNet.SshClient directly' {
        $script:scriptText | Should -Not -Match '\[Renci\.SshNet\.SshClient\]::new'
    }
}

Describe 'register-runners.ps1 - Common.PowerShell floor' {

    It 'raises the Common.PowerShell floor to the Export-PhaseTimingTreeIfRequested release (>= 9.3.0)' {
        # The shim the orchestrator calls ships in Common.PowerShell 9.3.0; the
        # bootstrap floor must stay >= that so the import resolves it. Pin the
        # MinimumVersion so a downgrade cannot silently leave the run calling an
        # unexported verb.
        $depsPath = Join-Path (Split-Path $script:scriptPath -Parent) `
            '..\shared\Install-ModuleDependencies.ps1'
        $depsText = Get-Content -Path $depsPath -Raw
        $depsText | Should -Match "MinimumVersion '(9\.(?:[3-9]|\d\d+)\.\d+|[1-9]\d+\.\d+\.\d+)'"
    }
}
