<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    register-runners.ps1 after PowerShell.Common is loaded.
#>

# ---------------------------------------------------------------------------
# Get-RunnerPaths
#   Single source of truth for remote filesystem path conventions.
#
#   RunnerDir lives under /opt/runners/ rather than the runner user's home
#   directory so that the deploy user can cd into it without needing execute
#   permission on the home directory (which is 700 by default on Ubuntu).
#
#   CacheDir remains under the runner user's home because it holds downloaded
#   tarballs that no other user needs to access.
#
#   Callers pass the returned paths down to leaf SSH functions so that
#   no leaf function re-derives path structure from user/name inputs.
# ---------------------------------------------------------------------------

function Get-RunnerPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RunnerUser,

        # Version string without leading 'v', e.g. '2.317.0'.
        # Optional - omit when only RunnerDir is needed (e.g. deregistration).
        # TarName and TarPath are $null when version is not provided.
        [string] $RunnerVersion = '',

        # Optional. Populate RunnerDir only when a specific runner is known.
        [string] $RunnerName = ''
    )

    $homeDir  = "/home/$RunnerUser"
    $cacheDir = "$homeDir/cache"
    $tarName  = if ($RunnerVersion) { "actions-runner-linux-x64-${RunnerVersion}.tar.gz" } else { $null }

    [PSCustomObject] @{
        CacheDir  = $cacheDir
        TarName   = $tarName
        TarPath   = if ($tarName) { "$cacheDir/$tarName" } else { $null }
        RunnerDir = if ($RunnerName) { "/opt/runners/$RunnerName" } else { $null }
    }
}
