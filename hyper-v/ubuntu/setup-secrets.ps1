<#
.SYNOPSIS
    One-time setup: stores the GitHub runner JSON config in the local vault.

.DESCRIPTION
    Run once per machine before running register-runners.ps1.
    Re-running safely updates the stored config.

    Installs Infrastructure.Common and Infrastructure.Secrets from PSGallery
    automatically if not already present on this machine.

.PARAMETER ConfigJson
    The runner config as a raw JSON string. Mutually exclusive with -ConfigFile.

.PARAMETER ConfigFile
    Path to a JSON file containing the runner config. Mutually exclusive with
    -ConfigJson. The file is read at runtime; it is not modified.

.PARAMETER RequireVaultPassword
    When specified, the SecretStore vault requires a password each session.
    Recommended on shared or less-trusted machines.

.EXAMPLE
    .\setup-secrets.ps1 -ConfigFile C:\private\runners-config.json

.EXAMPLE
    .\setup-secrets.ps1 -ConfigFile C:\private\runners-config.json -RequireVaultPassword
#>

[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Json')]
    [string] $ConfigJson,

    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string] $ConfigFile,

    [Parameter()]
    [switch] $RequireVaultPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Bootstrap Infrastructure.Common, which provides Invoke-ModuleInstall used
# for all subsequent module installs. This inline block is the only install
# logic that cannot be abstracted - you cannot call a function from a module
# that hasn't been installed yet.
# NuGet must be ensured here explicitly because Invoke-ModuleInstall is not
# yet available to do it, and Install-Module requires NuGet to reach PSGallery.
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 `
    -Scope CurrentUser -Force -ForceBootstrap | Out-Null
$_common = Get-Module -ListAvailable -Name Infrastructure.Common |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $_common -or $_common.Version -lt [Version]'1.2.1') {
    Install-Module Infrastructure.Common -Scope CurrentUser -Force
}
Import-Module Infrastructure.Common -Force -ErrorAction Stop

# ConvertFrom-GitHubRunnersConfigJson.ps1 is dot-sourced after Infrastructure.Common
# is loaded. It only calls Assert-RequiredProperties inside function bodies,
# not at load time, so this ordering is safe.
. "$PSScriptRoot\registration\common\config\ConvertFrom-GitHubRunnersConfigJson.ps1"

# The minimum version is pinned here - bump it when a newer feature is required.
Invoke-ModuleInstall -ModuleName 'Infrastructure.Secrets' -MinimumVersion '2.1.0'

Initialize-MicrosoftPowerShellSecretStoreVault `
    -VaultName  'GitHubRunners' `
    -SecretName 'GitHubRunnersConfig' `
    @PSBoundParameters `
    -Validate {
        param($json)
        $entries = @(ConvertFrom-GitHubRunnersConfigJson -Json $json)
        Write-Host "[OK] JSON validated - $($entries.Count) runner entry/entries found." `
            -ForegroundColor Green
    }

Write-Host ""
Write-Host "Setup complete. Run register-runners.ps1 to register runners." `
    -ForegroundColor Cyan
