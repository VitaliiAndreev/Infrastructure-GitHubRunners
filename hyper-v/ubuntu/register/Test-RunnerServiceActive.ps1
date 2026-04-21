<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    register-runners.ps1 after Infrastructure.Common is loaded.
    Get-RunnerServiceName.ps1 must also be dot-sourced before this function
    is called.
#>

# ---------------------------------------------------------------------------
# Test-RunnerServiceActive
#   Returns $true if the runner's systemd service is active, $false otherwise.
#   Returns $false when the service unit is not installed (runner not yet
#   registered) - the caller treats this as "service down".
# ---------------------------------------------------------------------------

function Test-RunnerServiceActive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName,

        [Parameter(Mandatory)]
        [string] $RunnerName
    )

    $serviceName = Get-RunnerServiceName -SshClient $SshClient -RunnerName $RunnerName
    if (-not $serviceName) { return $false }

    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   "systemctl is-active '$serviceName'" `
        -ErrorAction Stop

    ($result.Output -join '').Trim() -eq 'active'
}
