BeforeAll {
    function Invoke-SshClientCommand { param($SshClient, $Command, $ErrorAction) }

    . "$PSScriptRoot\..\..\..\..\registration\down\binary\Remove-RunnerFiles.ps1"

    $Script:FakeSsh   = [PSCustomObject] @{}
    $Script:RunnerDir = '/opt/runners/runner-a'
}

Describe 'Remove-RunnerFiles' {

    Context 'directory removal' {
        It 'issues sudo rm -rf for the runner directory when present' {
            Mock Invoke-SshClientCommand { [PSCustomObject] @{ ExitStatus = 0; Error = '' } }

            Remove-RunnerFiles -SshClient $Script:FakeSsh -VmName 'vm-01' `
                -RunnerName 'runner-a' -RunnerDir $Script:RunnerDir

            Should -Invoke Invoke-SshClientCommand -Times 1 -ParameterFilter {
                $Command -eq "sudo rm -rf '$($Script:RunnerDir)'"
            }
        }

        It 'skips removal and does not throw when the directory is already absent' {
            # test -d returns 1 when the directory is missing - no rm should run.
            Mock Invoke-SshClientCommand {
                [PSCustomObject] @{ ExitStatus = 1; Error = '' }
            }

            { Remove-RunnerFiles -SshClient $Script:FakeSsh -VmName 'vm-01' `
                -RunnerName 'runner-a' -RunnerDir $Script:RunnerDir
            } | Should -Not -Throw

            Should -Invoke Invoke-SshClientCommand -Times 0 -ParameterFilter {
                $Command -like 'sudo rm*'
            }
        }

        It 'throws when the rm command fails (e.g. sudoers misconfiguration)' {
            # Probe succeeds (dir present), rm fails. The earlier '|| true' form
            # silently swallowed this; the regression guard ensures we surface it.
            Mock Invoke-SshClientCommand {
                param($SshClient, $Command)
                if ($Command -like 'sudo rm*') {
                    [PSCustomObject] @{ ExitStatus = 1; Error = 'permission denied' }
                } else {
                    [PSCustomObject] @{ ExitStatus = 0; Error = '' }
                }
            }

            { Remove-RunnerFiles -SshClient $Script:FakeSsh -VmName 'vm-01' `
                -RunnerName 'runner-a' -RunnerDir $Script:RunnerDir
            } | Should -Throw '*Failed to remove runner directory*'
        }
    }
}
