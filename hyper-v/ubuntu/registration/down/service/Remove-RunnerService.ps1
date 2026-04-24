<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    deregister-runners.ps1 after Infrastructure.Common is loaded.
    Get-RunnerServiceName.ps1 and Test-RunnerServiceActive.ps1 must also be
    dot-sourced before this function is called.
#>

# ---------------------------------------------------------------------------
# Remove-RunnerService
#   Stops the runner's systemd service and uninstalls its unit file over an
#   existing SSH connection. Each step is independently guarded so the
#   function is safe to call in any partial-cleanup state:
#
#   1. Stop: if the service is active, issue 'sudo systemctl stop'. A service
#      that is already stopped or absent is silently skipped.
#   2. Uninstall: if a unit file is installed, run 'svc.sh uninstall' from
#      the runner directory. An absent unit is silently skipped.
#
#   svc.sh resolves the runner root via $(pwd), so the working directory must
#   be RunnerDir when it runs - same constraint as svc.sh install.
# ---------------------------------------------------------------------------

function Remove-RunnerService {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName,

        [Parameter(Mandatory)]
        [string] $RunnerName,

        # Pre-computed by Get-RunnerPaths - used as the working directory for
        # svc.sh uninstall.
        [Parameter(Mandatory)]
        [string] $RunnerDir
    )

    # Step 1: stop the service if it is currently active.
    $isActive = Test-RunnerServiceActive `
        -SshClient  $SshClient `
        -VmName     $VmName `
        -RunnerName $RunnerName

    if ($isActive) {
        $serviceName = Get-RunnerServiceName -SshClient $SshClient -RunnerName $RunnerName

        $r = Invoke-SshClientCommand `
            -SshClient $SshClient `
            -Command   "sudo systemctl stop '$serviceName'" `
            -ErrorAction Stop

        if ($r.ExitStatus -ne 0) {
            throw "[$VmName] systemctl stop failed for '$RunnerName': $($r.Error)"
        }
    }

    # Step 2: uninstall the unit file if it is installed. Independent of
    # whether the service was active - a stopped unit still needs removal.
    $serviceName = Get-RunnerServiceName -SshClient $SshClient -RunnerName $RunnerName

    if ($serviceName) {
        $r = Invoke-SshClientCommand `
            -SshClient $SshClient `
            -Command   "cd '$RunnerDir' && sudo './svc.sh' uninstall" `
            -ErrorAction Stop

        if ($r.ExitStatus -ne 0) {
            throw "[$VmName] svc.sh uninstall failed for '$RunnerName': $($r.Error)"
        }
    }
}
