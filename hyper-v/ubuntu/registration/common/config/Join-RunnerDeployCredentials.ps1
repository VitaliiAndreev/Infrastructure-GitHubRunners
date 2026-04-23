<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    register-runners.ps1 after Infrastructure.Common is loaded.
#>

# ---------------------------------------------------------------------------
# Join-RunnerDeployCredentials
#   Joins runner entries (from GitHubRunnersConfig) to deploy passwords
#   (from VmUsersConfig) by vmName + deployUsername.
#
#   Returns a list of hashtables, each pairing an Entry with its Password.
#   Entries with no matching password are warned and skipped - they likely
#   reference a user not yet added by Infrastructure-Vm-Users.
# ---------------------------------------------------------------------------

function Join-RunnerDeployCredentials {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [array] $RunnerEntries,
        [Parameter(Mandatory)] [hashtable] $DeployPasswords
    )

    $result = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($entry in $RunnerEntries) {
        $key = "$($entry.vmName)|$($entry.deployUsername)"

        if (-not $DeployPasswords.ContainsKey($key)) {
            Write-Warning ("[$($entry.runnerName)] No deploy password for " +
                "'$($entry.deployUsername)' on '$($entry.vmName)' in VmUsers " +
                "vault - skipping.")
            continue
        }

        $result.Add(@{
            Entry    = $entry
            # Plain string - see Read-VmDeployPasswords.ps1 for rationale.
            Password = $DeployPasswords[$key]
        })
    }

    Write-Host ("Matched $($result.Count) of $($RunnerEntries.Count) " +
        "runner entry/entries to deploy credentials.") -ForegroundColor Cyan
    $result.ToArray()
}
