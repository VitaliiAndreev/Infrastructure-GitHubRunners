<#
.SYNOPSIS
    Installs and registers self-hosted GitHub Actions runners on Ubuntu VMs.

.DESCRIPTION
    Reads VM connection details and runner config from the GitHubRunners vault
    and deploy credentials from the VmUsers vault. For each reachable VM,
    installs the runner binary and registers it with GitHub, then ensures the
    systemd service is running.

    The shared opening - the two vault reads, the feature-53 router resolution,
    the phase-timing setup, and the timing export - lives in the shared
    Invoke-RunnerReconcileRun orchestrator (registration/common); this entry
    script supplies only the registration direction: its operation phases and a
    -Body that joins credentials, probes reachability, prefetches the tarball,
    and installs/registers each runner over a host file server.

    Prerequisites:
    - setup-secrets.ps1 has been run at least once on this machine.
    - VMs are provisioned (Infrastructure-Vm-Provisioner) and reachable.
    - Deploy user and runner service user exist on each VM
      (Infrastructure-Vm-Users).

.EXAMPLE
    .\register-runners.ps1
#>

# Dispose() on an SSH session can throw on double-dispose or an already
# dropped connection; the finally-block cleanup swallows that so it cannot
# derail the surrounding teardown. Suppress the empty-catch rule file-wide
# for that single best-effort site (the rule stays live elsewhere).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingEmptyCatchBlock', '',
    Justification = 'Dispose cleanup must not throw out of a finally block')]
# Deploy passwords are plaintext by design (see
# registration/common/config/Read-VmDeployPasswords.ps1 for the rationale); the
# -Body callback param only forwards that documented collection to
# Join-RunnerDeployCredentials, so the plaintext-password rule is a false
# positive here. Suppress it file-wide (the rule stays live for real secrets).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingPlainTextForPassword', '',
    Justification = 'Deploy passwords are plaintext by design; the param only forwards them')]
