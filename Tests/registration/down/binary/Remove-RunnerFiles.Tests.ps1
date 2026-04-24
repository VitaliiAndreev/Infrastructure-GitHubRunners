BeforeAll {
    function Invoke-SshClientCommand { param($SshClient, $Command, $ErrorAction) }

    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\registration\down\binary\Remove-RunnerFiles.ps1"

    $Script:FakeSsh   = [PSCustomObject] @{}
    $Script:RunnerDir = '/home/u-actions-runner/runners/runner-a'
}

Describe 'Remove-RunnerFiles' {

    Context 'directory removal' {
        It 'issues the removal command for the runner directory' {
            Mock Invoke-SshClientCommand { [PSCustomObject] @{ ExitStatus = 0; Error = '' } }

            Remove-RunnerFiles -SshClient $Script:FakeSsh -VmName 'vm-01' `
                -RunnerName 'runner-a' -RunnerDir $Script:RunnerDir

            Should -Invoke Invoke-SshClientCommand -Times 1 -ParameterFilter {
                $Command -like "*'$($Script:RunnerDir)'*"
            }
        }

        It 'does not throw when the directory is already absent' {
            Mock Invoke-SshClientCommand { [PSCustomObject] @{ ExitStatus = 0; Error = '' } }

            { Remove-RunnerFiles -SshClient $Script:FakeSsh -VmName 'vm-01' `
                -RunnerName 'runner-a' -RunnerDir $Script:RunnerDir
            } | Should -Not -Throw
        }

        It 'throws when the SSH command fails' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject] @{ ExitStatus = 1; Error = 'permission denied' }
            }

            { Remove-RunnerFiles -SshClient $Script:FakeSsh -VmName 'vm-01' `
                -RunnerName 'runner-a' -RunnerDir $Script:RunnerDir
            } | Should -Throw '*Failed to remove runner directory*'
        }
    }
}
