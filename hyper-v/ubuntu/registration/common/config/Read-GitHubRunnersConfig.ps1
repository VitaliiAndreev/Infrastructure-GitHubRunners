<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    register-runners.ps1 after Infrastructure.Common, Infrastructure.Secrets,
    and ConvertFrom-GitHubRunnersConfigJson.ps1 are loaded.
#>

# ---------------------------------------------------------------------------
# Read-GitHubRunnersConfig
#   Reads and parses the GitHubRunnersConfig secret from the GitHubRunners
#   vault. Returns an array of validated runner entry objects.
# ---------------------------------------------------------------------------

function Read-GitHubRunnersConfig {
    [CmdletBinding()]
    param()

    Write-Host "Reading GitHubRunnersConfig from GitHubRunners vault ..." `
        -ForegroundColor Cyan

    $json    = Get-InfrastructureSecret `
                   -VaultName  'GitHubRunners' `
                   -SecretName 'GitHubRunnersConfig'
    $entries = @(ConvertFrom-GitHubRunnersConfigJson -Json $json)

    Write-Host "OK - $($entries.Count) runner entry/entries in GitHubRunnersConfig." `
        -ForegroundColor Green
    $entries
}
