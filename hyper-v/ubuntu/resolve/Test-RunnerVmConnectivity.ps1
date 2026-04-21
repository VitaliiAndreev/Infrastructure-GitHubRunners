<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    register-runners.ps1 after Infrastructure.Common is loaded.
#>

# ---------------------------------------------------------------------------
# Test-RunnerVmConnectivity
#   Pings each target VM. Returns a list containing only the reachable ones.
#   Unreachable VMs are warned and skipped rather than aborting the run, so
#   a single offline VM does not block all others.
# ---------------------------------------------------------------------------

function Test-RunnerVmConnectivity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Targets
    )

    $reachable = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($t in $Targets) {
        $name = $t.Entry.runnerName
        $ip   = $t.Entry.ipAddress

        Write-Host "[$name] Pinging ..." -ForegroundColor Cyan

        if (Test-Connection -ComputerName $ip -Count 1 -Quiet) {
            Write-Host "[$name] Reachable." -ForegroundColor Green
            $reachable.Add($t)
        }
        else {
            Write-Warning "[$name] Unreachable - skipping."
        }
    }

    Write-Host ("$($reachable.Count) of $($Targets.Count) runner " +
        "target(s) reachable.") -ForegroundColor Cyan
    $reachable.ToArray()
}
