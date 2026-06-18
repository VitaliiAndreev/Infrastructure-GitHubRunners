<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    register-runners.ps1 after Common.PowerShell is loaded.
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

        # Feature-53 workloads behind a NAT router carry _RouterVm
        # stamped by register-runners.ps1; a direct Test-VmSshPort
        # against their private-switch IP would always return $false
        # because the host has no route there. Trust the upstream
        # router-resolution step and rely on the SSH session attempt's
        # own diagnostics if the workload turns out to be down.
        $hasRouter = $t.Entry.PSObject.Properties['_RouterVm'] -and `
                     $t.Entry._RouterVm
        if ($hasRouter) {
            Write-Host "[$name] Skipping direct SSH probe (jumped through router)." `
                -ForegroundColor Cyan
            $reachable.Add($t)
            continue
        }

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
