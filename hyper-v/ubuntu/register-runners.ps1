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
. "$PSScriptRoot\Install-ModuleDependencies.ps1"

# Dot-source helpers after the modules are loaded so Assert-RequiredProperties,
# Invoke-GitHubApi, and the SSH helpers are available inside their function
# bodies.
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
# Read configs from vaults
# ---------------------------------------------------------------------------

$runnerEntries   = Read-GitHubRunnersConfig -SecretSuffix $SecretSuffix
$deployPasswords = Read-VmDeployPasswords    -SecretSuffix $SecretSuffix

# ---------------------------------------------------------------------------
# Join runner entries to deploy credentials
#    Entries with no matching password in VmUsers vault are warned and
#    skipped - they likely reference a user not yet created by
#    Infrastructure-Vm-Users.
# ---------------------------------------------------------------------------

$targets = Join-RunnerDeployCredentials `
    -RunnerEntries   $runnerEntries `
    -DeployPasswords $deployPasswords

# ---------------------------------------------------------------------------
# Ping each matched VM
# ---------------------------------------------------------------------------

$reachable = Test-RunnerVmConnectivity -Targets $targets

# ---------------------------------------------------------------------------
# Resolve the latest runner version once - all VMs receive the same binary.
# ---------------------------------------------------------------------------

$runnerVersion = Resolve-RunnerVersion -Token $token

# ---------------------------------------------------------------------------
# Prefetch the runner tarball to the Windows host cache
#   The tarball is later served to each VM by the host file server, bypassing
#   the Hyper-V NAT bottleneck (~116 KB/s for in-VM curl from GitHub).
# ---------------------------------------------------------------------------

$_tarLocalPath = Invoke-RunnerTarballEnsure `
    -RunnerVersion $runnerVersion `
    -CacheDir      (Join-Path $env:TEMP 'runner-cache')

# ---------------------------------------------------------------------------
# Install runner binary and register each runner via SSH
#   The file server runs for the duration of all VM installs and is stopped
#   in a finally block by Invoke-WithVmFileServer regardless of errors.
#
#   The host IP is derived from the first reachable VM's ipAddress - all VMs
#   are on the same Hyper-V internal switch so any of them works.
#
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

$_hostVmIp = ($reachable | Select-Object -First 1).Entry.ipAddress
$vmGroups  = $reachable | Group-Object { $_.Entry.vmName }

Invoke-WithVmFileServer -VmIpAddress $_hostVmIp -Port 8745 -ScriptBlock {
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
                -Token         $token `
                -HostBaseUrl   $server.BaseUrl
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
}
