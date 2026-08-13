BeforeAll {
    Set-StrictMode -Version Latest

    $dashboard = "$PSScriptRoot\..\..\dashboard"
    . "$dashboard\Format-FixedWidthColumn.ps1"
    . "$dashboard\Format-RunnerElapsed.ps1"
    . "$dashboard\Format-RunnerDashboardFrame.ps1"

    $script:now = [DateTime]::new(2026, 8, 6, 12, 0, 0, [DateTimeKind]::Utc)

    function New-Activity {
        param($Runners = @(), $QueuedJobs = @(), $Failures = @(), $RateLimit = $null)
        [PSCustomObject]@{
            Runners    = $Runners
            QueuedJobs = $QueuedJobs
            Failures   = $Failures
            RateLimit  = $RateLimit
        }
    }

    function New-RunnerRow {
        param(
            [string] $Name = 'ubuntu-01-ci-1',
            [string] $Repository = 'owner/repo',
            [string] $Status = 'online',
            [bool]   $Busy = $false,
            $WorkflowName = $null,
            $JobName = $null,
            $CurrentStep = $null,
            $StartedAt = $null
        )
        [PSCustomObject]@{
            Repository   = $Repository
            Name         = $Name
            Id           = 1
            Status       = $Status
            Busy         = $Busy
            Labels       = @('self-hosted')
            WorkflowName = $WorkflowName
            JobName      = $JobName
            CurrentStep  = $CurrentStep
            StartedAt    = $StartedAt
            Url          = $null
        }
    }

    # Collapses a frame to one searchable string. The tests assert on content,
    # not on which line index it landed on - that would break on any cosmetic
    # reordering without catching a real defect.
    function ConvertTo-FrameText {
        param($Frame)
        ($Frame | ForEach-Object { $_.Text }) -join "`n"
    }

    function Get-RowColour {
        param($Frame, [string] $Match)
        ($Frame | Where-Object { $_.Text -match $Match } | Select-Object -First 1).Colour
    }
}

