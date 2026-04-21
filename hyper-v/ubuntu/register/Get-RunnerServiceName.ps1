<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    register-runners.ps1 after Infrastructure.Common is loaded.
#>

# ---------------------------------------------------------------------------
# Get-RunnerServiceName
#   Finds the systemd service unit name for a runner on the remote host.
#   Returns the unit name (e.g. 'actions.runner.owner-repo.runner-a.service')
#   or $null if no matching unit file is installed.
#
#   svc.sh names the service 'actions.runner.{owner}-{repo}.{runnerName}.service'.
#   Matching on '.$RunnerName.' as a dot-delimited field avoids partial
#   matches when one runner name is a prefix of another.
# ---------------------------------------------------------------------------

function Get-RunnerServiceName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $RunnerName
    )

    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   "systemctl list-unit-files --no-legend --type=service 'actions.runner.*' | grep -F '.$RunnerName.'" `
        -ErrorAction Stop

    $line = ($result.Output -join '').Trim()
    if (-not $line) { return $null }

    # Output format: '{unit-name} {state}'; return just the unit name.
    ($line -split '\s+')[0]
}
