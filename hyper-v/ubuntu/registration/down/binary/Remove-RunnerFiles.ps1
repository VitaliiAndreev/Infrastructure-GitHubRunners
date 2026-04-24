<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    deregister-runners.ps1 after Infrastructure.Common is loaded.
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

    $r = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   "test -d '$RunnerDir' && sudo rm -rf '$RunnerDir' || true" `
        -ErrorAction Stop

    if ($r.ExitStatus -ne 0) {
        throw "[$VmName] Failed to remove runner directory for '$RunnerName': $($r.Error)"
    }
}
