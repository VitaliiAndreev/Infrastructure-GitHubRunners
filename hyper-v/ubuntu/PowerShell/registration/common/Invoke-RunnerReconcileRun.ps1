<#
.NOTES
    Do not run this file directly. It is dot-sourced by register-runners.ps1 and
    deregister-runners.ps1 after Common.PowerShell + Infrastructure.* are loaded
    (which supply the phase-timing shims, Get-InfrastructureSecret, and the
    jump-host helpers) and after the caller has dot-sourced its own
    registration/common config helpers (Read-GitHubRunnersConfig,
    Read-VmDeployPasswords), which this orchestrator calls.
#>

# ---------------------------------------------------------------------------
# Invoke-RunnerReconcileRun
#   The shared front matter and cross-process timing envelope for the two
#   runner entry scripts. register-runners.ps1 and deregister-runners.ps1 both
#   open with the same work - read the two vault configs, resolve the feature-53
#   NAT router topology, and stamp _RouterVm onto the runner entries - and both
#   close by handing their phase-timing tree to a parent orchestrator on the
#   TIMING_TREE_OUTPUT_PATH opt-in. Only the middle differs: registration
#   prefetches the tarball and installs over a host file server; deregistration
#   removes (with a force-mode GitHub-API path for unreachable VMs). So the
#   shared opening phase and the timing setup / finally live here once, and each
#   entry script supplies just its operation-specific phases via -Body.
#
#   Two verbatim copies of a two-vault read + router-resolution flow would drift
#   silently: a fix to one (a KVP-discovery tweak, a switch-matching correction)
#   is easy to forget in the other. Symmetric with Invoke-VmUserReconcileRun in
#   Infrastructure-Vm-Users, which plays the same role for create-users.ps1 /
#   remove-users.ps1.
#
#   Because this is a function seam (not a top-level script), it can be
#   dot-sourced and exercised end-to-end with Read-GitHubRunnersConfig /
#   Read-VmDeployPasswords / Get-InfrastructureSecret / Get-VmKvpIpAddress
#   mocked, so the shared flow gains real behavioural coverage rather than the
#   AST-only structural checks the top-level entry scripts are limited to.
# ---------------------------------------------------------------------------

