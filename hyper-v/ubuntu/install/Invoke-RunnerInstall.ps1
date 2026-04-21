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

    # All entries are for the same VM so runnerUsername is the same for all.
    # Home directory is derived by convention (/home/{username}) - the same
    # convention used by useradd -m in Infrastructure-Vm-Users.
    $runnerUser = $RunnerEntries[0].runnerUsername

    Invoke-TarballDownload `
        -SshClient     $SshClient `
        -VmName        $VmName `
        -RunnerUser    $runnerUser `
        -RunnerVersion $RunnerVersion

    foreach ($entry in $RunnerEntries) {
        Invoke-RunnerExtract `
            -SshClient     $SshClient `
            -VmName        $VmName `
            -RunnerUser    $runnerUser `
            -RunnerVersion $RunnerVersion `
            -RunnerName    $entry.runnerName
    }
}
