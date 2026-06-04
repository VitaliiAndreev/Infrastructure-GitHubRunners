<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    register-runners.ps1 after PowerShell.Common, Infrastructure.Secrets,
    and ConvertFrom-GitHubRunnersConfigJson.ps1 are loaded.
#>

# ---------------------------------------------------------------------------
# Read-GitHubRunnersConfig
#   Reads and parses the GitHubRunnersConfig secret from the GitHubRunners
#   vault. Returns an array of validated runner entry objects.
# ---------------------------------------------------------------------------

function Read-GitHubRunnersConfig {
    [CmdletBinding()]
    param(
        # Required. The secret read is `GitHubRunnersConfig-<Suffix>`.
        # See provision.ps1 in Infrastructure-Vm-Provisioner for the
        # suffix contract.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SecretSuffix
    )

    $secretName = "GitHubRunnersConfig-$SecretSuffix"

    Write-Host "Reading $secretName from GitHubRunners vault ..." `
        -ForegroundColor Cyan

    $json    = Get-InfrastructureSecret `
                   -VaultName  'GitHubRunners' `
                   -SecretName $secretName
    $entries = ConvertTo-Array (ConvertFrom-GitHubRunnersConfigJson -Json $json)

    Write-Host "OK - $($entries.Count) runner entry/entries in $secretName." `
        -ForegroundColor Green
    ConvertTo-Array $entries
}
