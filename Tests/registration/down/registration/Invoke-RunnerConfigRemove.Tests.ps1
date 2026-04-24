BeforeAll {
    function Invoke-GitHubRunnersApi { param($Pat, $GithubUrl, $Suffix, $Method) }
    function Invoke-SshClientCommand { param($SshClient, $Command, $ErrorAction) }

    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\registration\down\registration\Invoke-RunnerConfigRemove.ps1"

    $Script:FakeSsh   = [PSCustomObject] @{}
    $Script:RunnerDir = '/home/u-actions-runner/runners/runner-a'

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
            Mock Invoke-GitHubRunnersApi { [PSCustomObject] @{ token = 'rem_token' } }
            Mock Invoke-SshClientCommand { [PSCustomObject] @{ ExitStatus = 0; Error = '' } }

            Invoke-RunnerConfigRemove `
                -SshClient  $Script:FakeSsh `
                -VmName     'vm-01' `
                -RunnerUser 'u-actions-runner' `
                -Entry      (New-Entry 'runner-a') `
                -RunnerDir  $Script:RunnerDir `
                -Pat        'ghp_test'

            Should -Invoke Invoke-GitHubRunnersApi -Times 1 -ParameterFilter {
                $Suffix -eq 'remove-token' -and $Method -eq 'Post'
            }
        }
    }

    Context 'config.sh remove' {
        It 'calls config.sh remove with the correct token, runner user, and --unattended' {
            Mock Invoke-GitHubRunnersApi { [PSCustomObject] @{ token = 'rem_token' } }
            Mock Invoke-SshClientCommand { [PSCustomObject] @{ ExitStatus = 0; Error = '' } }

            Invoke-RunnerConfigRemove `
                -SshClient  $Script:FakeSsh `
                -VmName     'vm-01' `
                -RunnerUser 'u-actions-runner' `
                -Entry      (New-Entry 'runner-a') `
                -RunnerDir  $Script:RunnerDir `
                -Pat        'ghp_test'

            Should -Invoke Invoke-SshClientCommand -Times 1 -ParameterFilter {
                $Command -like "*sudo -u u-actions-runner*config.sh*" -and
                $Command -like "* remove *" -and
                $Command -like "*--token 'rem_token'*" -and
                $Command -like "*--unattended*"
            }
        }

        It 'throws when config.sh remove exits non-zero' {
            Mock Invoke-GitHubRunnersApi { [PSCustomObject] @{ token = 'rem_token' } }
            Mock Invoke-SshClientCommand {
                [PSCustomObject] @{ ExitStatus = 1; Error = 'remove error' }
            }

            { Invoke-RunnerConfigRemove `
                -SshClient  $Script:FakeSsh `
                -VmName     'vm-01' `
                -RunnerUser 'u-actions-runner' `
                -Entry      (New-Entry 'runner-a') `
                -RunnerDir  $Script:RunnerDir `
                -Pat        'ghp_test'
            } | Should -Throw '*config.sh remove failed*'
        }
    }
}
