<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    register-runners.ps1 after Infrastructure.Common is loaded.
#>

# ---------------------------------------------------------------------------
# New-RunnerRegistrationToken
#   Fetches a short-lived registration token from the GitHub API (1hr expiry).
#   The token is used by config.sh to register a new runner.
#
#   The token must never appear in console output, error messages, or logs.
#   Callers are responsible for treating the return value as a secret.
# ---------------------------------------------------------------------------

function New-RunnerRegistrationToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Pat,

        [Parameter(Mandatory)]
        [string] $GithubUrl
    )

    $parts = $GithubUrl.TrimEnd('/') -split '/'
    $owner = $parts[-2]
    $repo  = $parts[-1]

    $response = Invoke-RestMethod `
        -Uri     "https://api.github.com/repos/$owner/$repo/actions/runners/registration-token" `
        -Method  Post `
        -Headers @{
            'User-Agent'    = 'Infrastructure-GitHubRunners'
            'Authorization' = "Bearer $Pat"
        } `
        -ErrorAction Stop

    $response.token
}
