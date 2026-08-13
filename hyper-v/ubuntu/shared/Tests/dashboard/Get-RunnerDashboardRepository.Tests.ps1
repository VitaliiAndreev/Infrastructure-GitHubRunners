BeforeAll {
    Set-StrictMode -Version Latest
    . "$PSScriptRoot\..\..\dashboard\Get-RunnerDashboardRepository.ps1"

    function New-RunnerEntry {
        param([string] $RunnerName, [string] $GitHubUrl)
        [PSCustomObject]@{ runnerName = $RunnerName; githubUrl = $GitHubUrl }
    }
}

# The function returns its array through the repo's shape-preserving `, $arr`
# idiom, so every test ASSIGNS the result and asserts on that variable. Piping
# the call straight into Should (or wrapping it in @()) would add a level of
# nesting the production caller never sees, and the assertion would then be
# testing the harness rather than the function.
Describe 'Get-RunnerDashboardRepository' {

    It 'reduces a githubUrl to its owner/repo slug' {
        $entries = @(New-RunnerEntry 'r1' 'https://github.com/Klark-Morrigan/Common-Automation')

        $result = Get-RunnerDashboardRepository -RunnerEntry $entries

        $result | Should -Be 'Klark-Morrigan/Common-Automation'
    }

    It 'collapses several runners on one repository to a single slug' {
        # The vault is keyed by runner; polling per entry would multiply every
        # API call by the fleet size for no extra information.
        $entries = @(
            New-RunnerEntry 'r1' 'https://github.com/Klark-Morrigan/Common-Automation'
            New-RunnerEntry 'r2' 'https://github.com/Klark-Morrigan/Common-Automation'
            New-RunnerEntry 'r3' 'https://github.com/Klark-Morrigan/Common-Automation'
        )

        $result = Get-RunnerDashboardRepository -RunnerEntry $entries

        $result.Count | Should -Be 1
    }

    It 'keeps distinct repositories' {
        $entries = @(
            New-RunnerEntry 'r1' 'https://github.com/Klark-Morrigan/Common-Automation'
            New-RunnerEntry 'r2' 'https://github.com/Klark-Morrigan/Infrastructure-E2E'
        )

        $result = Get-RunnerDashboardRepository -RunnerEntry $entries

        $result.Count | Should -Be 2
    }

    It 'treats slugs differing only in case as the same repository' {
        $entries = @(
            New-RunnerEntry 'r1' 'https://github.com/Klark-Morrigan/Common-Automation'
            New-RunnerEntry 'r2' 'https://github.com/klark-morrigan/common-automation'
        )

        $result = Get-RunnerDashboardRepository -RunnerEntry $entries

        $result.Count | Should -Be 1
    }

    It 'preserves the order the entries appeared in' {
        $entries = @(
            New-RunnerEntry 'r1' 'https://github.com/o/zebra'
            New-RunnerEntry 'r2' 'https://github.com/o/apple'
        )

        $result = Get-RunnerDashboardRepository -RunnerEntry $entries

        $result[0] | Should -Be 'o/zebra'
        $result[1] | Should -Be 'o/apple'
    }

    It 'strips a trailing .git' {
        $entries = @(New-RunnerEntry 'r1' 'https://github.com/o/repo.git')

        $result = Get-RunnerDashboardRepository -RunnerEntry $entries

        $result | Should -Be 'o/repo'
    }

    It 'strips a trailing slash' {
        $entries = @(New-RunnerEntry 'r1' 'https://github.com/o/repo/')

        $result = Get-RunnerDashboardRepository -RunnerEntry $entries

        $result | Should -Be 'o/repo'
    }

    It 'ignores path segments beyond owner and repository' {
        $entries = @(New-RunnerEntry 'r1' 'https://github.com/o/repo/tree/master')

        $result = Get-RunnerDashboardRepository -RunnerEntry $entries

        $result | Should -Be 'o/repo'
    }

    It 'returns an empty array for no entries' {
        $result = Get-RunnerDashboardRepository -RunnerEntry @()

        $result.Count | Should -Be 0
    }

    # ------------------------------------------------------------------
    Context 'malformed configuration' {
    # ------------------------------------------------------------------
    # A bad slug would otherwise surface as a 404 on every tick, with nothing
    # to say which vault entry produced it.

        It 'names the offending runner when the URL has no repository segment' {
            $entries = @(New-RunnerEntry 'broken-runner' 'https://github.com/owner-only')

            { Get-RunnerDashboardRepository -RunnerEntry $entries } |
                Should -Throw '*broken-runner*'
        }

        It 'rejects an empty githubUrl' {
            $entries = @(New-RunnerEntry 'broken-runner' '')

            { Get-RunnerDashboardRepository -RunnerEntry $entries } |
                Should -Throw '*githubUrl is empty*'
        }
    }
}
