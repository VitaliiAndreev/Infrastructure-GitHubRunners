BeforeAll {
    function Invoke-SshClientCommand { param($SshClient, $Command, $ErrorAction) }

    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\registration\common\service\Get-RunnerServiceName.ps1"

    $Script:FakeSsh = [PSCustomObject] @{}
}

Describe 'Get-RunnerServiceName' {

    Context 'service unit found' {
        It 'returns the unit name from the first matching line' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject] @{
                    Output     = 'actions.runner.user-repo.runner-a.service disabled'
                    ExitStatus = 0; Error = ''
                }
            }

            $result = Get-RunnerServiceName -SshClient $Script:FakeSsh -RunnerName 'runner-a'

            $result | Should -Be 'actions.runner.user-repo.runner-a.service'
        }

        It 'uses the runner name as a dot-delimited field in the grep filter' {
            Mock Invoke-SshClientCommand { [PSCustomObject] @{ Output = ''; ExitStatus = 0; Error = '' } }

            Get-RunnerServiceName -SshClient $Script:FakeSsh -RunnerName 'runner-a'

            Should -Invoke Invoke-SshClientCommand -Times 1 -ParameterFilter {
                $Command -like "*grep -F '.runner-a.'*"
            }
        }
    }

    Context 'service unit absent' {
        It 'returns $null when no matching unit file is installed' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject] @{ Output = ''; ExitStatus = 0; Error = '' }
            }

            $result = Get-RunnerServiceName -SshClient $Script:FakeSsh -RunnerName 'runner-a'

            $result | Should -BeNullOrEmpty
        }
    }
}
