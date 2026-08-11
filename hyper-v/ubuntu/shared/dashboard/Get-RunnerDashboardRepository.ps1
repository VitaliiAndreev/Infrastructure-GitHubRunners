<#
.NOTES
    Do not run this file directly. It is dot-sourced by runner-dashboard.ps1.
#>

# ---------------------------------------------------------------------------
# Get-RunnerDashboardRepository
#   Reduces the runner entries from the GitHubRunnersConfig vault to the
#   distinct 'owner/repo' slugs the dashboard has to poll.
#
#   The vault is keyed by RUNNER, and several runners routinely share a
#   repository - polling per entry would multiply every API call by the number
#   of runners on that repo for no extra information. Collapsing to distinct
#   repositories here is what keeps the per-tick call count proportional to
#   repositories rather than to fleet size.
#
#   Deriving the list from the vault rather than a literal keeps the single
#   source of truth where it already is: add a runner on a new repo via
#   setup-secrets and the dashboard follows with no code change.
# ---------------------------------------------------------------------------

function Get-RunnerDashboardRepository {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        # Validated runner entries as returned by Read-GitHubRunnersConfig.
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $RunnerEntry
    )

    # Owner and repository are always the first two path segments of the
    # githubUrl; anything after them (a trailing .git, a deep link) is noise.
    $ownerSegmentIndex = 0
    $repoSegmentIndex  = 1
    $requiredSegments  = 2

    $slugs = [System.Collections.Generic.List[string]]::new()
    $seen  = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($entry in $RunnerEntry) {
        $runnerName = $entry.runnerName
        $url        = $entry.githubUrl

        if ([string]::IsNullOrWhiteSpace($url)) {
            throw "Runner entry '$runnerName': githubUrl is empty."
        }

        try {
            $path = ([Uri] $url).AbsolutePath.Trim('/')
        }
        catch [System.Management.Automation.PSInvalidCastException] {
            throw "Runner entry '$runnerName': githubUrl '$url' is not a valid URL."
        }

        $path     = $path -replace '\.git$', ''
        $segments = @($path -split '/' | Where-Object { $_ })

        # A bad slug would surface downstream as a confusing 404 per tick, so
        # reject it here where the message can name the offending entry.
        if ($segments.Count -lt $requiredSegments) {
            throw "Runner entry '$runnerName': githubUrl '$url' is not an owner/repo URL."
        }

        $slug = "$($segments[$ownerSegmentIndex])/$($segments[$repoSegmentIndex])"
        if ($seen.Add($slug)) { $slugs.Add($slug) }
    }

    # Comma operator preserves the array shape through the pipeline, including
    # the empty and single-element cases the caller has to handle uniformly.
    , $slugs.ToArray()
}
