<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    deregister-runners.ps1 after Common.PowerShell is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-RunnerConfigRemove
#   Deregisters a single runner from GitHub and removes its local credential
#   files (.runner, .credentials) by running config.sh remove over an
#   existing SSH connection.
#
#   Steps performed:
#     1. Fetch a short-lived removal token via Invoke-GitHubApi.
#     2. Run config.sh remove --unattended as RunnerUser from the runner
#        directory. config.sh runs as RunnerUser (via sudoers-permitted
#        'sudo -u') so credential files owned by the service user are
#        accessible.
#
#   Only call this when the runner is confirmed present on GitHub.
#   Invoke-VmDeregisterGroup owns that decision via Get-GitHubRunnerRegistration
#   so this function does not need to re-check.
#
#   Security: the removal token must never appear in console output or error
#   messages. Log only VmName and RunnerName in diagnostics.
# ---------------------------------------------------------------------------

function Invoke-RunnerConfigRemove {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName,

        [Parameter(Mandatory)]
        [string] $RunnerUser,

        [Parameter(Mandatory)]
        [object] $Entry,

        # Pre-computed by Get-RunnerPaths - caller owns path convention.
        [Parameter(Mandatory)]
        [string] $RunnerDir,

        # GitHub token - used to fetch the removal token only, never logged.
        [Parameter(Mandatory)]
        [string] $Token
    )

    $runnerName = $Entry.runnerName
    $parts      = $Entry.githubUrl.TrimEnd('/') -split '/'
    $owner      = $parts[-2]
    $repo       = $parts[-1]

    # Removal token expires in 1hr - fetch immediately before use.
    $removeToken = (Invoke-GitHubApi `
        -Token    $Token `
        -Endpoint "repos/$owner/$repo/actions/runners/remove-token" `
        -Method   'Post').token

    # config.sh remove deregisters the runner from GitHub and deletes local
    # credential files. Token is intentionally not included in any throw
    # message or Write-* call below.
    $r = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   ("sudo -u $RunnerUser '$RunnerDir/config.sh'" +
                    " remove" +
                    " --token '$removeToken'" +
                    " --unattended") `
        -ErrorAction Stop

    if ($r.ExitStatus -ne 0) {
        throw "[$VmName] config.sh remove failed for '$runnerName': $($r.Error)"
    }
}
