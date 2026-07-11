<#
.SYNOPSIS
    Deregisters self-hosted GitHub Actions runners from Ubuntu VMs and GitHub.

.DESCRIPTION
    Reads VM connection details and runner config from the GitHubRunners vault
    and deploy credentials from the VmUsers vault. For each reachable VM,
    stops and uninstalls the systemd service, deregisters from GitHub via
    config.sh, and removes the runner directory.

    The shared opening - the two vault reads, the feature-53 router resolution,
    the phase-timing setup, and the timing export - lives in the shared
    Invoke-RunnerReconcileRun orchestrator (registration/common); this entry
    script supplies only the deregistration direction: its operation phases and
    a -Body that probes reachability and removes each runner (with a force-mode
    GitHub-API path for unreachable VMs).

    Prerequisites:
    - setup-secrets.ps1 has been run at least once on this machine.
    - VMs are provisioned (Infrastructure-Vm-Provisioner) and reachable, or
      -Force is used to remove GitHub registrations without SSH access.
    - Deploy user and runner service user exist on each VM
      (Infrastructure-Vm-Users).

.PARAMETER Force
    When specified, runners on unreachable VMs that are still registered on
    GitHub are removed via the GitHub API without SSH access. Use when a VM
    is permanently gone or being rebuilt.

    Without -Force, an unreachable VM with registered runners is reported
    as an error at the end of the run.

.EXAMPLE
    .\deregister-runners.ps1

.EXAMPLE
    .\deregister-runners.ps1 -Force
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
    [switch] $Force,

    # GitHub token. When provided, skips the interactive Read-GitHubPat
    # prompt - required for unattended callers such as the E2E agent.
    [Parameter()]
    [string] $Token = '',

    # Required. See register-runners.ps1 for the suffix contract.
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
# bodies. The shared orchestrator drives the run; the deregistration-direction
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
. "$PSScriptRoot\registration\down\binary\Remove-RunnerFiles.ps1"
. "$PSScriptRoot\registration\down\github\Remove-GitHubRunner.ps1"
. "$PSScriptRoot\registration\down\registration\Invoke-RunnerConfigRemove.ps1"
. "$PSScriptRoot\registration\down\service\Remove-RunnerService.ps1"
. "$PSScriptRoot\registration\down\Invoke-VmDeregisterGroup.ps1"

# ---------------------------------------------------------------------------
# Register the SecretStore provider for all vault reads in this session.
#    Use-MicrosoftPowerShellSecretStoreProvider installs and imports the
#    SecretManagement/SecretStore modules and registers the provider once.
#    Get-InfrastructureSecret requires this to be called first.
# ---------------------------------------------------------------------------

Use-MicrosoftPowerShellSecretStoreProvider

# ---------------------------------------------------------------------------
# Prompt for the GitHub token
#    Held in memory only. Used to authenticate GitHub API calls: checking
#    runner registration status, fetching short-lived removal tokens, and
#    deleting runners directly in force mode.
#    Required scope: 'repo' for private repos, 'public_repo' for public.
# ---------------------------------------------------------------------------

if (-not $Token) {
    $Token = Read-GitHubPat
}

# Collected across the deregister phase so all reachable VMs are processed
# first, then reported at the end. Declared here (entry-script scope) so the
# -Body phase can append to it via closure and it is still readable after the
# orchestrator returns, to drive the non-zero exit below.
$errors = [System.Collections.Generic.List[string]]::new()

# ---------------------------------------------------------------------------
# Drive the shared orchestration in the deregistration direction. The
# orchestrator times the shared opening (read configs + resolve router IP) and
# exports the tree on the opt-in; the -Body below owns the deregistration
# phases, receiving the router-stamped runner entries and deploy passwords.
# The down path has no tarball prefetch, so it declares two operation phases to
# the up path's three.
# ---------------------------------------------------------------------------

