<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    register-runners.ps1 and deregister-runners.ps1 after Infrastructure.Common
    is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-GitHubRunnersApi
#   Common wrapper for all GitHub Actions runners API calls. Handles URL
#   construction, authentication, and the User-Agent header in one place.
#
#   -Suffix is appended to the base runners URL:
#     - Path segment (e.g. 'registration-token') -> appended with '/'.
#     - Query string (e.g. '?per_page=100')       -> appended directly.
#   Omit -Suffix to address the runners collection endpoint.
#
#   Returns the raw Invoke-RestMethod response. Callers extract the fields
#   they need (.token, .runners, etc.) or ignore the body (DELETE).
#
#   The PAT is passed in the Authorization header, not the URL, so it does
#   not appear in server logs or error messages.
# ---------------------------------------------------------------------------

function Invoke-GitHubRunnersApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Pat,

        [Parameter(Mandatory)]
        [string] $GithubUrl,

        [Parameter()]
        [string] $Suffix = '',

        [Parameter()]
        [string] $Method = 'Get'
    )

    $parts = $GithubUrl.TrimEnd('/') -split '/'
    $owner = $parts[-2]
    $repo  = $parts[-1]

    $uri = "https://api.github.com/repos/$owner/$repo/actions/runners"
    if ($Suffix) {
        $uri += if ($Suffix[0] -eq '?') { $Suffix } else { "/$Suffix" }
    }

    Invoke-RestMethod `
        -Uri     $uri `
        -Method  $Method `
        -Headers @{
            'User-Agent'    = 'Infrastructure-GitHubRunners'
            'Authorization' = "Bearer $Pat"
        } `
        -ErrorAction Stop
}
