<#
.SYNOPSIS
    Behavioural tests for the shared runner-reconcile orchestrator.

.DESCRIPTION
    Invoke-RunnerReconcileRun is a function seam (unlike the top-level entry
    scripts register-runners.ps1 / deregister-runners.ps1, which have
    un-dot-sourceable side effects), so its shared opening - the two vault
    reads, the feature-53 router resolution, the phase-timing declaration, and
    the timing export in the finally - can be dot-sourced with every boundary
    cmdlet mocked and driven end-to-end. This is the coverage the two AST-only
    entry-script suites could not provide.

    The phase-timing shims (Initialize-PhaseTimings / Invoke-WithPhaseTimer /
    Export-PhaseTimingTreeIfRequested) come from Common.PowerShell in
    production; here they are stubbed so the suite is hermetic.
    Invoke-WithPhaseTimer's stub simply runs its -Action, which is exactly the
    shim's observable effect - it wraps a stopwatch around the action but never
    alters control flow. The env-var opt-in behaviour of
    Export-PhaseTimingTreeIfRequested itself is owned by Common.PowerShell's
    tests; here we only assert the orchestrator calls it from the finally on
    both the success and failure paths.
#>

# The -Body test doubles mirror the production callback signature
# (RunnerEntries, DeployPasswords) so the mocked flow exercises the real
# contract. The DeployPasswords param name trips the plaintext-password rule,
# but no real secret is ever bound here - suppress it file-wide for the doubles.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingPlainTextForPassword', '',
    Justification = 'Test -Body doubles mirror the production callback signature; no real password is bound')]
param()

BeforeAll {
    $script:orchestratorPath =
        Join-Path $PSScriptRoot '..\..\..\registration\common\Invoke-RunnerReconcileRun.ps1'

    # --- Common.PowerShell surface (stubbed) ---------------------------------
    # Invoke-WithPhaseTimer runs the action inline (its control-flow-neutral
    # behaviour); the other two are no-op seams the tests Mock to assert on.
    function Initialize-PhaseTimings { param([object[]] $Phases) }
    function Invoke-WithPhaseTimer   { param([string] $Name, [scriptblock] $Action) & $Action }
    function Export-PhaseTimingTreeIfRequested { }

    # --- registration/common + Infrastructure boundary (stubbed) -------------
    function Read-GitHubRunnersConfig { param($SecretSuffix) }
    function Read-VmDeployPasswords   { param($SecretSuffix) }
    function Get-InfrastructureSecret { param($VaultName, $SecretName) }
    function Get-VmKvpIpAddress       { param($VmName, $SwitchName, [scriptblock] $OnPoll) }

    . $script:orchestratorPath

    # Builds a provisioner VM row (workload by default).
    function New-ProvisionerVm {
        param(
            [string] $VmName,
            [string] $Ip = '10.0.0.10',
            [string] $Kind,
            [string] $PrivateSwitch
        )
        $vm = [PSCustomObject] @{ vmName = $VmName; ipAddress = $Ip }
        if ($Kind)          { Add-Member -InputObject $vm -NotePropertyName 'kind'              -NotePropertyValue $Kind }
        if ($PrivateSwitch) { Add-Member -InputObject $vm -NotePropertyName 'privateSwitchName' -NotePropertyValue $PrivateSwitch }
        $vm
    }

    # Builds a runner entry (what Read-GitHubRunnersConfig yields).
    function New-RunnerEntry {
        param([string] $VmName)
        [PSCustomObject] @{ vmName = $VmName; runnerName = "$VmName-ci" }
    }

    # A -Body that records each invocation (entries + passwords) so tests can
    # assert it fired with the resolved context.
    $script:recordingBody = {
        param($RunnerEntries, $DeployPasswords)
        $script:bodyCalls.Add([PSCustomObject] @{
            Entries   = $RunnerEntries
            Passwords = $DeployPasswords
        })
    }
}

