<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    deregister-runners.ps1 after all helpers are loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-VmDeregisterGroup
#   Deregisters all runners on a single VM over an existing SSH connection.
#   Called once per reachable VM by deregister-runners.ps1. The caller owns
#   the reachable/unreachable split and always passes a live SshClient.
#
#   Sequence per runner entry:
#     1. Remove-RunnerService          - stop and uninstall systemd unit if present.
#     2. Get-GitHubRunnerRegistration  - determine GitHub registration state.
#     3. Invoke-RunnerConfigRemove     - deregister from GitHub (only if registered).
#     4. Remove-RunnerFiles            - delete runner directory (always).
#
#   The GitHub check (step 2) drives step 3 explicitly. Registration state is
#   never inferred from the filesystem - a directory may exist from a partial
#   install that never completed registration.
# ---------------------------------------------------------------------------

function Invoke-VmDeregisterGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName,

        # All reachable targets for this VM (Entry + Password pairs).
        [Parameter(Mandatory)]
        [object[]] $Targets,

        # GitHub PAT - used for API calls only, never logged.
        [Parameter(Mandatory)]
        [string] $Pat
    )

    foreach ($target in $Targets) {
        $entry     = $target.Entry
        $entryPaths = Get-RunnerPaths `
            -RunnerUser $entry.runnerUsername `
            -RunnerName $entry.runnerName

        Write-Host "[$VmName] Runner '$($entry.runnerName)': deregistering ..." `
            -ForegroundColor Cyan

        # Step 1: stop and uninstall the service. Always run regardless of
        # GitHub state - a partial install may have a service but no registration.
        Remove-RunnerService `
            -SshClient  $SshClient `
            -VmName     $VmName `
            -RunnerName $entry.runnerName `
            -RunnerDir  $entryPaths.RunnerDir

        # Step 2: check GitHub registration state.
        $registration = Get-GitHubRunnerRegistration `
            -Pat        $Pat `
            -GithubUrl  $entry.githubUrl `
            -RunnerName $entry.runnerName

        # Step 3: deregister from GitHub only when confirmed registered.
        if ($registration) {
            Invoke-RunnerConfigRemove `
                -SshClient  $SshClient `
                -VmName     $VmName `
                -RunnerUser $entry.runnerUsername `
                -Entry      $entry `
                -RunnerDir  $entryPaths.RunnerDir `
                -Pat        $Pat
        }

        # Step 4: remove runner directory. Always run to clean up any leftover
        # files from partial installs, regardless of GitHub state.
        Remove-RunnerFiles `
            -SshClient  $SshClient `
            -VmName     $VmName `
            -RunnerName $entry.runnerName `
            -RunnerDir  $entryPaths.RunnerDir

        Write-Host "[$VmName] Runner '$($entry.runnerName)': deregistered." `
            -ForegroundColor Green
    }
}
