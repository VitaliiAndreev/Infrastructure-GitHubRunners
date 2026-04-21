<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    register-runners.ps1 after Infrastructure.Common is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-RunnerExtract
#   Ensures a single runner's directory exists and contains the extracted
#   binary. Skips extraction if the directory is already present (idempotent).
#
#   Extract path convention: /home/{RunnerUser}/runners/{RunnerName}/
#   Tarball path convention: /home/{RunnerUser}/cache/
#     actions-runner-linux-x64-{RunnerVersion}.tar.gz
#
#   mkdir -p on the full runner path creates the runners/ parent implicitly,
#   so no separate step is needed to ensure the parent directory exists.
#
#   All operations run as $RunnerUser (via sudoers-permitted
#   'sudo -u $RunnerUser') so the service user owns the files.
# ---------------------------------------------------------------------------

function Invoke-RunnerExtract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName,

        [Parameter(Mandatory)]
        [string] $RunnerUser,

        # Version string without leading 'v', e.g. '2.317.0'.
        [Parameter(Mandatory)]
        [string] $RunnerVersion,

        [Parameter(Mandatory)]
        [string] $RunnerName
    )

    $tarPath   = "/home/$RunnerUser/cache/" +
                 "actions-runner-linux-x64-${RunnerVersion}.tar.gz"
    $runnerDir = "/home/$RunnerUser/runners/$RunnerName"

    $check = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   "test -d '$runnerDir'" `
        -ErrorAction Stop

    if ($check.ExitStatus -eq 0) {
        Write-Host "[$VmName] Runner '$RunnerName': already extracted - skipping." `
            -ForegroundColor Green
        return
    }

    # mkdir -p creates /home/$RunnerUser/runners/ implicitly.
    $mkdir = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   "sudo -u $RunnerUser mkdir -p '$runnerDir'" `
        -ErrorAction Stop

    if ($mkdir.ExitStatus -ne 0) {
        throw "[$VmName] Failed to create runner directory '$runnerDir': $($mkdir.Error)"
    }

    $extract = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   "sudo -u $RunnerUser tar -xzf '$tarPath' -C '$runnerDir'" `
        -ErrorAction Stop

    if ($extract.ExitStatus -ne 0) {
        throw "[$VmName] tar extraction failed for '$RunnerName': $($extract.Error)"
    }

    Write-Host "[$VmName] Runner '$RunnerName': extracted v$RunnerVersion." `
        -ForegroundColor Green
}