Describe 'Invoke-RunnerReconcileRun' {

    BeforeEach {
        $script:bodyCalls = [System.Collections.Generic.List[object]]::new()
    }

    Context 'vault reads carry the suffix' {

        It 'reads both runner-config vaults with the SecretSuffix' {
            Mock Read-GitHubRunnersConfig { @(New-RunnerEntry 'node-01') }
            Mock Read-VmDeployPasswords   { @() }
            Mock Get-InfrastructureSecret { '[]' }

            Invoke-RunnerReconcileRun -SecretSuffix 'Env42' `
                -OperationPhase @('Match + probe reachable VMs') `
                -Body $script:recordingBody

            Should -Invoke Read-GitHubRunnersConfig -Times 1 -ParameterFilter {
                $SecretSuffix -eq 'Env42'
            }
            Should -Invoke Read-VmDeployPasswords -Times 1 -ParameterFilter {
                $SecretSuffix -eq 'Env42'
            }
        }

        It 'reads the provisioner config with the SecretSuffix-stamped name' {
            Mock Read-GitHubRunnersConfig { @(New-RunnerEntry 'node-01') }
            Mock Read-VmDeployPasswords   { @() }
            Mock Get-InfrastructureSecret { '[]' }

            Invoke-RunnerReconcileRun -SecretSuffix 'Env42' `
                -OperationPhase @('Match + probe reachable VMs') `
                -Body $script:recordingBody

            Should -Invoke Get-InfrastructureSecret -Times 1 -ParameterFilter {
                $VaultName -eq 'VmProvisioner' -and
                $SecretName -eq 'VmProvisionerConfig-Env42'
            }
        }
    }

    Context 'phase declaration' {

        It 'declares the shared opening phase first, then the operation phases in order' {
            Mock Initialize-PhaseTimings {}
            Mock Read-GitHubRunnersConfig { @(New-RunnerEntry 'node-01') }
            Mock Read-VmDeployPasswords   { @() }
            Mock Get-InfrastructureSecret { '[]' }

            Invoke-RunnerReconcileRun -SecretSuffix 'S' `
                -OperationPhase @('Match + probe reachable VMs', 'Deregister runners') `
                -Body $script:recordingBody

            Should -Invoke Initialize-PhaseTimings -Times 1 -ParameterFilter {
                ($Phases -join '|') -eq
                    'Read configs + resolve router IP|Match + probe reachable VMs|Deregister runners'
            }
        }
    }

    Context 'context handed to the body' {

        It 'invokes -Body with the resolved runner entries and deploy passwords' {
            $passwords = [PSCustomObject] @{ Index = 'deploy-secret-index' }
            Mock Read-GitHubRunnersConfig { @((New-RunnerEntry 'node-01'), (New-RunnerEntry 'node-02')) }
            Mock Read-VmDeployPasswords   { $passwords }
            Mock Get-InfrastructureSecret { '[]' }

            Invoke-RunnerReconcileRun -SecretSuffix 'S' `
                -OperationPhase @('Match + probe reachable VMs') `
                -Body $script:recordingBody

            $script:bodyCalls | Should -HaveCount 1
            @($script:bodyCalls[0].Entries).Count | Should -Be 2
            $script:bodyCalls[0].Passwords.Index   | Should -Be 'deploy-secret-index'
        }
    }

    Context 'router-jump topology (feature 53)' {

        It 'stamps _RouterVm onto a workload entry and resolves the router IP via KVP' {
            # Router row (no ipAddress -> resolved via KVP) plus one workload
            # entry on the same private switch.
            $router = New-ProvisionerVm -VmName 'router-01' -Kind 'router' -PrivateSwitch 'sw-a'
            $router.PSObject.Properties.Remove('ipAddress')
            Add-Member -InputObject $router -NotePropertyName 'externalSwitchName' -NotePropertyValue 'sw-ext'
            $workload = New-ProvisionerVm -VmName 'node-01' -PrivateSwitch 'sw-a'
            $provJson = ConvertTo-Json -Depth 5 -InputObject @($router, $workload)

            Mock Read-GitHubRunnersConfig { @(New-RunnerEntry 'node-01') }
            Mock Read-VmDeployPasswords   { @() }
            Mock Get-InfrastructureSecret { $provJson }
            Mock Import-Module {}                       # Hyper-V import on the router path
            Mock Get-VmKvpIpAddress { '192.168.7.5' }

            Invoke-RunnerReconcileRun -SecretSuffix 'S' `
                -OperationPhase @('Match + probe reachable VMs') `
                -Body $script:recordingBody

            Should -Invoke Get-VmKvpIpAddress -Times 1
            $entry = @($script:bodyCalls[0].Entries)[0]
            $entry.PSObject.Properties['_RouterVm'] | Should -Not -BeNullOrEmpty
            $entry._RouterVm.vmName                 | Should -Be 'router-01'
            $entry._RouterVm.ipAddress              | Should -Be '192.168.7.5'
        }
    }

    Context 'no-router topology (pre-feature-53)' {

        It 'leaves entries unstamped and never calls KVP discovery' {
            $provJson = ConvertTo-Json -Depth 5 -InputObject @(New-ProvisionerVm -VmName 'node-01')

            Mock Read-GitHubRunnersConfig { @(New-RunnerEntry 'node-01') }
            Mock Read-VmDeployPasswords   { @() }
            Mock Get-InfrastructureSecret { $provJson }
            Mock Get-VmKvpIpAddress { '192.168.7.5' }

            Invoke-RunnerReconcileRun -SecretSuffix 'S' `
                -OperationPhase @('Match + probe reachable VMs') `
                -Body $script:recordingBody

            Should -Invoke Get-VmKvpIpAddress -Times 0
            $entry = @($script:bodyCalls[0].Entries)[0]
            $entry.PSObject.Properties['_RouterVm'] | Should -BeNullOrEmpty
        }
    }

    Context 'cross-process timing export (finally)' {

        BeforeEach {
            Mock Read-GitHubRunnersConfig { @(New-RunnerEntry 'node-01') }
            Mock Read-VmDeployPasswords   { @() }
            Mock Get-InfrastructureSecret { '[]' }
            Mock Export-PhaseTimingTreeIfRequested {}
        }

        It 'calls Export-PhaseTimingTreeIfRequested on the success path' {
            Invoke-RunnerReconcileRun -SecretSuffix 'S' `
                -OperationPhase @('Match + probe reachable VMs') `
                -Body $script:recordingBody

            Should -Invoke Export-PhaseTimingTreeIfRequested -Times 1
        }

        It 'calls Export-PhaseTimingTreeIfRequested on the failure path' {
            $throwing = { param($RunnerEntries, $DeployPasswords) throw 'boom' }

            { Invoke-RunnerReconcileRun -SecretSuffix 'S' `
                -OperationPhase @('Match + probe reachable VMs') `
                -Body $throwing } | Should -Throw

            Should -Invoke Export-PhaseTimingTreeIfRequested -Times 1
        }
    }
}
