BeforeAll {
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\registration\common\infra\Test-RunnerVmConnectivity.ps1"

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

    function New-Target {
        param(
            [string] $VmName       = 'ubuntu-01-ci',
            [string] $IpAddress    = '192.168.1.101',
            [string] $DeployUser   = 'u-runner-deploy',
            [string] $RunnerName   = 'ubuntu-01-ci',
            [string] $DeploySecret = 'pass123'
        )
        @{
            Entry    = New-RunnerEntry -VmName $VmName -IpAddress $IpAddress `
                           -DeployUser $DeployUser -RunnerName $RunnerName
            Password = $DeploySecret
        }
    }
}

Describe 'Test-RunnerVmConnectivity' {

    Context 'reachability' {
        It 'returns a reachable target' {
            Mock Test-Connection { $true }
            $result = @(Test-RunnerVmConnectivity -Targets @(New-Target))
            $result | Should -HaveCount 1
        }

        It 'warns and excludes an unreachable target' {
            Mock Test-Connection { $false }
            $result = @(Test-RunnerVmConnectivity -Targets @(New-Target) `
                            -WarningVariable w)
            $result | Should -HaveCount 0
            $w | Should -BeLike '*ubuntu-01-ci*'
        }

        It 'warning does not include the IP address' {
            Mock Test-Connection { $false }
            Test-RunnerVmConnectivity -Targets @(New-Target -IpAddress '10.11.12.13') `
                -WarningVariable w
            $w | Should -Not -BeLike '*10.11.12.13*'
        }

        It 'returns only reachable targets from a mixed list' {
            Mock Test-Connection { $true }  -ParameterFilter { $ComputerName -eq '192.168.1.101' }
            Mock Test-Connection { $false } -ParameterFilter { $ComputerName -eq '192.168.1.102' }
            $targets = (New-Target -RunnerName 'r1' -IpAddress '192.168.1.101'),
                       (New-Target -RunnerName 'r2' -IpAddress '192.168.1.102')
            $result = @(Test-RunnerVmConnectivity -Targets $targets)
            $result | Should -HaveCount 1
            $result[0].Entry.runnerName | Should -Be 'r1'
        }

        It 'calls Test-Connection once per target' {
            Mock Test-Connection { $true }
            $two = (New-Target), (New-Target)
            Test-RunnerVmConnectivity -Targets $two | Out-Null
            Should -Invoke Test-Connection -Times 2 -Exactly
        }

        It 'returns an empty list when targets list is empty' {
            $result = @(Test-RunnerVmConnectivity -Targets @())
            $result | Should -HaveCount 0
        }
    }
}
