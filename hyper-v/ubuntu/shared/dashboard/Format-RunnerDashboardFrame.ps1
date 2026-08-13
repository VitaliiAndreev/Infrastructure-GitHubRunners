<#
.NOTES
    Do not run this file directly. It is dot-sourced by runner-dashboard.ps1
    after Format-FixedWidthColumn.ps1 and Format-RunnerElapsed.ps1.
#>

# ---------------------------------------------------------------------------
# Format-RunnerDashboardFrame
#   Turns one Get-GitHubRunnerActivity result into the ordered list of lines
#   that make up a screen. Each line is an object with .Text and .Colour;
#   nothing here touches the console.
#
#   Formatting is split from painting (Write-RunnerDashboardFrame) so the
#   layout - column widths, state derivation, which sections appear - is
#   testable as plain data, with no console, no cursor, and no host required.
#   It also means the same frame could be written to a log or a file without
#   reimplementing the layout.
# ---------------------------------------------------------------------------

function Format-RunnerDashboardFrame {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        # A Get-GitHubRunnerActivity result: .Runners, .QueuedJobs,
        # .Failures, .RateLimit.
        [Parameter(Mandatory)]
        $Activity,

        # Shown in the header so the operator knows how stale a row can be.
        [Parameter(Mandatory)]
        [int] $RefreshSeconds,

        # UTC reference point for every elapsed time on the frame. Injectable
        # so the rendered output is deterministic under test.
        [Parameter()]
        [DateTime] $Now = [DateTime]::UtcNow
    )

    # A wrapped row would break the in-place repaint, so no line may exceed
    # the width of a default terminal. Add-FrameLine enforces that ceiling for
    # every line; the column widths below (plus their single-space gutters)
    # are sized to fit inside it without ever being clipped.
    #   20 + 1 + 28 + 1 + 7 + 1 + 32 + 1 + 6 = 97
    $maxLineWidth = 100
    $runnerWidth  = 20
    $repoWidth    = 28
    $stateWidth   = 7
    $jobWidth     = 32
    $forWidth     = 6

    $emptyMarker = '-'
    $clipMarker  = '...'

    $lines = [System.Collections.Generic.List[object]]::new()

    # Enforcing the ceiling here rather than at each call site is what keeps
    # the free-form lines - a queued job's label list, a failure message of
    # unbounded length - from being the one place the invariant leaks.
    function Add-FrameLine {
        param([string] $Text, [string] $Colour = 'Gray')
        if ($Text.Length -gt $maxLineWidth) {
            $Text = $Text.Substring(0, $maxLineWidth - $clipMarker.Length) + $clipMarker
        }
        $lines.Add([PSCustomObject]@{ Text = $Text; Colour = $Colour })
    }

    # -- Header ---------------------------------------------------------
    $titleWidth = 60
    Add-FrameLine ('GitHub Actions runners - live'.PadRight($titleWidth) +
                   $Now.ToString('yyyy-MM-dd HH:mm:ss') + 'Z') 'White'

    # The rate-limit reading is the one number that tells an operator whether
    # the refresh interval is sustainable, so it goes in the header rather
    # than being buried at the bottom.
    $budget = if ($null -ne $Activity.RateLimit) {
        $resets = if ($null -ne $Activity.RateLimit.ResetsAt) {
            ' (resets ' + $Activity.RateLimit.ResetsAt.ToString('HH:mm') + 'Z)'
        } else { '' }
        "$($Activity.RateLimit.Remaining)/$($Activity.RateLimit.Limit)$resets"
    } else {
        'unknown'
    }
    $repoCount = @($Activity.Runners |
        ForEach-Object { $_.Repository } | Select-Object -Unique).Count
    Add-FrameLine "repos: $repoCount   refresh: ${RefreshSeconds}s   rate limit: $budget" 'DarkGray'
    Add-FrameLine ''

    # -- Runner table ---------------------------------------------------
    Add-FrameLine (
        (Format-FixedWidthColumn 'RUNNER'     $runnerWidth) + ' ' +
        (Format-FixedWidthColumn 'REPOSITORY' $repoWidth)   + ' ' +
        (Format-FixedWidthColumn 'STATE'      $stateWidth)  + ' ' +
        (Format-FixedWidthColumn 'JOB'        $jobWidth)    + ' ' +
        (Format-FixedWidthColumn 'FOR'        $forWidth)
    ) 'DarkGray'

    if (@($Activity.Runners).Count -eq 0) {
        Add-FrameLine '  (no runners registered on the polled repositories)' 'DarkGray'
    }

    foreach ($runner in $Activity.Runners) {
        # Offline outranks busy: a runner GitHub last saw executing something
        # can still be reported busy after it drops off, and "offline" is the
        # fact the operator needs to act on.
        $state, $colour =
            if ($runner.Status -ne 'online') { 'OFFLINE', 'Red' }
            elseif ($runner.Busy)            { 'BUSY',    'Cyan' }
            else                             { 'IDLE',    'Green' }

        # 'CI / build > Run tests' - workflow, job, then the live step. Built
        # from whichever parts are present so a partially-reported job still
        # says something useful.
        # Outer @() is load-bearing: Where-Object that matches nothing yields
        # $null, not an empty array, and .Count on $null is fatal under
        # Set-StrictMode - which is exactly the idle-runner case.
        $jobParts = @(@($runner.WorkflowName, $runner.JobName) | Where-Object { $_ })
        $job = if ($jobParts.Count -gt 0) { $jobParts -join ' / ' } else { $emptyMarker }
        if ($runner.CurrentStep) { $job = "$job > $($runner.CurrentStep)" }

        Add-FrameLine (
            (Format-FixedWidthColumn $runner.Name       $runnerWidth) + ' ' +
            (Format-FixedWidthColumn $runner.Repository $repoWidth)   + ' ' +
            (Format-FixedWidthColumn $state             $stateWidth)  + ' ' +
            (Format-FixedWidthColumn $job               $jobWidth)    + ' ' +
            (Format-FixedWidthColumn (Format-RunnerElapsed $runner.StartedAt -Now $Now) $forWidth)
        ) $colour
    }

    # -- Queue ----------------------------------------------------------
    # Only rendered when non-empty: an always-present empty section would
    # push the runner table around as jobs come and go.
    $queued = @($Activity.QueuedJobs)
    if ($queued.Count -gt 0) {
        Add-FrameLine ''
        Add-FrameLine "QUEUED ($($queued.Count))" 'Yellow'
        foreach ($job in $queued) {
            $labels = @($job.Labels) -join ', '
            Add-FrameLine (
                '  ' +
                (Format-FixedWidthColumn $job.Repository $repoWidth) + ' ' +
                (Format-FixedWidthColumn "$($job.WorkflowName) / $($job.JobName)" $jobWidth) + ' ' +
                'waiting ' +
                (Format-FixedWidthColumn (Format-RunnerElapsed $job.QueuedAt -Now $Now) $forWidth) +
                " [$labels]"
            ) 'Yellow'
        }
    }

    # -- Repositories that could not be polled --------------------------
    $failures = @($Activity.Failures)
    if ($failures.Count -gt 0) {
        Add-FrameLine ''
        Add-FrameLine "NOT POLLED ($($failures.Count))" 'Red'
        foreach ($failure in $failures) {
            Add-FrameLine "  $($failure.Repository): $($failure.Message)" 'Red'
        }
    }

    Add-FrameLine ''
    Add-FrameLine '[Q] quit   [R] refresh now' 'DarkGray'

    , $lines.ToArray()
}
