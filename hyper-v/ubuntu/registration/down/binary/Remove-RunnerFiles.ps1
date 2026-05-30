<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    deregister-runners.ps1 after PowerShell.Common is loaded.
#>

# ---------------------------------------------------------------------------
# Remove-RunnerFiles
#   Deletes the runner directory on the remote VM if it exists. Always called
#   on reachable VMs regardless of GitHub registration state - this is the
#   leftover cleanup guarantee that ensures the next registration starts from
#   a clean slate (partial installs leave directories that block re-use of
#   the same runner name).
#
#   An already-absent directory is silently skipped and is not an error.
# ---------------------------------------------------------------------------

function Remove-RunnerFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName,

        [Parameter(Mandatory)]
        [string] $RunnerName,

        # Pre-computed by Get-RunnerPaths - caller owns path convention.
        [Parameter(Mandatory)]
        [string] $RunnerDir
    )

    # Two-stage: probe for presence first so an absent directory is a no-op
    # (idempotency guarantee). The earlier inline '|| true' form swallowed
    # the rm's exit status and would silently leave the directory behind
    # whenever sudoers was misconfigured - the failure must surface so
    # operators can repair the sudoers grants.
    $probe = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   "test -d '$RunnerDir'" `
        -ErrorAction Stop

    if ($probe.ExitStatus -ne 0) {
        return
    }

    $r = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   "sudo rm -rf '$RunnerDir'" `
        -ErrorAction Stop

    if ($r.ExitStatus -ne 0) {
        throw "[$VmName] Failed to remove runner directory for '$RunnerName': $($r.Error)"
    }
}