[CmdletBinding()]
param(
    # GitHub token. When provided, skips the interactive Read-GitHubPat
    # prompt - required for unattended callers such as the E2E agent.
    [Parameter()]
    [string] $Token = '',

    # Required. The vault reads target `GitHubRunnersConfig-<Suffix>`
    # and `VmUsersConfig-<Suffix>`. See provision.ps1 in
    # Infrastructure-Vm-Provisioner for the suffix contract.
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SecretSuffix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Install / import every required PowerShell module. The helper owns the
# dependency list for this repo so each entry-point script does not repeat
# the bootstrap block.
. "$PSScriptRoot\..\shared\Install-ModuleDependencies.ps1"

# Dot-source helpers after the modules are loaded so Assert-RequiredProperties,
# Invoke-GitHubApi, and the SSH helpers are available inside their function
# bodies. The shared orchestrator drives the run; the registration-direction
# helpers back its -Body. Read-GitHubRunnersConfig / Read-VmDeployPasswords are
# dot-sourced here because the orchestrator resolves them in this scope.
. "$PSScriptRoot\registration\common\config\ConvertFrom-GitHubRunnersConfigJson.ps1"
. "$PSScriptRoot\registration\common\config\Join-RunnerDeployCredentials.ps1"
. "$PSScriptRoot\registration\common\config\Read-GitHubPat.ps1"
. "$PSScriptRoot\registration\common\config\Read-GitHubRunnersConfig.ps1"
. "$PSScriptRoot\registration\common\config\Read-VmDeployPasswords.ps1"
. "$PSScriptRoot\registration\common\github\Get-GitHubRunnerRegistration.ps1"
. "$PSScriptRoot\registration\common\infra\Get-RunnerPaths.ps1"
. "$PSScriptRoot\registration\common\infra\Test-RunnerVmConnectivity.ps1"
. "$PSScriptRoot\registration\common\service\Get-RunnerServiceName.ps1"
. "$PSScriptRoot\registration\common\service\Test-RunnerServiceActive.ps1"
. "$PSScriptRoot\registration\common\Invoke-RunnerReconcileRun.ps1"
. "$PSScriptRoot\registration\up\binary\Invoke-RunnerExtract.ps1"
. "$PSScriptRoot\registration\up\binary\Invoke-RunnerInstall.ps1"
. "$PSScriptRoot\registration\up\github\Resolve-RunnerVersion.ps1"
. "$PSScriptRoot\registration\up\registration\Invoke-RunnerRegistration.ps1"
. "$PSScriptRoot\registration\up\service\Start-RunnerService.ps1"
. "$PSScriptRoot\registration\up\Invoke-VmRunnerGroup.ps1"

# ---------------------------------------------------------------------------
# Register the SecretStore provider for all vault reads in this session.
#    Use-MicrosoftPowerShellSecretStoreProvider installs and imports the
#    SecretManagement/SecretStore modules and registers the provider once.
#    Get-InfrastructureSecret requires this to be called first.
# ---------------------------------------------------------------------------

Use-MicrosoftPowerShellSecretStoreProvider

# ---------------------------------------------------------------------------
# Prompt for the GitHub token
#    Held in memory only. Used to authenticate GitHub API calls: resolving
#    the latest runner version, checking runner registration status, and
#    fetching short-lived registration tokens.
#    Required scope: 'repo' for private repos, 'public_repo' for public.
# ---------------------------------------------------------------------------

if (-not $Token) {
    $Token = Read-GitHubPat
}

# ---------------------------------------------------------------------------
# Drive the shared orchestration in the registration direction. The orchestrator
# times the shared opening (read configs + resolve router IP) and exports the
# tree on the opt-in; the -Body below owns the registration-specific phases,
# receiving the router-stamped runner entries and deploy passwords.
# ---------------------------------------------------------------------------

Invoke-RunnerReconcileRun `
    -SecretSuffix   $SecretSuffix `
    -OperationPhase @(
        'Match + probe reachable VMs',
        'Resolve + prefetch runner tarball',
        'Install + register runners'
    ) `
    -Body {
        param($RunnerEntries, $DeployPasswords)

        Invoke-WithPhaseTimer -Name 'Match + probe reachable VMs' -Action {

            # -----------------------------------------------------------------
            # Join runner entries to deploy credentials
            #    Entries with no matching password in VmUsers vault are warned
            #    and skipped - they likely reference a user not yet created by
            #    Infrastructure-Vm-Users.
            # -----------------------------------------------------------------

            $targets = Join-RunnerDeployCredentials `
                -RunnerEntries   $RunnerEntries `
                -DeployPasswords $DeployPasswords

            # Ping each matched VM. $script:-scoped for the install phase below
            # (child-scope survival).
            $script:reachable = Test-RunnerVmConnectivity -Targets $targets
        }

        Invoke-WithPhaseTimer -Name 'Resolve + prefetch runner tarball' -Action {

            # -----------------------------------------------------------------
            # Resolve the latest runner version once - all VMs receive the same
            # binary - then prefetch the tarball to the Windows host cache. The
            # tarball is later served to each VM by the host file server,
            # bypassing the Hyper-V NAT bottleneck (~116 KB/s for in-VM curl
            # from GitHub). Both land in the script scope for the install phase.
            # -----------------------------------------------------------------

            $script:runnerVersion     = Resolve-RunnerVersion -Token $Token
            $script:runnerTarballPath = Invoke-RunnerTarballEnsure `
                -RunnerVersion $script:runnerVersion `
                -CacheDir      (Join-Path $env:TEMP 'runner-cache')
        }

        Invoke-WithPhaseTimer -Name 'Install + register runners' -Action {

            # -----------------------------------------------------------------
            # Install runner binary and register each runner via SSH
            #   The file server runs for the duration of all VM installs and is
            #   stopped in a finally block by Invoke-WithVmFileServer regardless
            #   of errors.
            #
            #   File-server binding decision:
            #     - No router (legacy / pre-feature-53): bind on the host
            #       adapter sharing the runner VM's /24. Invoke-WithVmFileServer's
            #       -VmIpAddress path calls Get-VmSwitchHostIp on it.
            #     - With router (feature-53 NAT): the runner VM lives on a
            #       private switch the host has no route to, so binding by its IP
            #       throws "No host adapter found". Resolve the host adapter on
            #       the router's UPSTREAM LAN instead and pass -HostIp
            #       explicitly; runners reach the listener via their default
            #       route -> router priv0 -> router MASQUERADE on ext0 -> host.
            #
            #   Group reachable entries by VM so one SSH connection handles all
            #   runners on a host. Open the connection as the deploy user - admin
            #   credentials are not used or stored in this repo (see plan.md
            #   prerequisites).
            #
            #   Security: deployPassword must never appear in SSH commands,
            #   console output, or error messages. Log only vmName and
            #   deployUsername. Registration tokens are treated with the same
            #   care.
            # -----------------------------------------------------------------

            # Local aliases over the script-scoped cross-phase values so the
            # install logic below (and the nested file-server scriptblock's
            # closure) reads exactly as it did before the phase wrapping.
            $reachable     = $script:reachable
            $runnerVersion = $script:runnerVersion
            $_tarLocalPath = $script:runnerTarballPath

            $_firstEntry = ($reachable | Select-Object -First 1).Entry
            $_hostVmIp   = $_firstEntry.ipAddress
            $_hasRouter  = $_firstEntry.PSObject.Properties['_RouterVm'] -and `
                           $_firstEntry._RouterVm
            $vmGroups    = $reachable | Group-Object { $_.Entry.vmName }

            $fileServerParams = @{ Port = 8745 }
            if ($_hasRouter) {
                $fileServerParams['HostIp'] = Get-VmSwitchHostIp `
                                                  -VmIpAddress $_firstEntry._RouterVm.ipAddress
            } else {
                $fileServerParams['VmIpAddress'] = $_hostVmIp
            }

            Invoke-WithVmFileServer @fileServerParams -ScriptBlock {
                param($server)

                # Stage the pre-fetched tarball once; all VMs download from the same URL.
                $null = Add-VmFileServerFile -Server $server -LocalPath $_tarLocalPath

                foreach ($group in $vmGroups) {
                    $first     = $group.Group[0]
                    $vmName    = $first.Entry.vmName
                    $ipAddress = $first.Entry.ipAddress
                    $username  = $first.Entry.deployUsername
                    # Plain string - see resolve\Read-VmDeployPasswords.ps1 for rationale.
                    $password  = $first.Password

                    Write-Host ""
                    Write-Host "[$vmName] Connecting as '$username' ..." -ForegroundColor Cyan

                    # New-VmSshClientWithJump expects ipAddress/username/password
                    # on the supplied object, plus _RouterVm when a jump is
                    # needed. Runner entries carry deployUsername (not username),
                    # so we build a small adapter object rather than rename the
                    # Entry's field (which would ripple through Invoke-VmRunnerGroup
                    # and all its callers).
                    $vmShim = [PSCustomObject]@{
                        ipAddress = $ipAddress
                        username  = $username
                        password  = $password
                    }
                    if ($first.Entry.PSObject.Properties['_RouterVm'] -and `
                        $first.Entry._RouterVm) {
                        Add-Member -InputObject $vmShim -MemberType NoteProperty `
                                   -Name '_RouterVm' -Value $first.Entry._RouterVm -Force
                    }

                    $sshSession = $null

                    try {
                        $sshSession = New-VmSshClientWithJump -Vm $vmShim

                        Invoke-VmRunnerGroup `
                            -SshClient     $sshSession.Client `
                            -VmName        $vmName `
                            -Targets       $group.Group `
                            -RunnerVersion $runnerVersion `
                            -Token         $Token `
                            -HostBaseUrl   $server.BaseUrl
                    }
                    catch [Renci.SshNet.Common.SshConnectionException] {
                        Write-Error "[$vmName] SSH connection failed: $($_.Exception.Message)"
                    }
                    finally {
                        if ($null -ne $sshSession) {
                            try { $sshSession.Dispose() } catch {}
                        }
                    }
                }
            }
        }
    }
