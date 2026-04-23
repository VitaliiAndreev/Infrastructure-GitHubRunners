<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    register-runners.ps1 after Infrastructure.Common is loaded.
#>

# ---------------------------------------------------------------------------
# Get-RunnerPaths
#   Single source of truth for remote filesystem path conventions.
#   All paths follow the layout created by useradd -m in
#   Infrastructure-Vm-Users: /home/{RunnerUser}/...
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
        [Parameter(Mandatory)]
        [string] $RunnerVersion,

        # Optional. Populate RunnerDir only when a specific runner is known.
        [string] $RunnerName = ''
    )

    $homeDir  = "/home/$RunnerUser"
    $cacheDir = "$homeDir/cache"
    $tarName  = "actions-runner-linux-x64-${RunnerVersion}.tar.gz"

    [PSCustomObject] @{
        CacheDir  = $cacheDir
        TarName   = $tarName
        TarPath   = "$cacheDir/$tarName"
        RunnerDir = if ($RunnerName) { "$homeDir/runners/$RunnerName" } else { $null }
    }
}
