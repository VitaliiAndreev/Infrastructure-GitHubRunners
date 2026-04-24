<#
.SYNOPSIS
    Deregisters self-hosted GitHub Actions runners from Ubuntu VMs and GitHub.

.DESCRIPTION
    Reads VM connection details and runner config from the GitHubRunners vault
    and deploy credentials from the VmUsers vault. For each reachable VM,
    stops and uninstalls the systemd service, deregisters from GitHub via
    config.sh, and removes the runner directory.

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

[CmdletBinding()]
param(
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Bootstrap Infrastructure.Common, which provides Invoke-ModuleInstall used
# for all subsequent module installs. This inline block is the only install
# logic that cannot be abstracted - you cannot call a function from a module
# that hasn't been installed yet.
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 `
    -Scope CurrentUser -Force -ForceBootstrap | Out-Null
$_common = Get-Module -ListAvailable -Name Infrastructure.Common |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $_common -or $_common.Version -lt [Version]'1.2.1') {
    Install-Module Infrastructure.Common -Scope CurrentUser -Force
}
Import-Module Infrastructure.Common -Force -ErrorAction Stop

# Dot-source helpers after Infrastructure.Common is loaded so
# Assert-RequiredProperties is available inside their function bodies.
. "$PSScriptRoot\registration\common\config\ConvertFrom-GitHubRunnersConfigJson.ps1"
. "$PSScriptRoot\registration\common\config\Join-RunnerDeployCredentials.ps1"
. "$PSScriptRoot\registration\common\config\Read-GitHubPat.ps1"
. "$PSScriptRoot\registration\common\config\Read-GitHubRunnersConfig.ps1"
. "$PSScriptRoot\registration\common\config\Read-VmDeployPasswords.ps1"
. "$PSScriptRoot\registration\common\github\Get-GitHubRunnerRegistration.ps1"
. "$PSScriptRoot\registration\common\github\Invoke-GitHubRunnersApi.ps1"
. "$PSScriptRoot\registration\common\infra\Get-RunnerPaths.ps1"
. "$PSScriptRoot\registration\common\infra\Test-RunnerVmConnectivity.ps1"
. "$PSScriptRoot\registration\common\service\Get-RunnerServiceName.ps1"
. "$PSScriptRoot\registration\common\service\Test-RunnerServiceActive.ps1"
. "$PSScriptRoot\registration\down\binary\Remove-RunnerFiles.ps1"
. "$PSScriptRoot\registration\down\github\Remove-GitHubRunner.ps1"
. "$PSScriptRoot\registration\down\registration\Invoke-RunnerConfigRemove.ps1"
. "$PSScriptRoot\registration\down\service\Remove-RunnerService.ps1"
. "$PSScriptRoot\registration\down\Invoke-VmDeregisterGroup.ps1"

# Infrastructure.Secrets provides Get-InfrastructureSecret and
# Use-MicrosoftPowerShellSecretStoreProvider used below.
Invoke-ModuleInstall -ModuleName 'Infrastructure.Secrets' -MinimumVersion '2.1.0'

# Posh-SSH is installed here solely to obtain its bundled Renci.SshNet.dll.
# Posh-SSH's own cmdlets (New-SSHSession, Invoke-SSHCommand) are NOT used
# because ConnectionInfoGenerator in Posh-SSH 3.x has a bug that drops
# algorithm entries from the SSH.NET ConnectionInfo, causing "Key exchange
# negotiation failed" against OpenSSH 9.x (Ubuntu 24.04). SSH.NET is used
# directly instead via Invoke-SshClientCommand (Infrastructure.Common) and
# the connection block in the reconciliation loop below.
Invoke-ModuleInstall -ModuleName 'Posh-SSH'

# ---------------------------------------------------------------------------
# Register the SecretStore provider for all vault reads in this session.
#    Use-MicrosoftPowerShellSecretStoreProvider installs and imports the
#    SecretManagement/SecretStore modules and registers the provider once.
#    Get-InfrastructureSecret requires this to be called first.
# ---------------------------------------------------------------------------

Use-MicrosoftPowerShellSecretStoreProvider

# ---------------------------------------------------------------------------
# Prompt for the GitHub PAT
#    Held in memory only. Used to authenticate GitHub API calls: checking
#    runner registration status, fetching short-lived removal tokens, and
#    deleting runners directly in force mode.
#    Required scope: 'repo' for private repos, 'public_repo' for public.
# ---------------------------------------------------------------------------

$pat = Read-GitHubPat

# ---------------------------------------------------------------------------
# Read configs from vaults
# ---------------------------------------------------------------------------

$runnerEntries   = Read-GitHubRunnersConfig
$deployPasswords = Read-VmDeployPasswords

# ---------------------------------------------------------------------------
# Join runner entries to deploy credentials
#    Entries with no matching password in VmUsers vault are warned and
#    skipped - they likely reference a user not yet created by
#    Infrastructure-Vm-Users.
# ---------------------------------------------------------------------------

$targets = @(Join-RunnerDeployCredentials `
    -RunnerEntries   $runnerEntries `
    -DeployPasswords $deployPasswords)

# ---------------------------------------------------------------------------
# Ping each matched VM
# ---------------------------------------------------------------------------

$reachable   = @(Test-RunnerVmConnectivity -Targets $targets)
$reachableVms = $reachable | Group-Object { $_.Entry.vmName } |
    ForEach-Object { $_.Name }

# ---------------------------------------------------------------------------
# Deregister runners via SSH on reachable VMs; handle unreachable VMs
#   Errors for unreachable VMs in normal mode are collected and reported at
#   the end so all reachable VMs are processed first.
#
#   Security: deployPassword must never appear in SSH commands, console
#   output, or error messages. Log only vmName and deployUsername.
#   Removal tokens are treated with the same care.
#
#   SSH.NET is used directly (not Posh-SSH cmdlets) - see the Posh-SSH
#   comment above for why.
# ---------------------------------------------------------------------------

$vmGroups  = $targets | Group-Object { $_.Entry.vmName }
$errors    = [System.Collections.Generic.List[string]]::new()

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

        $sshClient = $null

        try {
            $auth      = [Renci.SshNet.PasswordAuthenticationMethod]::new(
                             $username, $password)
            $connInfo  = [Renci.SshNet.ConnectionInfo]::new(
                             $ipAddress, $username, @($auth))
            $sshClient = [Renci.SshNet.SshClient]::new($connInfo)
            $sshClient.Connect()

            Invoke-VmDeregisterGroup `
                -SshClient $sshClient `
                -VmName    $vmName `
                -Targets   $group.Group `
                -Pat       $pat
        }
        catch [Renci.SshNet.Common.SshConnectionException] {
            Write-Error "[$vmName] SSH connection failed: $($_.Exception.Message)"
        }
        finally {
            if ($null -ne $sshClient) {
                if ($sshClient.IsConnected) { $sshClient.Disconnect() }
                $sshClient.Dispose()
            }
        }
    }
    else {
        # VM is unreachable - check GitHub state for each runner entry.
        foreach ($target in $group.Group) {
            $entry        = $target.Entry
            $registration = Get-GitHubRunnerRegistration `
                -Pat        $pat `
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
                    -Pat       $pat `
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

# ---------------------------------------------------------------------------
# Report any errors collected from unreachable VMs in normal mode.
#    Exit with a non-zero code so CI/callers can detect incomplete runs.
# ---------------------------------------------------------------------------

if ($errors.Count -gt 0) {
    Write-Host ""
    Write-Host "The following runners could not be deregistered:" -ForegroundColor Red
    foreach ($msg in $errors) {
        Write-Host "  $msg" -ForegroundColor Red
    }
    exit 1
}
