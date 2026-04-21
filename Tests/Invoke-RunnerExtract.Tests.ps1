BeforeAll {
    function Invoke-SshClientCommand {
        param($SshClient, $Command, $ErrorAction)
    }

    . "$PSScriptRoot\..\hyper-v\ubuntu\install\Invoke-RunnerExtract.ps1"

    $Script:FakeSsh = [PSCustomObject] @{}
}

Describe 'Invoke-RunnerExtract' {

    Context 'runner directory already exists' {
        It 'skips mkdir and tar when the runner directory is present' {
            Mock Invoke-SshClientCommand { [PSCustomObject] @{ ExitStatus = 0; Error = '' } }

            Invoke-RunnerExtract `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -RunnerUser    'u-actions-runner' `
                -RunnerVersion '2.317.0' `
                -RunnerName    'runner-a'

            Should -Invoke Invoke-SshClientCommand -Times 0 -ParameterFilter {
                $Command -like '*tar -xzf*'
            }
            Should -Invoke Invoke-SshClientCommand -Times 0 -ParameterFilter {
                $Command -like '*mkdir*runner-a*'
            }
        }
    }

    Context 'runner directory absent' {
        BeforeEach {
            Mock Invoke-SshClientCommand {
                param($SshClient, $Command)
                $exit = if ($Command -like 'test -d*') { 1 } else { 0 }
                [PSCustomObject] @{ ExitStatus = $exit; Error = '' }
            }
        }

        It 'creates the runner directory as the runner user' {
            Invoke-RunnerExtract `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -RunnerUser    'u-actions-runner' `
                -RunnerVersion '2.317.0' `
                -RunnerName    'runner-a'

            Should -Invoke Invoke-SshClientCommand -Times 1 -ParameterFilter {
                $Command -like "sudo -u u-actions-runner mkdir -p '/home/u-actions-runner/runners/runner-a'"
            }
        }

        It 'extracts the tarball into the runner directory' {
            Invoke-RunnerExtract `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -RunnerUser    'u-actions-runner' `
                -RunnerVersion '2.317.0' `
                -RunnerName    'runner-a'

            Should -Invoke Invoke-SshClientCommand -Times 1 -ParameterFilter {
                $Command -like ("sudo -u u-actions-runner tar -xzf " +
                    "'/home/u-actions-runner/cache/actions-runner-linux-x64-2.317.0.tar.gz'" +
                    " -C '/home/u-actions-runner/runners/runner-a'")
            }
        }

        It 'throws when mkdir fails' {
            Mock Invoke-SshClientCommand {
                param($SshClient, $Command)
                $exit = if ($Command -like 'test -d*') { 1 }
                        elseif ($Command -like '*mkdir*') { 1 }
                        else { 0 }
                [PSCustomObject] @{ ExitStatus = $exit; Error = 'permission denied' }
            }

            { Invoke-RunnerExtract `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -RunnerUser    'u-actions-runner' `
                -RunnerVersion '2.317.0' `
                -RunnerName    'runner-a'
            } | Should -Throw '*Failed to create runner directory*'
        }

        It 'throws when tar fails' {
            Mock Invoke-SshClientCommand {
                param($SshClient, $Command)
                $exit = if ($Command -like 'test -d*') { 1 }
                        elseif ($Command -like '*tar -xzf*') { 1 }
                        else { 0 }
                [PSCustomObject] @{ ExitStatus = $exit; Error = 'bad archive' }
            }

            { Invoke-RunnerExtract `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -RunnerUser    'u-actions-runner' `
                -RunnerVersion '2.317.0' `
                -RunnerName    'runner-a'
            } | Should -Throw '*tar extraction failed*'
        }
    }
}
