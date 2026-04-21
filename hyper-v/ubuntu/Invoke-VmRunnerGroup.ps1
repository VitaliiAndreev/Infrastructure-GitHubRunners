<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    register-runners.ps1 after all install/ and register/ helpers are loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-VmRunnerGroup
#   Installs and reconciles all runners on a single VM over an existing SSH
#   connection. Called once per VM by register-runners.ps1.
#
#   Targets is an array of objects from Join-RunnerDeployCredentials, each
#   carrying an Entry (runner config) and a Password (deploy credential).
#   They are pre-filtered to a single VM by the caller.
#
#   Reconciliation per runner:
#     - Registered + service active  -> skip (healthy)
#     - Registered + service down    -> restart service only
#     - Not registered               -> full install, register, start
# ---------------------------------------------------------------------------

function Invoke-VmRunnerGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName,

        # All reachable targets for this VM (Entry + Password pairs).
        [Parameter(Mandatory)]
        [object[]] $Targets,

        # Version string without leading 'v', e.g. '2.317.0'.
        [Parameter(Mandatory)]
        [string] $RunnerVersion,

        # GitHub PAT - used for registration API calls only, never logged.
        [Parameter(Mandatory)]
        [string] $Pat
    )

    # Group by runner service user so each user's tarball cache and runner
    # directories are managed together. Multiple users on one VM are valid
    # (e.g. separate service accounts per security boundary).
    $userGroups = $Targets | Group-Object { $_.Entry.runnerUsername }

    foreach ($userGroup in $userGroups) {
        $runnerUser = $userGroup.Name

        Invoke-RunnerInstall `
            -SshClient     $SshClient `
            -VmName        $VmName `
            -RunnerEntries @($userGroup.Group | ForEach-Object { $_.Entry }) `
            -RunnerVersion $RunnerVersion

        foreach ($target in $userGroup.Group) {
            $entry      = $target.Entry
            $entryPaths = Get-RunnerPaths `
                -RunnerUser    $runnerUser `
                -RunnerVersion $RunnerVersion `
                -RunnerName    $entry.runnerName

            $registration = Get-GitHubRunnerRegistration `
                -Pat        $Pat `
                -GithubUrl  $entry.githubUrl `
                -RunnerName $entry.runnerName

            $serviceActive = Test-RunnerServiceActive `
                -SshClient  $SshClient `
                -VmName     $VmName `
                -RunnerName $entry.runnerName

            if ($registration -and $serviceActive) {
                Write-Host "[$VmName] Runner '$($entry.runnerName)': healthy - skipping." `
                    -ForegroundColor Green
            }
            elseif ($registration -and -not $serviceActive) {
                Start-RunnerService `
                    -SshClient  $SshClient `
                    -VmName     $VmName `
                    -RunnerName $entry.runnerName
            }
            else {
                # Token expires in 1hr - fetch immediately before use.
                $token = New-RunnerRegistrationToken `
                    -Pat       $Pat `
                    -GithubUrl $entry.githubUrl

                Invoke-RunnerRegistration `
                    -SshClient  $SshClient `
                    -VmName     $VmName `
                    -RunnerUser $runnerUser `
                    -Entry      $entry `
                    -Token      $token `
                    -RunnerDir  $entryPaths.RunnerDir
            }
        }
    }
}
