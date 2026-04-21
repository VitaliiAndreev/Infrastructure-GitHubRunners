<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    register-runners.ps1 after Infrastructure.Common is loaded.
    Get-RunnerServiceName.ps1 must also be dot-sourced before this function
    is called.
#>

# ---------------------------------------------------------------------------
# Start-RunnerService
#   Starts the runner's systemd service and verifies it is active afterward.
#   Writes a prominent Write-Error if the service is not active after the
#   start attempt - never swallows the failure silently.
#
#   Used when a runner is registered on GitHub but its service is down.
# ---------------------------------------------------------------------------

function Start-RunnerService {
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

    if (-not $serviceName) {
        Write-Error ("[$VmName] Runner '$RunnerName': service unit not found - " +
            "cannot start. Re-run register-runners.ps1 to re-register.")
        return
    }

    $r = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   "sudo systemctl start '$serviceName'" `
        -ErrorAction Stop

    if ($r.ExitStatus -ne 0) {
        Write-Error ("[$VmName] Runner '$RunnerName': systemctl start failed: $($r.Error)")
        return
    }

    # Re-check: the service may still fail to reach active state even when
    # systemctl start exits 0 (e.g. ExecStart fails immediately).
    $recheck = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   "systemctl is-active '$serviceName'" `
        -ErrorAction Stop

    if (($recheck.Output -join '').Trim() -ne 'active') {
        Write-Error ("[$VmName] Runner '$RunnerName': service is not active after start. " +
            "Check: journalctl -u '$serviceName'")
        return
    }

    Write-Host "[$VmName] Runner '$RunnerName': service restarted." -ForegroundColor Green
}
