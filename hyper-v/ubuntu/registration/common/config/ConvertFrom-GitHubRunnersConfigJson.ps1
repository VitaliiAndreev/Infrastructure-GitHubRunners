<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    setup-secrets.ps1 and register-runners.ps1 after PowerShell.Common
    is loaded.
#>

# ---------------------------------------------------------------------------
# ConvertFrom-GitHubRunnersConfigJson
#   Parses a GitHubRunnersConfig JSON string and validates its structure.
#   Throws a descriptive error on any problem.
#
#   Outputs each validated runner entry object to the pipeline. Callers must
#   use ConvertTo-Array to collect the result as an array:
#       $entries = ConvertTo-Array (ConvertFrom-GitHubRunnersConfigJson -Json $json)
#
#   Centralised here so the required-field list has a single source of
#   truth - update it once when the config schema changes.
# ---------------------------------------------------------------------------

function ConvertFrom-GitHubRunnersConfigJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Json
    )

    try {
        $parsed = $Json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Invalid JSON: $_"
    }

    $entries = ConvertTo-Array $parsed

    if ($entries.Count -eq 0) {
        throw "Config must be a non-empty JSON array of runner entries."
    }

    foreach ($entry in $entries) {
        Assert-RequiredProperties `
            -Object     $entry `
            -Properties @('vmName', 'ipAddress', 'deployUsername',
                          'runnerUsername', 'githubUrl', 'runnerName',
                          'runnerLabels') `
            -Context    "Runner entry"

        $labels = ConvertTo-Array $entry.runnerLabels
        if ($labels.Count -eq 0) {
            throw "Runner entry '$($entry.runnerName)': runnerLabels must not be empty."
        }

        Write-Output $entry
    }
}
