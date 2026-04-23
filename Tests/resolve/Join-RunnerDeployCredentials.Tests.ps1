BeforeAll {
    . "$PSScriptRoot\..\..\hyper-v\ubuntu\resolve\Join-RunnerDeployCredentials.ps1"

    function New-RunnerEntry {
        param(
            [string] $VmName       = 'ubuntu-01-ci',
            [string] $IpAddress    = '192.168.1.101',
            [string] $DeployUser   = 'u-runner-deploy',
            [string] $RunnerName   = 'ubuntu-01-ci'
        )
        [PSCustomObject]@{
            vmName         = $VmName
            ipAddress      = $IpAddress
            deployUsername = $DeployUser
            runnerName     = $RunnerName
        }
    }
}

Describe 'Join-RunnerDeployCredentials' {

    Context 'matching' {
        It 'pairs an entry with its matching password' {
            $entry     = New-RunnerEntry
            $passwords = @{ 'ubuntu-01-ci|u-runner-deploy' = 'pass123' }
            $result    = @(Join-RunnerDeployCredentials -RunnerEntries @($entry) `
                               -DeployPasswords $passwords)
            $result | Should -HaveCount 1
            $result[0].Password | Should -Be 'pass123'
            $result[0].Entry.runnerName | Should -Be 'ubuntu-01-ci'
        }

        It 'returns all entries when all have matching passwords' {
            $entries   = (New-RunnerEntry -RunnerName 'r1' -VmName 'vm1' -DeployUser 'u1'),
                         (New-RunnerEntry -RunnerName 'r2' -VmName 'vm2' -DeployUser 'u2')
            $passwords = @{ 'vm1|u1' = 'p1'; 'vm2|u2' = 'p2' }
            $result    = @(Join-RunnerDeployCredentials -RunnerEntries $entries `
                               -DeployPasswords $passwords)
            $result | Should -HaveCount 2
        }

        It 'warns and skips an entry with no matching password' {
            $entry     = New-RunnerEntry
            $passwords = @{}
            $result    = @(Join-RunnerDeployCredentials -RunnerEntries @($entry) `
                               -DeployPasswords $passwords)
            $result | Should -HaveCount 0
        }

        It 'warns on the skipped entry' {
            $entry     = New-RunnerEntry -RunnerName 'ubuntu-01-ci'
            $passwords = @{}
            Join-RunnerDeployCredentials -RunnerEntries @($entry) `
                -DeployPasswords $passwords -WarningVariable w
            $w | Should -BeLike '*ubuntu-01-ci*'
        }

        It 'returns only matched entries when some are missing passwords' {
            $entries   = (New-RunnerEntry -RunnerName 'r1' -VmName 'vm1' -DeployUser 'u1'),
                         (New-RunnerEntry -RunnerName 'r2' -VmName 'vm2' -DeployUser 'u2')
            $passwords = @{ 'vm1|u1' = 'p1' }
            $result    = @(Join-RunnerDeployCredentials -RunnerEntries $entries `
                               -DeployPasswords $passwords)
            $result | Should -HaveCount 1
            $result[0].Entry.runnerName | Should -Be 'r1'
        }

        It 'returns an empty list when no entries are provided' {
            $result = @(Join-RunnerDeployCredentials -RunnerEntries @() `
                            -DeployPasswords @{})
            $result | Should -HaveCount 0
        }
    }
}