Invoke-RunnerReconcileRun `
    -SecretSuffix   $SecretSuffix `
    -OperationPhase @(
        'Match + probe reachable VMs',
        'Deregister runners'
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

            # $script:-scoped so the deregister phase below can read the matched
            # targets and the reachable-VM name set (child-scope survival).
            $script:targets = Join-RunnerDeployCredentials `
                -RunnerEntries   $RunnerEntries `
                -DeployPasswords $DeployPasswords

            # Ping each matched VM.
            $reachable = Test-RunnerVmConnectivity -Targets $script:targets
            $script:reachableVms = $reachable | Group-Object { $_.Entry.vmName } |
                ForEach-Object { $_.Name }
        }

        Invoke-WithPhaseTimer -Name 'Deregister runners' -Action {

            # -----------------------------------------------------------------
            # Deregister runners via SSH on reachable VMs; handle unreachable VMs
            #   Errors for unreachable VMs in normal mode are collected and
            #   reported after the run so all reachable VMs are processed first.
            #
            #   Security: deployPassword must never appear in SSH commands,
            #   console output, or error messages. Log only vmName and
            #   deployUsername. Removal tokens are treated with the same care.
            #
            #   SSH.NET is used directly (not Posh-SSH cmdlets) - see the
            #   Install-ModuleDependencies Posh-SSH comment for why.
            # -----------------------------------------------------------------

            # Local aliases over the script-scoped cross-phase values so the
            # loop below reads exactly as it did before the phase wrapping.
            $targets      = $script:targets
            $reachableVms = $script:reachableVms

            $vmGroups = $targets | Group-Object { $_.Entry.vmName }

            foreach ($group in $vmGroups) {
                $first     = $group.Group[0]
                $vmName    = $first.Entry.vmName
                $ipAddress = $first.Entry.ipAddress
                $username  = $first.Entry.deployUsername
                # Plain string - see registration\common\config\Read-VmDeployPasswords.ps1
                # for rationale.
                $password  = $first.Password

                if ($reachableVms -contains $vmName) {
                    Write-Host ""
                    Write-Host "[$vmName] Connecting as '$username' ..." -ForegroundColor Cyan

                    # See register-runners.ps1 for the vmShim rationale -
                    # New-VmSshClientWithJump expects ipAddress/username/password
                    # on a single object, and runner entries use deployUsername.
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

                        Invoke-VmDeregisterGroup `
                            -SshClient $sshSession.Client `
                            -VmName    $vmName `
                            -Targets   $group.Group `
                            -Token     $Token
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
                else {
                    # VM is unreachable - check GitHub state for each runner entry.
                    foreach ($target in $group.Group) {
                        $entry        = $target.Entry
                        $registration = Get-GitHubRunnerRegistration `
                            -Token      $Token `
                            -GithubUrl  $entry.githubUrl `
                            -RunnerName $entry.runnerName

                        if (-not $registration) {
                            Write-Host ("[$vmName] Runner '$($entry.runnerName)': unreachable " +
                                "and not on GitHub - skipping.") -ForegroundColor Yellow
                            continue
                        }

                        if ($Force) {
                            # Remove the GitHub registration directly - no SSH access needed.
                            Write-Host ("[$vmName] Runner '$($entry.runnerName)': unreachable " +
                                "- removing from GitHub (force mode).") -ForegroundColor Yellow
                            Remove-GitHubRunner `
                                -Token     $Token `
                                -GithubUrl $entry.githubUrl `
                                -RunnerId  $registration.id
                        }
                        else {
                            $errors.Add(
                                "[$vmName] Runner '$($entry.runnerName)': VM unreachable and " +
                                "runner is still registered on GitHub. Re-run with -Force to " +
                                "remove it via the GitHub API, or deregister manually.")
                        }
                    }
                }
            }
        }
    }

# ---------------------------------------------------------------------------
# Report any errors collected from unreachable VMs in normal mode.
#    Runs after the orchestrator returns (so the timing export in its finally
#    always fires first). Exit with a non-zero code so CI/callers can detect
#    incomplete runs. Reached only on the success path; if a phase threw, the
#    exception has already propagated past this point.
# ---------------------------------------------------------------------------

if ($errors.Count -gt 0) {
    Write-Host ""
    Write-Host "The following runners could not be deregistered:" -ForegroundColor Red
    foreach ($msg in $errors) {
        Write-Host "  $msg" -ForegroundColor Red
    }
    exit 1
}
