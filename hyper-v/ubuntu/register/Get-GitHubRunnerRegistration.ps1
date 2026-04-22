<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    register-runners.ps1 after Infrastructure.Common is loaded.
#>

# ---------------------------------------------------------------------------
# Get-GitHubRunnerRegistration
#   Queries the GitHub API for a runner registered under the given name on
#   the repo identified by GithubUrl. Returns the runner object if found,
#   or $null if the runner is not registered.
#
#   Owner and repo are parsed from GithubUrl so the caller does not need to
#   split them separately.
#
#   per_page=100 avoids the 30-item default page limit. Pagination beyond
#   100 runners per repo is not handled - it is unlikely in practice.
#
#   The PAT is passed in the Authorization header, not the URL, so it does
#   not appear in server logs or error messages.
# ---------------------------------------------------------------------------

function Get-GitHubRunnerRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Pat,

        [Parameter(Mandatory)]
        [string] $GithubUrl,

        [Parameter(Mandatory)]
        [string] $RunnerName
    )

    $parts = $GithubUrl.TrimEnd('/') -split '/'
    $owner = $parts[-2]
    $repo  = $parts[-1]

    $response = Invoke-RestMethod `
        -Uri     "https://api.github.com/repos/$owner/$repo/actions/runners?per_page=100" `
        -Headers @{
            'User-Agent'    = 'Infrastructure-GitHubRunners'
            'Authorization' = "Bearer $Pat"
        } `
        -ErrorAction Stop

    # Select-Object -ErrorAction SilentlyContinue guards against an absent
    # 'runners' property under Set-StrictMode -Version Latest, which would
    # otherwise throw PropertyNotFoundException.
    $response |
        Select-Object -ExpandProperty runners -ErrorAction SilentlyContinue |
        Where-Object { $_.name -eq $RunnerName } |
        Select-Object -First 1
}
