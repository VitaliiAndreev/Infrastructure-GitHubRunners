<#
.NOTES
    Do not run this file directly. It is dot-sourced by runner-dashboard.ps1.
#>

# ---------------------------------------------------------------------------
# Format-FixedWidthColumn
#   Pads or truncates a value to an exact character width so the dashboard's
#   columns stay aligned frame after frame.
#
#   Exact width matters more here than it would in a one-shot report: the
#   dashboard repaints in place over the previous frame, so a row that grows
#   or shrinks by a character leaves the columns visibly jittering as values
#   change. Truncation is marked with a trailing ellipsis character so a
#   clipped repository or step name is never mistaken for the whole value.
# ---------------------------------------------------------------------------

function Format-FixedWidthColumn {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # $null renders as the empty marker rather than an empty cell, so a
        # missing value reads as "nothing here" instead of "column broken".
        [Parameter(Mandatory, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Value,

        [Parameter(Mandatory, Position = 1)]
        [ValidateRange(1, 500)]
        [int] $Width
    )

    $emptyMarker  = '-'
    # ASCII only (three dots, not a single ellipsis glyph) - the console this
    # renders in is not guaranteed to be on a Unicode code page.
    $clipMarker   = '...'

    $text = if ([string]::IsNullOrEmpty($Value)) { $emptyMarker } else { $Value }

    if ($text.Length -le $Width) { return $text.PadRight($Width) }

    # Too narrow to fit even the marker: a hard cut is the only option left.
    if ($Width -le $clipMarker.Length) { return $text.Substring(0, $Width) }

    return $text.Substring(0, $Width - $clipMarker.Length) + $clipMarker
}
