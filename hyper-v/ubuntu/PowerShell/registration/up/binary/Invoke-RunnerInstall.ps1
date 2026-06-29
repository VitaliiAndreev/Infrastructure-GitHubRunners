<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    register-runners.ps1 after Common.PowerShell and Infrastructure.GitHub
    are loaded. Invoke-RunnerExtract.ps1 must also be dot-sourced before this
    function is called.
#>

# ---------------------------------------------------------------------------
# Invoke-RunnerInstall
#   Orchestrates runner installation for all entries on a single VM.
#   Ensures the shared binary is cached on the VM (idempotent via
#   Invoke-RunnerTarballDeploy), then extracts it for each runner entry.
#
#   All runner entries are expected to belong to the same VM and share the
#   same runnerUsername - the service user that owns the runner files.
# ---------------------------------------------------------------------------

function Invoke-RunnerInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName,

        # All runner entries for this VM (may be more than one).
        [Parameter(Mandatory)]
        [object[]] $RunnerEntries,

        # Version string without leading 'v', e.g. '2.317.0'.
        [Parameter(Mandatory)]
        [string] $RunnerVersion,

        # Base URL of the host file server (e.g. 'http://10.10.0.1:8745').
        # When provided the tarball is fetched from the Windows host instead
        # of GitHub, bypassing the Hyper-V NAT bottleneck. Falls back to the
        # GitHub URL when empty (backward-compatible default).
        [Parameter()]
        [string] $HostBaseUrl = ''
    )

    # Guard: caller is expected to pass entries pre-grouped by runnerUsername
    # (register-runners.ps1 groups by vmName then by runnerUsername before
    # calling this function). Mixed users here would install files under the
    # wrong home directory, so fail fast rather than silently misattribute.
    $distinctUsers = @($RunnerEntries | Select-Object -ExpandProperty runnerUsername -Unique)
    if ($distinctUsers.Count -gt 1) {
        throw ("[$VmName] All runner entries on a VM must share the same " +
            "runnerUsername. Found: $($distinctUsers -join ', ')")
    }
    $runnerUser = $distinctUsers[0]

    $tarball = "actions-runner-linux-x64-${RunnerVersion}.tar.gz"
    $tarUrl  = if ($HostBaseUrl) {
        "${HostBaseUrl}/${tarball}"
    } else {
        "https://github.com/actions/runner/releases/download/v${RunnerVersion}/${tarball}"
    }

    Invoke-RunnerTarballDeploy `
        -SshClient  $SshClient `
        -TarUrl     $tarUrl `
        -RunnerUser $runnerUser `
        -Label      $VmName

    foreach ($entry in $RunnerEntries) {
        $entryPaths = Get-RunnerPaths `
            -RunnerUser    $runnerUser `
            -RunnerVersion $RunnerVersion `
            -RunnerName    $entry.runnerName

        Invoke-RunnerExtract `
            -SshClient     $SshClient `
            -VmName        $VmName `
            -RunnerUser    $runnerUser `
            -RunnerVersion $RunnerVersion `
            -RunnerName    $entry.runnerName `
            -RunnerDir     $entryPaths.RunnerDir `
            -TarPath       $entryPaths.TarPath
    }
}
