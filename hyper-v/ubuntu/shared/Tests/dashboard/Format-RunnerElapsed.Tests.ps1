BeforeAll {
    Set-StrictMode -Version Latest
    . "$PSScriptRoot\..\..\dashboard\Format-RunnerElapsed.ps1"

    $script:now = [DateTime]::new(2026, 8, 6, 12, 0, 0, [DateTimeKind]::Utc)
}

Describe 'Format-RunnerElapsed' {

    It 'renders seconds alone under a minute' {
        Format-RunnerElapsed $script:now.AddSeconds(-47) -Now $script:now | Should -Be '47s'
    }

    It 'renders minutes and zero-padded seconds under an hour' {
        Format-RunnerElapsed $script:now.AddSeconds(-134) -Now $script:now | Should -Be '2m14s'
    }

    It 'renders hours and zero-padded minutes at an hour and beyond' {
        Format-RunnerElapsed $script:now.AddMinutes(-64) -Now $script:now | Should -Be '1h04m'
    }

    It 'switches unit exactly at the minute boundary' {
        Format-RunnerElapsed $script:now.AddSeconds(-59) -Now $script:now | Should -Be '59s'
        Format-RunnerElapsed $script:now.AddSeconds(-60) -Now $script:now | Should -Be '1m00s'
    }

    It 'switches unit exactly at the hour boundary' {
        Format-RunnerElapsed $script:now.AddSeconds(-3599) -Now $script:now | Should -Be '59m59s'
        Format-RunnerElapsed $script:now.AddSeconds(-3600) -Now $script:now | Should -Be '1h00m'
    }

    It 'renders a dash for an idle runner with no start time' {
        Format-RunnerElapsed $null -Now $script:now | Should -Be '-'
    }

    It 'clamps a future start time to zero rather than showing a negative age' {
        # Clock skew between this host and GitHub can put a just-started job
        # marginally ahead of local now.
        Format-RunnerElapsed $script:now.AddSeconds(5) -Now $script:now | Should -Be '0s'
    }

    It 'renders a multi-hour age without rolling over' {
        Format-RunnerElapsed $script:now.AddHours(-26) -Now $script:now | Should -Be '26h00m'
    }
}
