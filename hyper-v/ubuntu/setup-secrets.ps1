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

# Install / import every required PowerShell module via the centralised
# helper. Owns NuGet provider, Infrastructure.Common, Infrastructure.Secrets,
# and the rest of this repo's deps in one place.
. "$PSScriptRoot\Install-ModuleDependencies.ps1"

# ConvertFrom-GitHubRunnersConfigJson.ps1 is dot-sourced after the modules
# are loaded. It only calls Assert-RequiredProperties inside function
# bodies, not at load time, so this ordering is safe.
. "$PSScriptRoot\registration\common\config\ConvertFrom-GitHubRunnersConfigJson.ps1"

Initialize-MicrosoftPowerShellSecretStoreVault `
    -VaultName  'GitHubRunners' `
    -SecretName 'GitHubRunnersConfig' `
    @PSBoundParameters `
    -Validate {
        param($json)
        $entries = ConvertTo-Array (ConvertFrom-GitHubRunnersConfigJson -Json $json)
        Write-Host "[OK] JSON validated - $($entries.Count) runner entry/entries found." `
            -ForegroundColor Green
    }

Write-Host ""
Write-Host "Setup complete. Run register-runners.ps1 to register runners." `
    -ForegroundColor Cyan