function Invoke-RunnerReconcileRun {
    [CmdletBinding()]
    param(
        # The vault reads target `GitHubRunnersConfig-<Suffix>`,
        # `VmUsersConfig-<Suffix>` (deploy passwords), and
        # `VmProvisionerConfig-<Suffix>` (router topology). See
        # register-runners.ps1 for the suffix contract.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SecretSuffix,

        # The operation-specific phase names, in run order, that -Body times.
        # Prepended with the shared 'Read configs + resolve router IP' phase
        # this function owns, so Initialize-PhaseTimings declares the full
        # ordered set up front (a phase never reached because an earlier one
        # failed still renders). Each name here must match an
        # Invoke-WithPhaseTimer -Name in -Body.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]] $OperationPhase,

        # Runs the operation-specific phases after the shared config+router
        # phase, receiving the router-stamped runner entries and the deploy
        # passwords (positional: $RunnerEntries, $DeployPasswords). This is the
        # only part that differs between the register and deregister directions.
        [Parameter(Mandatory)]
        [scriptblock] $Body
    )

    # -----------------------------------------------------------------------
    # Phase-timing setup
    #   Initialize-PhaseTimings / Invoke-WithPhaseTimer /
    #   Export-PhaseTimingTreeIfRequested are the 2-level compat shims exported
    #   by Common.PowerShell. Declare the shared opening stage plus the caller's
    #   operation stages in run order so the emitted tree lists each one. The
    #   stages run inside Invoke-WithPhaseTimer wrappers; the outer try/finally
    #   calls the self-guarding Export-PhaseTimingTreeIfRequested shim, which
    #   serialises the tree only when the TIMING_TREE_OUTPUT_PATH opt-in is set
    #   so the E2E parent can graft this run's timings under the runner part
    #   that shelled out to the entry script. Unset, behaviour is unchanged (no
    #   file, no extra output).
    # -----------------------------------------------------------------------

    Initialize-PhaseTimings -Phases (@('Read configs + resolve router IP') + $OperationPhase)

    try {

        Invoke-WithPhaseTimer -Name 'Read configs + resolve router IP' -Action {

            # ---------------------------------------------------------------
            # Read configs from vaults
            # ---------------------------------------------------------------

            # $script:-scoped because Invoke-WithPhaseTimer runs -Action in a
            # child scope; a bare assignment would not survive to the -Body
            # invocation below, which reads them back.
            $script:runnerEntries   = Read-GitHubRunnersConfig -SecretSuffix $SecretSuffix
            $script:deployPasswords = Read-VmDeployPasswords    -SecretSuffix $SecretSuffix

            # ---------------------------------------------------------------
            # Router-VM resolution (feature-53 NAT topology)
            #   Read VmProvisionerConfig to find the router row (kind ==
            #   'router'), discover its upstream IP via Hyper-V KVP when absent,
            #   and stamp it as _RouterVm on every runner entry sharing the
            #   router's privateSwitchName. New-VmSshClientWithJump downstream
            #   uses that property to decide direct-vs-jumped session per VM
            #   without callers having to thread the router VM explicitly. When
            #   no router row is present the topology predates feature 53 -
            #   every workload keeps the legacy direct path.
            # ---------------------------------------------------------------

            $provisionerJson = Get-InfrastructureSecret `
                                   -VaultName  'VmProvisioner' `
                                   -SecretName "VmProvisionerConfig-$SecretSuffix"
            $provisionerVms  = @($provisionerJson | ConvertFrom-Json)

            $routerVm = $provisionerVms | Where-Object {
                $_.PSObject.Properties['kind'] -and $_.kind -eq 'router'
            } | Select-Object -First 1

            if ($null -ne $routerVm) {
                Import-Module Hyper-V -ErrorAction Stop

                # Static-mode routers (externalDhcp = false) keep their
                # ipAddress in the vault; DHCP-mode routers (the schema default)
                # carry it only in Hyper-V KVP. Discover on demand so both modes
                # work without forking the call site.
                if (-not ($routerVm.PSObject.Properties['ipAddress'] -and $routerVm.ipAddress)) {
                    Write-Host "Resolving router '$($routerVm.vmName)' upstream IP via KVP ..." `
                        -NoNewline -ForegroundColor Cyan
                    $routerIp = Get-VmKvpIpAddress `
                                    -VmName     $routerVm.vmName `
                                    -SwitchName $routerVm.externalSwitchName `
                                    -OnPoll     { Write-Host '.' -NoNewline -ForegroundColor Cyan }
                    Add-Member -InputObject $routerVm -MemberType NoteProperty `
                               -Name 'ipAddress' -Value $routerIp -Force
                    Write-Host " $routerIp" -ForegroundColor Green
                }

                # Stamp _RouterVm on each runner entry whose corresponding
                # provisioner row sits on the router's privateSwitchName. Match
                # by vmName since runner entries do not carry switch fields
                # themselves.
                $provisionerIndex = @{}
                foreach ($vm in $provisionerVms) {
                    $provisionerIndex[$vm.vmName] = $vm
                }
                foreach ($entry in $script:runnerEntries) {
                    if (-not $provisionerIndex.ContainsKey($entry.vmName)) { continue }
                    $provVm   = $provisionerIndex[$entry.vmName]
                    $isRouter = $provVm.PSObject.Properties['kind'] -and `
                                $provVm.kind -eq 'router'
                    if ($isRouter) { continue }
                    $sameEnv  = $provVm.PSObject.Properties['privateSwitchName'] -and `
                                $provVm.privateSwitchName -eq $routerVm.privateSwitchName
                    if (-not $sameEnv) { continue }

                    Add-Member -InputObject $entry -MemberType NoteProperty `
                               -Name '_RouterVm' -Value $routerVm -Force
                }
            }
        }

        # Hand the resolved context to the operation-specific phases. The body
        # owns its own Invoke-WithPhaseTimer wrappers (named per -OperationPhase)
        # and any cross-phase $script: state within itself.
        & $Body $script:runnerEntries $script:deployPasswords
    }
    finally {
        # Cross-process handoff (opt-in). When a parent orchestrator (the E2E
        # runner) sets TIMING_TREE_OUTPUT_PATH, the shim serialises the phase
        # tree to that path so the parent can graft this run's timings under the
        # runner part that shelled out to the entry script. The shim owns the
        # env-var name and the guard, so this stays one call: it fires on
        # success AND failure, and no-ops when the var is unset or timings were
        # never initialised (no file written).
        Export-PhaseTimingTreeIfRequested
    }
}
