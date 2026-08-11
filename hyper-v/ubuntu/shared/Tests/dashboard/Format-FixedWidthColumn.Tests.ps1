BeforeAll {
    Set-StrictMode -Version Latest
    . "$PSScriptRoot\..\..\dashboard\Format-FixedWidthColumn.ps1"
}

Describe 'Format-FixedWidthColumn' {

    It 'pads a short value to the full width' {
        Format-FixedWidthColumn 'abc' 8 | Should -Be 'abc     '
    }

    It 'leaves an exactly-fitting value unchanged' {
        Format-FixedWidthColumn 'abcdefgh' 8 | Should -Be 'abcdefgh'
    }

    It 'always returns exactly the requested width' {
        # The frame repaints over the previous one, so a row that changes
        # width leaves the columns visibly jittering.
        foreach ($value in @('', 'a', 'abcdefgh', 'abcdefghijklmnop')) {
            (Format-FixedWidthColumn $value 8).Length | Should -Be 8
        }
    }

    It 'marks a truncated value so it is not mistaken for the whole one' {
        Format-FixedWidthColumn 'Klark-Morrigan/Common-Automation' 12 | Should -Be 'Klark-Mor...'
    }

    It 'hard-cuts when the width cannot hold the truncation marker' {
        Format-FixedWidthColumn 'abcdef' 3 | Should -Be 'abc'
    }

    It 'renders an empty value as the empty marker' {
        Format-FixedWidthColumn '' 5 | Should -Be '-    '
    }

    It 'renders a null value as the empty marker' {
        Format-FixedWidthColumn $null 5 | Should -Be '-    '
    }
}
