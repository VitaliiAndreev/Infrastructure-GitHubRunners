BeforeAll {
    function Invoke-SshClientCommand { param($SshClient, $Command, $ErrorAction) }
    function Get-RunnerServiceName   { param($SshClient, $RunnerName) }

    . "$PSScriptRoot\..\..\hyper-v\ubuntu\register\Start-RunnerService.ps1"

    $Script:FakeSsh = [PSCustomObject] @{}
}

Describe 'Start-RunnerService' {

    Context 'service unit not installed' {
        It 'writes an error when Get-RunnerServiceName returns $null' {
            Mock Get-RunnerServiceName { $null }
            Mock Invoke-SshClientCommand { [PSCustomObject] @{ Output = ''; ExitStatus = 0; Error = '' } }
            Mock Write-Error { }

            Start-RunnerService `
                -SshClient  $Script:FakeSsh `
                -VmName     'vm-01' `
                -RunnerName 'runner-a'

            Should -Invoke Invoke-SshClientCommand -Times 0
            Should -Invoke Write-Error -Times 1
        }
    }

    Context 'service unit installed' {
        It 'calls systemctl start with the correct service name' {
            Mock Get-RunnerServiceName { 'actions.runner.user-repo.runner-a.service' }
            Mock Invoke-SshClientCommand {
                param($SshClient, $Command)
                $output = if ($Command -like '*is-active*') { 'active' } else { '' }
                [PSCustomObject] @{ Output = $output; ExitStatus = 0; Error = '' }
            }

            Start-RunnerService `
                -SshClient  $Script:FakeSsh `
                -VmName     'vm-01' `
                -RunnerName 'runner-a'

            Should -Invoke Invoke-SshClientCommand -Times 1 -ParameterFilter {
                $Command -like "*systemctl start 'actions.runner.user-repo.runner-a.service'*"
            }
        }

        It 'writes an error when systemctl start fails' {
            Mock Get-RunnerServiceName { 'actions.runner.user-repo.runner-a.service' }
            Mock Invoke-SshClientCommand {
                [PSCustomObject] @{ Output = ''; ExitStatus = 1; Error = 'failed' }
            }
            Mock Write-Error { }

            Start-RunnerService `
                -SshClient  $Script:FakeSsh `
                -VmName     'vm-01' `
                -RunnerName 'runner-a'

            Should -Invoke Write-Error -Times 1
        }

        It 'writes an error when service is still not active after start' {
            Mock Get-RunnerServiceName { 'actions.runner.user-repo.runner-a.service' }
            Mock Invoke-SshClientCommand {
                param($SshClient, $Command)
                $output = if ($Command -like '*is-active*') { 'failed' } else { '' }
                [PSCustomObject] @{ Output = $output; ExitStatus = 0; Error = '' }
            }
            Mock Write-Error { }

            Start-RunnerService `
                -SshClient  $Script:FakeSsh `
                -VmName     'vm-01' `
                -RunnerName 'runner-a'

            Should -Invoke Write-Error -Times 1
        }

        It 'writes a success message when the service starts successfully' {
            Mock Get-RunnerServiceName { 'actions.runner.user-repo.runner-a.service' }
            Mock Invoke-SshClientCommand {
                param($SshClient, $Command)
                $output = if ($Command -like '*is-active*') { 'active' } else { '' }
                [PSCustomObject] @{ Output = $output; ExitStatus = 0; Error = '' }
            }
            Mock Write-Error { }

            Start-RunnerService `
                -SshClient  $Script:FakeSsh `
                -VmName     'vm-01' `
                -RunnerName 'runner-a'

            Should -Invoke Write-Error -Times 0
        }
    }
}