Describe 'Format-RunnerDashboardFrame' {

    # ------------------------------------------------------------------
    Context 'runner state' {
    # ------------------------------------------------------------------

        It 'shows an idle online runner as IDLE in green' {
            $frame = Format-RunnerDashboardFrame -RefreshSeconds 10 -Now $script:now `
                -Activity (New-Activity -Runners @(New-RunnerRow -Name 'r1'))

            ConvertTo-FrameText $frame | Should -Match 'r1\s+owner/repo\s+IDLE'
            Get-RowColour $frame '^r1' | Should -Be 'Green'
        }

        It 'shows a busy runner as BUSY in cyan' {
            $frame = Format-RunnerDashboardFrame -RefreshSeconds 10 -Now $script:now `
                -Activity (New-Activity -Runners @(New-RunnerRow -Name 'r1' -Busy $true))

            ConvertTo-FrameText $frame | Should -Match 'r1\s+owner/repo\s+BUSY'
            Get-RowColour $frame '^r1' | Should -Be 'Cyan'
        }

        It 'shows an offline runner as OFFLINE in red' {
            $frame = Format-RunnerDashboardFrame -RefreshSeconds 10 -Now $script:now `
                -Activity (New-Activity -Runners @(New-RunnerRow -Name 'r1' -Status 'offline'))

            ConvertTo-FrameText $frame | Should -Match 'r1\s+owner/repo\s+OFFLINE'
            Get-RowColour $frame '^r1' | Should -Be 'Red'
        }

        It 'reports a busy but offline runner as OFFLINE' {
            # GitHub can still report busy on a runner that has dropped off;
            # OFFLINE is the fact worth acting on.
            $frame = Format-RunnerDashboardFrame -RefreshSeconds 10 -Now $script:now `
                -Activity (New-Activity -Runners @(
                    New-RunnerRow -Name 'r1' -Status 'offline' -Busy $true))

            ConvertTo-FrameText $frame | Should -Match 'OFFLINE'
            ConvertTo-FrameText $frame | Should -Not -Match 'BUSY'
        }
    }

    # ------------------------------------------------------------------
    Context 'the job on a runner' {
    # ------------------------------------------------------------------

        It 'renders workflow, job and current step together' {
            $frame = Format-RunnerDashboardFrame -RefreshSeconds 10 -Now $script:now `
                -Activity (New-Activity -Runners @(New-RunnerRow -Busy $true `
                    -WorkflowName 'CI' -JobName 'build' -CurrentStep 'Run tests'))

            ConvertTo-FrameText $frame | Should -Match 'CI / build > Run tests'
        }

        It 'renders what it has when the step is not yet reported' {
            $frame = Format-RunnerDashboardFrame -RefreshSeconds 10 -Now $script:now `
                -Activity (New-Activity -Runners @(New-RunnerRow -Busy $true `
                    -WorkflowName 'CI' -JobName 'build'))

            ConvertTo-FrameText $frame | Should -Match 'CI / build'
        }

        It 'renders the elapsed time of the running job' {
            $frame = Format-RunnerDashboardFrame -RefreshSeconds 10 -Now $script:now `
                -Activity (New-Activity -Runners @(New-RunnerRow -Busy $true `
                    -WorkflowName 'CI' -JobName 'build' `
                    -StartedAt $script:now.AddSeconds(-134)))

            ConvertTo-FrameText $frame | Should -Match '2m14s'
        }
    }

    # ------------------------------------------------------------------
    Context 'header' {
    # ------------------------------------------------------------------

        It 'shows the remaining rate-limit budget' {
            $frame = Format-RunnerDashboardFrame -RefreshSeconds 10 -Now $script:now `
                -Activity (New-Activity -RateLimit ([PSCustomObject]@{
                    Remaining = 4873; Limit = 5000
                    ResetsAt  = [DateTime]::new(2026, 8, 6, 12, 58, 0, [DateTimeKind]::Utc)
                }))

            ConvertTo-FrameText $frame | Should -Match 'rate limit: 4873/5000 \(resets 12:58Z\)'
        }

        It 'says unknown when no response carried the budget headers' {
            $frame = Format-RunnerDashboardFrame -RefreshSeconds 10 -Now $script:now `
                -Activity (New-Activity)

            ConvertTo-FrameText $frame | Should -Match 'rate limit: unknown'
        }

        It 'shows the refresh interval' {
            $frame = Format-RunnerDashboardFrame -RefreshSeconds 30 -Now $script:now `
                -Activity (New-Activity)

            ConvertTo-FrameText $frame | Should -Match 'refresh: 30s'
        }

        It 'counts distinct repositories, not runners' {
            $frame = Format-RunnerDashboardFrame -RefreshSeconds 10 -Now $script:now `
                -Activity (New-Activity -Runners @(
                    New-RunnerRow -Name 'r1' -Repository 'owner/one'
                    New-RunnerRow -Name 'r2' -Repository 'owner/one'
                    New-RunnerRow -Name 'r3' -Repository 'owner/two'))

            ConvertTo-FrameText $frame | Should -Match 'repos: 2'
        }
    }

    # ------------------------------------------------------------------
    Context 'queue section' {
    # ------------------------------------------------------------------

        It 'lists queued jobs with their wait time and labels' {
            $frame = Format-RunnerDashboardFrame -RefreshSeconds 10 -Now $script:now `
                -Activity (New-Activity -QueuedJobs @([PSCustomObject]@{
                    Repository   = 'owner/repo'
                    WorkflowName = 'CI'
                    JobName      = 'lint'
                    Labels       = @('self-hosted', 'linux')
                    QueuedAt     = $script:now.AddSeconds(-42)
                    Url          = $null
                }))

            $text = ConvertTo-FrameText $frame
            $text | Should -Match 'QUEUED \(1\)'
            $text | Should -Match 'CI / lint'
            $text | Should -Match 'waiting 42s'
            $text | Should -Match '\[self-hosted, linux\]'
        }

        It 'omits the section entirely when nothing is queued' {
            # An always-present empty section would shift the runner table
            # every time a job appears or clears.
            $frame = Format-RunnerDashboardFrame -RefreshSeconds 10 -Now $script:now `
                -Activity (New-Activity -Runners @(New-RunnerRow))

            ConvertTo-FrameText $frame | Should -Not -Match 'QUEUED'
        }
    }

    # ------------------------------------------------------------------
    Context 'repositories that could not be polled' {
    # ------------------------------------------------------------------

        It 'lists each failure with its message' {
            $frame = Format-RunnerDashboardFrame -RefreshSeconds 10 -Now $script:now `
                -Activity (New-Activity -Failures @([PSCustomObject]@{
                    Repository = 'owner/private'
                    Message    = 'GitHub API GET repos/owner/private failed with HTTP 403.'
                }))

            $text = ConvertTo-FrameText $frame
            $text | Should -Match 'NOT POLLED \(1\)'
            $text | Should -Match 'owner/private: .*403'
        }

        It 'omits the section when every repository responded' {
            $frame = Format-RunnerDashboardFrame -RefreshSeconds 10 -Now $script:now `
                -Activity (New-Activity -Runners @(New-RunnerRow))

            ConvertTo-FrameText $frame | Should -Not -Match 'NOT POLLED'
        }
    }

    # ------------------------------------------------------------------
    Context 'frame shape' {
    # ------------------------------------------------------------------

        It 'says so plainly when no runners are registered' {
            $frame = Format-RunnerDashboardFrame -RefreshSeconds 10 -Now $script:now `
                -Activity (New-Activity)

            ConvertTo-FrameText $frame | Should -Match 'no runners registered'
        }

        It 'always ends with the key legend' {
            $frame = Format-RunnerDashboardFrame -RefreshSeconds 10 -Now $script:now `
                -Activity (New-Activity -Runners @(New-RunnerRow))

            $frame[-1].Text | Should -Match '\[Q\] quit'
        }

        It 'keeps every line inside a default 100-column terminal' {
            # A wrapped row would break the in-place repaint.
            $frame = Format-RunnerDashboardFrame -RefreshSeconds 10 -Now $script:now `
                -Activity (New-Activity -Runners @(New-RunnerRow `
                    -Name 'a-very-long-runner-name-indeed' `
                    -Repository 'Klark-Morrigan/Infrastructure-Something-Long' `
                    -Busy $true -WorkflowName 'Continuous Integration' `
                    -JobName 'build-and-test-everything' -CurrentStep 'Run the entire suite'))

            foreach ($line in $frame) { $line.Text.Length | Should -BeLessOrEqual 100 }
        }

        It 'emits every line with a text and a colour' {
            $frame = Format-RunnerDashboardFrame -RefreshSeconds 10 -Now $script:now `
                -Activity (New-Activity -Runners @(New-RunnerRow))

            foreach ($line in $frame) {
                $line.PSObject.Properties['Text']   | Should -Not -BeNullOrEmpty
                $line.PSObject.Properties['Colour'] | Should -Not -BeNullOrEmpty
            }
        }
    }
}
