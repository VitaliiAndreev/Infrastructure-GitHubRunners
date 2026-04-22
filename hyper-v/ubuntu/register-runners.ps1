<#
.SYNOPSIS
    Installs and registers self-hosted GitHub Actions runners on Ubuntu VMs.

.DESCRIPTION
    Reads VM connection details and runner config from the GitHubRunners vault
    and deploy credentials from the VmUsers vault. For each reachable VM,
    installs the runner binary and registers it with GitHub, then ensures the
    systemd service is running.

    Prerequisites:
    - setup-secrets.ps1 has been run at least once on this machine.
    - VMs are provisioned (Infrastructure-Vm-Provisioner) and reachable.
    - Deploy user and runner service user exist on each VM
      (Infrastructure-Vm-Users).

.EXAMPLE
    .\register-runners.ps1
#>

[CmdletBinding()]
param()

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
. "$PSScriptRoot\resolve\ConvertFrom-GitHubRunnersConfigJson.ps1"
. "$PSScriptRoot\resolve\Read-GitHubPat.ps1"
. "$PSScriptRoot\resolve\Read-GitHubRunnersConfig.ps1"
. "$PSScriptRoot\resolve\Read-VmDeployPasswords.ps1"
. "$PSScriptRoot\resolve\Join-RunnerDeployCredentials.ps1"
. "$PSScriptRoot\resolve\Test-RunnerVmConnectivity.ps1"
. "$PSScriptRoot\resolve\Get-RunnerPaths.ps1"
. "$PSScriptRoot\install\Resolve-RunnerVersion.ps1"
. "$PSScriptRoot\install\Invoke-TarballDownload.ps1"
. "$PSScriptRoot\install\Invoke-RunnerExtract.ps1"
. "$PSScriptRoot\install\Invoke-RunnerInstall.ps1"
. "$PSScriptRoot\register\Get-GitHubRunnerRegistration.ps1"
. "$PSScriptRoot\register\New-RunnerRegistrationToken.ps1"
. "$PSScriptRoot\register\Get-RunnerServiceName.ps1"
. "$PSScriptRoot\register\Test-RunnerServiceActive.ps1"
. "$PSScriptRoot\register\Start-RunnerService.ps1"
. "$PSScriptRoot\register\Invoke-RunnerRegistration.ps1"
. "$PSScriptRoot\Invoke-VmRunnerGroup.ps1"

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
#    Held in memory only. Used to authenticate GitHub API calls: resolving
#    the latest runner version, checking runner registration status, and
#    fetching short-lived registration tokens.
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

$reachable = @(Test-RunnerVmConnectivity -Targets $targets)

# ---------------------------------------------------------------------------
# Resolve the latest runner version once - all VMs receive the same binary.
# ---------------------------------------------------------------------------

$runnerVersion = Resolve-RunnerVersion -Pat $pat

# ---------------------------------------------------------------------------
# Install runner binary and register each runner via SSH
#   Group reachable entries by VM so one SSH connection handles all runners
#   on a host. Open the connection as the deploy user - admin credentials
#   are not used or stored in this repo (see plan.md prerequisites).
#
#   Security: deployPassword must never appear in SSH commands, console
#   output, or error messages. Log only vmName and deployUsername.
#   Registration tokens are treated with the same care.
#
#   SSH.NET is used directly (not Posh-SSH cmdlets) - see the Posh-SSH
#   comment above for why.
# ---------------------------------------------------------------------------

$vmGroups = $reachable | Group-Object { $_.Entry.vmName }

foreach ($group in $vmGroups) {
    $first     = $group.Group[0]
    $vmName    = $first.Entry.vmName
    $ipAddress = $first.Entry.ipAddress
    $username  = $first.Entry.deployUsername
    # Plain string - see resolve\Read-VmDeployPasswords.ps1 for rationale.
    $password  = $first.Password

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

        Invoke-VmRunnerGroup `
            -SshClient     $sshClient `
            -VmName        $vmName `
            -Targets       $group.Group `
            -RunnerVersion $runnerVersion `
            -Pat           $pat
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
