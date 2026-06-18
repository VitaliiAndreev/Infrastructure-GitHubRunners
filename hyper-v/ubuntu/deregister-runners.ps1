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

# ---------------------------------------------------------------------------
# Read configs from vaults
# ---------------------------------------------------------------------------

$runnerEntries   = Read-GitHubRunnersConfig -SecretSuffix $SecretSuffix
$deployPasswords = Read-VmDeployPasswords    -SecretSuffix $SecretSuffix

# ---------------------------------------------------------------------------
# Router-VM resolution (feature-53 NAT topology)
#   Read VmProvisionerConfig to find the router row (kind == 'router'),
#   discover its upstream IP via Hyper-V KVP when absent, and stamp it as
#   _RouterVm on every runner entry sharing the router's privateSwitchName.
#   New-VmSshClientWithJump downstream uses that property to decide
#   direct-vs-jumped session per VM. Symmetric with register-runners.ps1.
# ---------------------------------------------------------------------------

$provisionerJson = Get-InfrastructureSecret `
                       -VaultName  'VmProvisioner' `
                       -SecretName "VmProvisionerConfig-$SecretSuffix"
$provisionerVms  = @($provisionerJson | ConvertFrom-Json)

$routerVm = $provisionerVms | Where-Object {
    $_.PSObject.Properties['kind'] -and $_.kind -eq 'router'
} | Select-Object -First 1

if ($null -ne $routerVm) {
    Import-Module Hyper-V -ErrorAction Stop

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

    $provisionerIndex = @{}
    foreach ($vm in $provisionerVms) {
        $provisionerIndex[$vm.vmName] = $vm
    }
    foreach ($entry in $runnerEntries) {
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

$reachable   = Test-RunnerVmConnectivity -Targets $targets
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

        # See register-runners.ps1 for the vmShim rationale - New-VmSsh-
        # ClientWithJump expects ipAddress/username/password on a single
        # object, and runner entries use deployUsername.
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
                -Token     $token
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
                -Token      $token `
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
                    -Token     $token `
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
