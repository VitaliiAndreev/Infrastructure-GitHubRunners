BeforeAll {
    function Invoke-SshClientCommand { param($SshClient, $Command, $ErrorAction) }
    function Get-RunnerServiceName   { param($SshClient, $RunnerName) }

    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\registration\common\service\Test-RunnerServiceActive.ps1"

    $Script:FakeSsh = [PSCustomObject] @{}
}

Describe 'Test-RunnerServiceActive' {

    Context 'service unit not installed' {
        It 'returns $false when Get-RunnerServiceName returns $null' {
            Mock Get-RunnerServiceName { $null }

            $result = Test-RunnerServiceActive `
                -SshClient  $Script:FakeSsh `
                -VmName     'vm-01' `
                -RunnerName 'runner-a'

            $result | Should -Be $false
        }
    }

    Context 'service unit installed' {
        It 'returns $true when systemctl is-active reports active' {
            Mock Get-RunnerServiceName { 'actions.runner.user-repo.runner-a.service' }
            Mock Invoke-SshClientCommand {
                [PSCustomObject] @{ Output = 'active'; ExitStatus = 0; Error = '' }
            }

            $result = Test-RunnerServiceActive `
                -SshClient  $Script:FakeSsh `
                -VmName     'vm-01' `
                -RunnerName 'runner-a'

            $result | Should -Be $true
        }

        It 'returns $false when systemctl is-active reports inactive' {
            Mock Get-RunnerServiceName { 'actions.runner.user-repo.runner-a.service' }
            Mock Invoke-SshClientCommand {
                [PSCustomObject] @{ Output = 'inactive'; ExitStatus = 3; Error = '' }
            }

            $result = Test-RunnerServiceActive `
                -SshClient  $Script:FakeSsh `
                -VmName     'vm-01' `
                -RunnerName 'runner-a'

            $result | Should -Be $false
        }

        It 'passes the service name returned by Get-RunnerServiceName to systemctl' {
            Mock Get-RunnerServiceName { 'actions.runner.user-repo.runner-a.service' }
            Mock Invoke-SshClientCommand {
                [PSCustomObject] @{ Output = 'active'; ExitStatus = 0; Error = '' }
            }

            Test-RunnerServiceActive `
                -SshClient  $Script:FakeSsh `
                -VmName     'vm-01' `
                -RunnerName 'runner-a'

            Should -Invoke Invoke-SshClientCommand -Times 1 -ParameterFilter {
                $Command -like "*systemctl is-active 'actions.runner.user-repo.runner-a.service'*"
            }
        }
    }
}
