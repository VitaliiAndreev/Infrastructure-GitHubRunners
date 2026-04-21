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
    - u-runner-deploy and u-actions-runner exist on each VM
      (Infrastructure-Vm-Users).

.EXAMPLE
    .\register-runners.ps1
#>

# pat is assigned here and consumed by Step 5, which is not yet implemented.
# The suppress attribute prevents a false PSScriptAnalyzer warning until
# that step is added.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'pat')]
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
. "$PSScriptRoot\install\Resolve-RunnerVersion.ps1"
. "$PSScriptRoot\install\Invoke-TarballDownload.ps1"
. "$PSScriptRoot\install\Invoke-RunnerExtract.ps1"
. "$PSScriptRoot\install\Invoke-RunnerInstall.ps1"
# TODO: Step 5 - . "$PSScriptRoot\register\register-service.ps1"

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
#    The PAT is held in memory only. It authenticates the GitHub Releases
#    API call (Step 4) and will be used in Step 5 to fetch registration
#    tokens and list existing runners via the GitHub API.
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
# Install runner binary via SSH
#   Group reachable entries by VM so one SSH connection handles all runners
#   on a host. Open the connection as u-runner-deploy - admin credentials
#   are not used or stored in this repo (see plan.md prerequisites).
#
#   Security: deployPassword must never appear in SSH commands, console
#   output, or error messages. Log only vmName and deployUsername.
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

        Invoke-RunnerInstall `
            -SshClient      $sshClient `
            -VmName         $vmName `
            -RunnerEntries  @($group.Group | ForEach-Object { $_.Entry }) `
            -RunnerVersion  $runnerVersion
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

# ---------------------------------------------------------------------------
# TODO: Step 5 - Register runner and ensure service is running
# ---------------------------------------------------------------------------
