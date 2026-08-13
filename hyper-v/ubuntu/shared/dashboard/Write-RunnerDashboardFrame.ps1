<#
.NOTES
    Do not run this file directly. It is dot-sourced by runner-dashboard.ps1.
#>

# ---------------------------------------------------------------------------
# Write-RunnerDashboardFrame
#   Paints a formatted frame and returns the number of lines it wrote.
#
#   The frame is drawn from the cursor home position over the top of the
#   previous one rather than after a Clear-Host. Clear-Host blanks the buffer
#   and then repaints, which on a Windows console shows as a visible flash on
#   every tick; overwriting in place does not. That trades one problem for
#   another - a shorter frame would leave the tail of the longer previous one
#   on screen - so the caller passes -PreviousLineCount and the difference is
#   blanked explicitly. Returning the new count is what lets the caller thread
#   that value into the next call without this file holding hidden state.
#
#   Every line is padded to the console width for the same reason: a short
#   line would otherwise leave the previous frame's characters to its right.
#
#   When stdout is redirected there is no cursor to position and no width to
#   pad to, so the function degrades to plain sequential output. That keeps a
#   piped or logged run readable instead of failing on a console API call.
# ---------------------------------------------------------------------------

function Write-RunnerDashboardFrame {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        # Lines from Format-RunnerDashboardFrame: .Text and .Colour each.
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Line,

        # Lines the previous frame wrote. Any excess is blanked so a shrinking
        # board does not leave stale rows behind. Zero on the first frame.
        [Parameter()]
        [int] $PreviousLineCount = 0
    )

    $homeColumn = 0
    $homeRow    = 0
    # One column short of the full width: writing the last cell of a line
    # makes the console wrap to the next row, which would double-space the
    # whole frame.
    $widthMargin = 1

    $lines = @($Line)

    if ([Console]::IsOutputRedirected) {
        foreach ($item in $lines) { Write-Host $item.Text -ForegroundColor $item.Colour }
        return $lines.Count
    }

    [Console]::SetCursorPosition($homeColumn, $homeRow)

    $width = [Math]::Max([Console]::WindowWidth - $widthMargin, 1)

    foreach ($item in $lines) {
        $text = $item.Text
        if ($text.Length -gt $width) { $text = $text.Substring(0, $width) }
        Write-Host $text.PadRight($width) -ForegroundColor $item.Colour
    }

    for ($row = $lines.Count; $row -lt $PreviousLineCount; $row++) {
        Write-Host (' ' * $width)
    }

    return $lines.Count
}
