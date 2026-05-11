<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    register-runners.ps1 after Infrastructure.Common is loaded.
#>

# ---------------------------------------------------------------------------
# Test-RunnerVmConnectivity
#   Probes SSH on each target VM via Test-VmSshPort (Infrastructure.HyperV)
#   and returns a list of the reachable ones. Unreachable VMs are warned
#   and skipped rather than aborting the run, so a single offline VM does
#   not block all others.
#
#   Test-VmSshPort is preferred over Test-Connection because we follow this
#   check with an SSH session - a successful TCP-22 connect is a strict
#   superset of an ICMP "host up" reply and eliminates the post-reboot race
#   where ICMP succeeds before sshd binds.
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

        Write-Host "[$name] Probing SSH ..." -ForegroundColor Cyan

        if (Test-VmSshPort -IpAddress $ip) {
            Write-Host "[$name] SSH reachable." -ForegroundColor Green
            $reachable.Add($t)
        }
        else {
            Write-Warning "[$name] SSH unreachable - skipping."
        }
    }

    Write-Host ("$($reachable.Count) of $($Targets.Count) runner " +
        "target(s) reachable.") -ForegroundColor Cyan
    return , $reachable.ToArray()
}
