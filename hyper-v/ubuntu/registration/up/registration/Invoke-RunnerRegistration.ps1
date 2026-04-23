<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    register-runners.ps1 after Infrastructure.Common is loaded.
    Test-RunnerServiceActive.ps1 must also be dot-sourced before this
    function is called.
#>

# ---------------------------------------------------------------------------
# Invoke-RunnerRegistration
#   Registers a single runner on the remote VM and starts its service.
#
#   Steps performed over the existing SSH connection:
#     1. config.sh --unattended  - registers the runner with GitHub.
#        Skipped when -SkipConfig is set (runner already registered).
#     2. svc.sh install          - installs the systemd service.
#     3. svc.sh start            - starts the service.
#     4. Test-RunnerServiceActive - verifies the service is active.
#
#   -SkipConfig is used when the runner is already registered with GitHub
#   but the systemd unit was never installed - e.g. a previous run failed
#   between config.sh and svc.sh. Token is not required in this case.
#
#   All steps run from the runner directory. config.sh runs as RunnerUser
#   (via sudoers-permitted 'sudo -u') so the runner files remain owned by
#   the service user. svc.sh install and start require root (plain sudo).
#
#   Security: Token must never appear in console output or error messages.
#   Log only VmName and RunnerName in diagnostics.
# ---------------------------------------------------------------------------

function Invoke-RunnerRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName,

        [Parameter(Mandatory)]
        [string] $RunnerUser,

        [Parameter(Mandatory)]
        [object] $Entry,

        # Short-lived registration token from New-RunnerRegistrationToken.
        # Must not appear in any log output. Not required when -SkipConfig
        # is set.
        [Parameter()]
        [string] $Token = '',

        # Pre-computed by Get-RunnerPaths - caller owns path convention.
        [Parameter(Mandatory)]
        [string] $RunnerDir,

        # When set, skips config.sh. Used when the runner is already
        # registered with GitHub but the systemd unit is missing.
        [switch] $SkipConfig
    )

    if (-not $SkipConfig -and -not $Token) {
        throw "[$VmName] Token is required when -SkipConfig is not set."
    }

    $runnerName = $Entry.runnerName
    $labelsArg  = @($Entry.runnerLabels) -join ','

    if (-not $SkipConfig) {
        # config.sh registers the runner with GitHub. Token is intentionally
        # not included in any throw message or Write-* call below.
        $r = Invoke-SshClientCommand `
            -SshClient $SshClient `
            -Command   ("sudo -u $RunnerUser '$runnerDir/config.sh'" +
                        " --url '$($Entry.githubUrl)'" +
                        " --token '$Token'" +
                        " --name '$runnerName'" +
                        " --labels '$labelsArg'" +
                        " --unattended") `
            -ErrorAction Stop

        if ($r.ExitStatus -ne 0) {
            throw "[$VmName] config.sh failed for '$runnerName': $($r.Error)"
        }
    }

    # svc.sh resolves the runner root via $(pwd), so the working directory
    # must be the runner directory when it runs. 'cd' before sudo sets it.
    $r = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   "cd '$runnerDir' && sudo './svc.sh' install '$RunnerUser'" `
        -ErrorAction Stop

    if ($r.ExitStatus -ne 0) {
        throw "[$VmName] svc.sh install failed for '$runnerName': $($r.Error)"
    }

    $r = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   "cd '$runnerDir' && sudo './svc.sh' start" `
        -ErrorAction Stop

    if ($r.ExitStatus -ne 0) {
        throw "[$VmName] svc.sh start failed for '$runnerName': $($r.Error)"
    }

    # Verify the service reached active state. svc.sh start may exit 0 even
    # when the service fails immediately (ExecStart error), so an explicit
    # re-check is required.
    $isActive = Test-RunnerServiceActive `
        -SshClient  $SshClient `
        -VmName     $VmName `
        -RunnerName $runnerName

    if (-not $isActive) {
        Write-Error ("[$VmName] Runner '$runnerName': service is not active after " +
            "registration. Check: journalctl -u 'actions.runner.*'")
        return
    }

    Write-Host "[$VmName] Runner '$runnerName': registered and service started." `
        -ForegroundColor Green
}
