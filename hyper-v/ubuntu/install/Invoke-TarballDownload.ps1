<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    register-runners.ps1 after Infrastructure.Common is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-TarballDownload
#   Ensures the correct actions/runner tarball is present in the runner
#   user's cache directory on the remote host.
#
#   If the expected tarball is already present, the function returns
#   immediately (idempotent). If absent, any stale actions-runner-*.tar.gz
#   files are purged first so the cache never accumulates old versions,
#   then the new tarball is downloaded via curl.
#
#   All operations run as $RunnerUser (via sudoers-permitted
#   'sudo -u $RunnerUser') so the service user owns the files.
#
#   Cache path convention: /home/{RunnerUser}/cache/
#     actions-runner-linux-x64-{RunnerVersion}.tar.gz
# ---------------------------------------------------------------------------

function Invoke-TarballDownload {
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
        [string] $RunnerVersion
    )

    $cacheDir = "/home/$RunnerUser/cache"
    $tarball  = "actions-runner-linux-x64-${RunnerVersion}.tar.gz"
    $tarPath  = "$cacheDir/$tarball"
    $tarUrl   = "https://github.com/actions/runner/releases/download/" +
                "v${RunnerVersion}/${tarball}"

    $r = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   "sudo -u $RunnerUser mkdir -p '$cacheDir'" `
        -ErrorAction Stop

    if ($r.ExitStatus -ne 0) {
        throw "[$VmName] Failed to create cache directory: $($r.Error)"
    }

    $check = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   "test -f '$tarPath'" `
        -ErrorAction Stop

    if ($check.ExitStatus -eq 0) {
        Write-Host "[$VmName] Tarball already cached: $tarball" -ForegroundColor Green
        return
    }

    Write-Host "[$VmName] Tarball not cached for v$RunnerVersion - downloading ..." `
        -ForegroundColor Cyan

    # Purge stale versions before downloading so the cache directory does
    # not accumulate old binaries.
    $purge = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   "sudo -u $RunnerUser rm -f '$cacheDir'/actions-runner-*.tar.gz" `
        -ErrorAction Stop

    if ($purge.ExitStatus -ne 0) {
        throw "[$VmName] Failed to purge stale tarballs: $($purge.Error)"
    }

    $dl = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   "sudo -u $RunnerUser curl -fsSL -o '$tarPath' '$tarUrl'" `
        -ErrorAction Stop

    if ($dl.ExitStatus -ne 0) {
        throw "[$VmName] curl download failed for v${RunnerVersion}: $($dl.Error)"
    }

    Write-Host "[$VmName] Tarball downloaded: $tarball" -ForegroundColor Green
}
