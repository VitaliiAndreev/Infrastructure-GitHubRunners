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

# These variables are assigned here and consumed by Steps 4 and 5, which are
# not yet implemented. The suppress attributes prevent false PSScriptAnalyzer
# warnings until those steps are added.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'pat')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'reachable')]
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
# TODO: Step 4 - . "$PSScriptRoot\install-runners.ps1"
# TODO: Step 5 - . "$PSScriptRoot\register-service.ps1"

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
#    The PAT is held in memory only. It is used in Steps 4-5 to fetch
#    registration tokens and list existing runners via the GitHub API.
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
# TODO: Step 4 - Install runner binary via SSH
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# TODO: Step 5 - Register runner and ensure service is running
# ---------------------------------------------------------------------------
