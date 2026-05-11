BeforeAll {
    # Stub Test-VmSshPort (provided by Infrastructure.HyperV at runtime) so
    # the unit test does not need to import the module. The function under
    # test resolves the stub via PowerShell scope rules; Mock then replaces
    # it inside the It block.
    function Test-VmSshPort { param($IpAddress, $Port, $TimeoutMilliseconds) }

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
            Mock Test-VmSshPort { $true }
            $result = Test-RunnerVmConnectivity -Targets @(New-Target)
            $result | Should -HaveCount 1
        }

        It 'warns and excludes an unreachable target' {
            Mock Test-VmSshPort { $false }
            $result = Test-RunnerVmConnectivity -Targets @(New-Target) `
                          -WarningVariable w
            $result | Should -HaveCount 0
            $w | Should -BeLike '*ubuntu-01-ci*'
        }

        It 'warning does not include the IP address' {
            Mock Test-VmSshPort { $false }
            Test-RunnerVmConnectivity -Targets @(New-Target -IpAddress '10.11.12.13') `
                -WarningVariable w
            $w | Should -Not -BeLike '*10.11.12.13*'
        }

        It 'returns only reachable targets from a mixed list' {
            Mock Test-VmSshPort { $true }  -ParameterFilter { $IpAddress -eq '192.168.1.101' }
            Mock Test-VmSshPort { $false } -ParameterFilter { $IpAddress -eq '192.168.1.102' }
            $targets = (New-Target -RunnerName 'r1' -IpAddress '192.168.1.101'),
                       (New-Target -RunnerName 'r2' -IpAddress '192.168.1.102')
            $result = Test-RunnerVmConnectivity -Targets $targets
            $result | Should -HaveCount 1
            $result[0].Entry.runnerName | Should -Be 'r1'
        }

        It 'calls Test-VmSshPort once per target' {
            Mock Test-VmSshPort { $true }
            $two = (New-Target), (New-Target)
            Test-RunnerVmConnectivity -Targets $two | Out-Null
            Should -Invoke Test-VmSshPort -Times 2 -Exactly
        }

        It 'returns an empty list when targets list is empty' {
            $result = Test-RunnerVmConnectivity -Targets @()
            $result | Should -HaveCount 0
        }
    }
}
