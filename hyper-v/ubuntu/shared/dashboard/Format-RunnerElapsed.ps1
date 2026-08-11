<#
.NOTES
    Do not run this file directly. It is dot-sourced by runner-dashboard.ps1.
#>

# ---------------------------------------------------------------------------
# Format-RunnerElapsed
#   Renders "how long has this been going" as a short fixed-shape string:
#   '47s', '2m14s', '1h04m'. Returns '-' when there is no start time.
#
#   The unit set shrinks as the magnitude grows on purpose. An operator
#   scanning the board cares about seconds on a job that just started and
#   about hours on one that has hung; showing both at once would widen the
#   column for no gain and make the numbers harder to compare down the row.
#
#   -Now is injectable so the output is deterministic under test; production
#   callers take the default.
# ---------------------------------------------------------------------------

function Format-RunnerElapsed {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # UTC start instant, or $null when the runner is idle.
        [Parameter(Position = 0)]
        [AllowNull()]
        [Nullable[DateTime]] $StartedAt,

        # UTC reference point the elapsed time is measured back from.
        [Parameter()]
        [DateTime] $Now = [DateTime]::UtcNow
    )

    $emptyMarker = '-'

    if ($null -eq $StartedAt) { return $emptyMarker }

    $elapsed = $Now - $StartedAt

    # Clock skew between this host and GitHub can put a just-started job
    # marginally in the future. Clamping beats rendering a negative age.
    if ($elapsed.Ticks -lt 0) { $elapsed = [TimeSpan]::Zero }

    # [Math]::Floor, not an [int] cast: the cast rounds half-to-even, so 3599
    # seconds (TotalMinutes 59.98) would render as '60m59s' - a unit that
    # should already have rolled over to hours, showing a value that cannot
    # exist. Flooring is what makes the units agree with the remainder.
    if ($elapsed.TotalHours -ge 1) {
        return ('{0}h{1:00}m' -f [Math]::Floor($elapsed.TotalHours), $elapsed.Minutes)
    }
    if ($elapsed.TotalMinutes -ge 1) {
        return ('{0}m{1:00}s' -f [Math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds)
    }
    return ('{0}s' -f [Math]::Floor($elapsed.TotalSeconds))
}
