BeforeAll {
    function Invoke-GitHubApi     { param($Token, $Endpoint, $Uri, $Method) }
    function Invoke-SshClientCommand { param($SshClient, $Command, $ErrorAction) }

    . "$PSScriptRoot\..\..\..\..\registration\down\registration\Invoke-RunnerConfigRemove.ps1"

    $Script:FakeSsh   = [PSCustomObject] @{}
    $Script:RunnerDir = '/opt/runners/runner-a'

    function New-Entry ([string] $RunnerName) {
        [PSCustomObject] @{
            runnerName = $RunnerName
            githubUrl  = 'https://github.com/user/repo-a'
        }
    }
}

Describe 'Invoke-RunnerConfigRemove' {

    Context 'token fetch' {
        It 'fetches a removal token before calling config.sh' {
            Mock Invoke-GitHubApi     { [PSCustomObject] @{ token = 'rem_token' } }
            Mock Invoke-SshClientCommand { [PSCustomObject] @{ ExitStatus = 0; Error = '' } }

            Invoke-RunnerConfigRemove `
                -SshClient  $Script:FakeSsh `
                -VmName     'vm-01' `
                -RunnerUser 'u-actions-runner' `
                -Entry      (New-Entry 'runner-a') `
                -RunnerDir  $Script:RunnerDir `
                -Token      'ghp_test'

            Should -Invoke Invoke-GitHubApi -Times 1 -ParameterFilter {
                $Endpoint -like '*remove-token' -and $Method -eq 'Post'
            }
        }
    }

    Context 'config.sh remove' {
        It 'calls config.sh remove with the correct token, runner user, and --unattended' {
            Mock Invoke-GitHubApi     { [PSCustomObject] @{ token = 'rem_token' } }
            Mock Invoke-SshClientCommand { [PSCustomObject] @{ ExitStatus = 0; Error = '' } }

            Invoke-RunnerConfigRemove `
                -SshClient  $Script:FakeSsh `
                -VmName     'vm-01' `
                -RunnerUser 'u-actions-runner' `
                -Entry      (New-Entry 'runner-a') `
                -RunnerDir  $Script:RunnerDir `
                -Token      'ghp_test'

            Should -Invoke Invoke-SshClientCommand -Times 1 -ParameterFilter {
                $Command -like "*sudo -u u-actions-runner*config.sh*" -and
                $Command -like "* remove *" -and
                $Command -like "*--token 'rem_token'*" -and
                $Command -like "*--unattended*"
            }
        }

        It 'throws when config.sh remove exits non-zero' {
            Mock Invoke-GitHubApi     { [PSCustomObject] @{ token = 'rem_token' } }
            Mock Invoke-SshClientCommand {
                [PSCustomObject] @{ ExitStatus = 1; Error = 'remove error' }
            }

            { Invoke-RunnerConfigRemove `
                -SshClient  $Script:FakeSsh `
                -VmName     'vm-01' `
                -RunnerUser 'u-actions-runner' `
                -Entry      (New-Entry 'runner-a') `
                -RunnerDir  $Script:RunnerDir `
                -Token      'ghp_test'
            } | Should -Throw '*config.sh remove failed*'
        }
    }
}
