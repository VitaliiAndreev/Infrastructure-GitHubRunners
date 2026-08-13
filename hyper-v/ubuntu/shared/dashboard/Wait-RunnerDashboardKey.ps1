<#
.NOTES
    Do not run this file directly. It is dot-sourced by runner-dashboard.ps1.
#>

# ---------------------------------------------------------------------------
# Wait-RunnerDashboardKey
#   Waits out the refresh interval while staying responsive to a keypress.
#   Returns 'Quit', 'Refresh', or 'Timeout'.
#
#   A plain Start-Sleep for the whole interval would leave Q and R unanswered
#   for up to that long, which on a 10-second refresh feels broken. Polling
#   Console.KeyAvailable in short slices keeps the response under one slice
#   while still spending almost the entire interval asleep - the alternative,
#   a blocking read on a background thread, buys nothing here and costs a
#   runspace and its teardown.
#
#   Any key other than Q or R falls through to a refresh: on a status board
#   "something happened, show me now" is the only reasonable reading of an
#   unrecognised keystroke.
#
#   With input redirected there is no keyboard to poll, so the function sleeps
#   the interval out and reports a timeout. That is what makes an unattended
#   run (piped, logged, scheduled) behave as a plain refresh loop.
# ---------------------------------------------------------------------------

function Wait-RunnerDashboardKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 3600)]
        [int] $TimeoutSeconds,

        # Poll slice. Short enough that a keypress feels immediate, long
        # enough that the wait costs no measurable CPU.
        [Parameter()]
        [ValidateRange(10, 1000)]
        [int] $PollMilliseconds = 100
    )

    $quitKey    = 'Q'
    $refreshKey = 'R'

    if ([Console]::IsInputRedirected) {
        Start-Sleep -Seconds $TimeoutSeconds
        return 'Timeout'
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    while ([DateTime]::UtcNow -lt $deadline) {
        if ([Console]::KeyAvailable) {
            # $true suppresses the echo - a stray character printed into the
            # frame would survive until the next full repaint.
            $key = [Console]::ReadKey($true).Key.ToString()
            if ($key -eq $quitKey)    { return 'Quit' }
            if ($key -eq $refreshKey) { return 'Refresh' }
            return 'Refresh'
        }
        Start-Sleep -Milliseconds $PollMilliseconds
    }

    return 'Timeout'
}
