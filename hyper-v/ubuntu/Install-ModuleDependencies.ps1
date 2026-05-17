<#
.SYNOPSIS
    Installs and imports every PowerShell module the Infrastructure-GitHubRunners
    entry-point scripts need.

.DESCRIPTION
    Centralised so each entry-point (register-runners.ps1, deregister-runners.ps1)
    dot-sources this file once instead of repeating the same install/import
    block. Intentionally not a function: dot-sourcing this script imports
    every required module into the caller's scope, which is what the
    entry-points and their dot-sourced helpers expect.

    Step 1 - NuGet provider: PowerShellGet uses it to download from PSGallery.

    Step 2 - Infrastructure.Common: the chicken-and-egg case. It supplies
             Invoke-ModuleInstall used by every install below, so it cannot
             install itself - the inline guard is unavoidable.

    Step 3 - Everything else flows through Invoke-ModuleInstall.

    Step 4 - Posh-SSH carries the Renci.SshNet.dll that Infrastructure.HyperV's
             SSH helpers consume; Posh-SSH cmdlets themselves are NOT used
             because the ConnectionInfoGenerator in Posh-SSH 3.x drops
             algorithm entries and breaks KEX against OpenSSH 9.x on
             Ubuntu 24.04.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Step 1 - NuGet provider
$_nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $_nuget -or $_nuget.Version -lt [Version]'2.8.5.201') {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 `
        -Scope CurrentUser -Force -ForceBootstrap | Out-Null
}

# Step 2 - Infrastructure.Common (chicken-and-egg bootstrap)
$_common = Get-Module -ListAvailable -Name Infrastructure.Common |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $_common -or $_common.Version -lt [Version]'4.0.1') {
    Install-Module Infrastructure.Common -Scope CurrentUser -Force -AllowClobber
}
Import-Module Infrastructure.Common -Force -ErrorAction Stop

# Step 3 - Infrastructure.GitHub (Invoke-GitHubApi, Get-GitHubAppToken,
# Get-PendingDeployment, Set-DeploymentStatus, Invoke-RunnerTarballEnsure,
# Invoke-RunnerTarballDeploy)
Invoke-ModuleInstall -ModuleName 'Infrastructure.GitHub' -MinimumVersion '0.2.0'

# Infrastructure.HyperV (Invoke-SshClientCommand used by Invoke-RunnerTarballDeploy
# and Test-VmSshPort used by Test-RunnerVmConnectivity)
Invoke-ModuleInstall -ModuleName 'Infrastructure.HyperV' -MinimumVersion '0.3.1'

# Infrastructure.Secrets (Get-InfrastructureSecret,
# Use-MicrosoftPowerShellSecretStoreProvider)
Invoke-ModuleInstall -ModuleName 'Infrastructure.Secrets' -MinimumVersion '3.0.1'

# Step 4 - Posh-SSH (SSH.NET DLL carrier - see header comment)
Invoke-ModuleInstall -ModuleName 'Posh-SSH'
