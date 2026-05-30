<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    register-runners.ps1 after PowerShell.Common is loaded.
#>

# ---------------------------------------------------------------------------
# Resolve-RunnerVersion
#   Queries the GitHub Releases API to find the latest actions/runner
#   release and returns the version string without the leading 'v' prefix
#   (e.g. '2.317.0').
#
#   The token is passed here to authenticate the request. Unauthenticated
#   requests hit a stricter rate limit (60/hour vs 5000/hour) - using the
#   token already held in memory avoids that limit without requiring an
#   additional credential. The token must never appear in console output
#   or error messages.
# ---------------------------------------------------------------------------

function Resolve-RunnerVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Token
    )

    $response = Invoke-GitHubApi `
        -Token    $Token `
        -Endpoint 'repos/actions/runner/releases/latest'

    # tag_name is formatted as 'v2.317.0'; strip the leading 'v' so the
    # version string can be used directly in filenames and directory paths.
    $version = $response.tag_name -replace '^v', ''

    Write-Host "Latest runner version: $version" -ForegroundColor Cyan

    $version
}
