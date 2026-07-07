<#
.SYNOPSIS
    Structural wiring checks for register-runners.ps1.

.DESCRIPTION
    register-runners.ps1 has top-level side effects (module install/
    import, two helper-driven vault reads, SSH connect loop) that
    make it impractical to dot-source from a test. These tests parse
    the file via AST and assert the parts of the SecretSuffix contract
    that would otherwise silently regress:

      - $SecretSuffix is a Mandatory + ValidateNotNullOrEmpty script
        parameter.
      - Both vault-reading helpers (Read-GitHubRunnersConfig and
        Read-VmDeployPasswords) are called exactly once each and
        receive -SecretSuffix bound to the script-level $SecretSuffix
        variable. A regression that hard-codes the suffix or drops
        the forward would defeat the per-lifecycle isolation the
        parameter exists to enforce.
#>

BeforeAll {
    $script:scriptPath = Join-Path $PSScriptRoot '..\register-runners.ps1'

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

    # Returns $true if $Call passes `-SecretSuffix $SecretSuffix`
    # (the script-level variable, not a literal). Walks CommandElements
    # in pairs looking for the parameter / variable-expression pair.
    function Test-ForwardsSecretSuffix {
        param([System.Management.Automation.Language.CommandAst] $Call)
        for ($i = 1; $i -lt $Call.CommandElements.Count - 1; $i++) {
            $cur  = $Call.CommandElements[$i]
            $next = $Call.CommandElements[$i + 1]
            if ($cur -is [System.Management.Automation.Language.CommandParameterAst] -and
                $cur.ParameterName -eq 'SecretSuffix' -and
                $next -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $next.VariablePath.UserPath -eq 'SecretSuffix') {
                return $true
            }
        }
        return $false
    }

    # Returns the string literal bound to -Name on an Invoke-WithPhaseTimer
    # call, or $null when it is not a bare string literal. Used to collect the
    # declared phase names in source order.
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

    # The phases register-runners.ps1 declares, in dispatch order. Pinned here
    # so a rename silently reshaping the tree the E2E graft (C2) attaches under
    # the runner-registration part fails loudly.
    $script:expectedPhases = @(
        'Read configs + resolve router IP',
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

Describe 'register-runners.ps1 - suffix forwarding to vault helpers' {

    # Each helper read must receive the script-level $SecretSuffix
    # verbatim. Both helpers' own suites (Tests/registration/common/
    # config/*.Tests.ps1) prove they reject missing/empty input - so
    # the wiring here is the missing link end-to-end.

    It 'invokes Read-GitHubRunnersConfig exactly once' {
        $calls = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Read-GitHubRunnersConfig' }
        @($calls).Count | Should -Be 1
    }

    It 'forwards $SecretSuffix to Read-GitHubRunnersConfig' {
        $call = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Read-GitHubRunnersConfig' } |
            Select-Object -First 1
        Test-ForwardsSecretSuffix -Call $call | Should -BeTrue
    }

    It 'invokes Read-VmDeployPasswords exactly once' {
        $calls = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Read-VmDeployPasswords' }
        @($calls).Count | Should -Be 1
    }

    It 'forwards $SecretSuffix to Read-VmDeployPasswords' {
        $call = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Read-VmDeployPasswords' } |
            Select-Object -First 1
        Test-ForwardsSecretSuffix -Call $call | Should -BeTrue
    }
}


Describe 'register-runners.ps1 - jump-host wiring (feature 53 NAT topology)' {

    # The host has no route into the per-environment private switch
    # runner VMs sit on after feature 53 step 2. The script must (1)
    # read VmProvisionerConfig to find the router row, (2) discover
    # its upstream IP via KVP, (3) stamp _RouterVm onto every runner
    # entry in the same env, (4) reach workloads via the jump-aware
    # New-VmSshClientWithJump instead of constructing a Renci.SshNet.
    # SshClient directly, and (5) bind the host file server on the
    # router's upstream LAN (Get-VmSwitchHostIp keyed on the router
    # IP) so workloads can reach it via the router's MASQUERADE NAT.

    It 'reads VmProvisionerConfig to locate the router row' {
        $text = Get-Content -LiteralPath $script:scriptPath -Raw
        $text | Should -Match 'VmProvisionerConfig-\$SecretSuffix'
    }

    It 'calls Get-VmKvpIpAddress to discover the router upstream IP' {
        $call = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Get-VmKvpIpAddress' } |
            Select-Object -First 1
        $call | Should -Not -BeNullOrEmpty
    }

    It 'calls New-VmSshClientWithJump for the per-VM SSH session' {
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

    It 'stamps _RouterVm onto entries via Add-Member' {
        $text = Get-Content -LiteralPath $script:scriptPath -Raw
        $text | Should -Match "(?s)Add-Member[^']*-Name\s+'_RouterVm'"
    }

    It 'no longer constructs Renci.SshNet.SshClient directly' {
        $text = Get-Content -LiteralPath $script:scriptPath -Raw
        $text | Should -Not -Match '\[Renci\.SshNet\.SshClient\]::new'
    }
}


Describe 'register-runners.ps1 - phase-timing instrumentation (feature 88 D3)' {

    # register-runners.ps1 is a child emitter of the cross-process timing
    # feature: it declares its stages via Initialize-PhaseTimings, times each
    # with Invoke-WithPhaseTimer, and hands the tree to a parent orchestrator
    # on the TIMING_TREE_OUTPUT_PATH opt-in via the self-guarding
    # Export-PhaseTimingTreeIfRequested shim. These checks pin that wiring so a
    # dropped stage, a renamed phase, or a reverted export regresses loudly.

    It 'declares its stages once via Initialize-PhaseTimings' {
        $calls = @($script:commands |
            Where-Object { $_.GetCommandName() -eq 'Initialize-PhaseTimings' })
        $calls.Count | Should -Be 1
    }

    It 'times every declared stage with Invoke-WithPhaseTimer, in order' {
        $timerCalls = @($script:commands |
            Where-Object { $_.GetCommandName() -eq 'Invoke-WithPhaseTimer' })
        $names = @($timerCalls | ForEach-Object { Get-PhaseTimerName -Call $_ })
        $names | Should -Be $script:expectedPhases
    }

    It 'exports the tree via the self-guarding opt-in shim exactly once' {
        $calls = @($script:commands | Where-Object {
            $_.GetCommandName() -eq 'Export-PhaseTimingTreeIfRequested'
        })
        $calls.Count | Should -Be 1
    }

    It 'does not call the mandatory-path Export-PhaseTimingTree directly' {
        # The opt-in guard and the env-var name live only in the shim; a direct
        # Export-PhaseTimingTree here would mean a hand-written guard crept back.
        $calls = @($script:commands |
            Where-Object { $_.GetCommandName() -eq 'Export-PhaseTimingTree' })
        $calls.Count | Should -Be 0
    }

    It 'does not hand-write the TIMING_TREE_OUTPUT_PATH env-var guard' {
        # The shim single-sources the contract name and owns the env read; a
        # literal $env:TIMING_TREE_OUTPUT_PATH reference here signals the
        # pre-D2-B hand-written guard regressed back in (a comment naming the
        # variable is fine - only the $env: read is forbidden).
        $text = Get-Content -LiteralPath $script:scriptPath -Raw
        $text | Should -Not -Match '\$env:TIMING_TREE_OUTPUT_PATH'
    }
}

Describe 'register-runners.ps1 - Common.PowerShell floor' {

    It 'raises the Common.PowerShell floor to the Export-PhaseTimingTreeIfRequested release (>= 9.3.0)' {
        # The shim register-runners.ps1 calls ships in Common.PowerShell 9.3.0;
        # the bootstrap floor must stay >= that so the import resolves it. Pin
        # the MinimumVersion so a downgrade cannot silently leave the run
        # calling an unexported verb.
        $depsPath = Join-Path (Split-Path $script:scriptPath -Parent) `
            '..\shared\Install-ModuleDependencies.ps1'
        $depsText = Get-Content -Path $depsPath -Raw
        $depsText | Should -Match "MinimumVersion '(9\.(?:[3-9]|\d\d+)\.\d+|[1-9]\d+\.\d+\.\d+)'"
    }
}
