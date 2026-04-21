<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    register-runners.ps1 after Infrastructure.Common is loaded.
    Invoke-TarballDownload.ps1 and Invoke-RunnerExtract.ps1 must also be
    dot-sourced before this function is called.
#>

# ---------------------------------------------------------------------------
# Invoke-RunnerInstall
#   Orchestrates runner installation for all entries on a single VM.
#   Calls Invoke-TarballDownload once to ensure the shared binary is cached,
#   then Invoke-RunnerExtract for each runner entry.
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
        [string] $RunnerVersion
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

    $userPaths = Get-RunnerPaths -RunnerUser $runnerUser -RunnerVersion $RunnerVersion

    Invoke-TarballDownload `
        -SshClient     $SshClient `
        -VmName        $VmName `
        -RunnerUser    $runnerUser `
        -RunnerVersion $RunnerVersion `
        -CacheDir      $userPaths.CacheDir `
        -TarPath       $userPaths.TarPath

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
