<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    deregister-runners.ps1 after Infrastructure.Common is loaded.
#>

# ---------------------------------------------------------------------------
# Remove-GitHubRunner
#   Deletes a runner registration from GitHub via the REST API. Used in
#   force mode when the VM is unreachable and config.sh remove cannot run.
#
#   404 is treated as success - the runner is already gone, which is the
#   desired end state. This makes the function safe to call regardless of
#   prior partial runs (idempotency).
#
#   RunnerId is the numeric GitHub runner ID returned by
#   Get-GitHubRunnerRegistration. GithubUrl is used to derive the owner
#   and repo for the API endpoint.
# ---------------------------------------------------------------------------

function Remove-GitHubRunner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Pat,

        [Parameter(Mandatory)]
        [string] $GithubUrl,

        [Parameter(Mandatory)]
        [int] $RunnerId
    )

    try {
        Invoke-GitHubRunnersApi `
            -Pat       $Pat `
            -GithubUrl $GithubUrl `
            -Suffix    $RunnerId `
            -Method    'Delete'
    }
    catch {
        # 404 means the runner is already gone - treat as success.
        # Cast to int to handle both System.Net.HttpStatusCode enum (real
        # HTTP responses) and plain integer values (test mocks).
        if ([int]$_.Exception.Response.StatusCode -ne 404) {
            throw
        }
    }
}
