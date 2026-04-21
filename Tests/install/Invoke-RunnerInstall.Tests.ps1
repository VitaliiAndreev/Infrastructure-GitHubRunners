BeforeAll {
    function Get-RunnerPaths        { param($RunnerUser, $RunnerVersion, $RunnerName)
        [PSCustomObject] @{ CacheDir = '/cache'; TarPath = '/cache/runner.tar.gz'
                            RunnerDir = "/runners/$RunnerName" } }
    function Invoke-TarballDownload { param($SshClient, $VmName, $RunnerUser, $RunnerVersion, $CacheDir, $TarPath) }
    function Invoke-RunnerExtract   { param($SshClient, $VmName, $RunnerUser, $RunnerVersion, $RunnerName, $RunnerDir, $TarPath) }

    . "$PSScriptRoot\..\..\hyper-v\ubuntu\install\Invoke-RunnerInstall.ps1"

    $Script:FakeSsh = [PSCustomObject] @{}

    function New-Entry ([string] $RunnerName, [string] $RunnerUser = 'u-actions-runner') {
        [PSCustomObject] @{ runnerName = $RunnerName; runnerUsername = $RunnerUser }
    }
}

Describe 'Invoke-RunnerInstall' {

    Context 'tarball download' {
        It 'calls Invoke-TarballDownload once with the runner user and version' {
            Mock Invoke-TarballDownload {}
            Mock Invoke-RunnerExtract   {}

            Invoke-RunnerInstall `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -RunnerEntries @(New-Entry 'runner-a') `
                -RunnerVersion '2.317.0'

            Should -Invoke Invoke-TarballDownload -Times 1 -ParameterFilter {
                $VmName        -eq 'vm-01'          -and
                $RunnerUser    -eq 'u-actions-runner' -and
                $RunnerVersion -eq '2.317.0'
            }
        }

        It 'calls Invoke-TarballDownload once even for multiple runner entries' {
            Mock Invoke-TarballDownload {}
            Mock Invoke-RunnerExtract   {}

            Invoke-RunnerInstall `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -RunnerEntries @(New-Entry 'runner-a'; New-Entry 'runner-b') `
                -RunnerVersion '2.317.0'

            Should -Invoke Invoke-TarballDownload -Times 1
        }
    }

    Context 'runner extraction' {
        It 'calls Invoke-RunnerExtract once per entry' {
            Mock Invoke-TarballDownload {}
            Mock Invoke-RunnerExtract   {}

            Invoke-RunnerInstall `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -RunnerEntries @(New-Entry 'runner-a'; New-Entry 'runner-b') `
                -RunnerVersion '2.317.0'

            Should -Invoke Invoke-RunnerExtract -Times 2
        }

        It 'passes the correct runner name and version to each Invoke-RunnerExtract call' {
            Mock Invoke-TarballDownload {}
            Mock Invoke-RunnerExtract   {}

            Invoke-RunnerInstall `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -RunnerEntries @(New-Entry 'runner-a'; New-Entry 'runner-b') `
                -RunnerVersion '2.317.0'

            Should -Invoke Invoke-RunnerExtract -Times 1 -ParameterFilter {
                $RunnerName -eq 'runner-a' -and $RunnerVersion -eq '2.317.0'
            }
            Should -Invoke Invoke-RunnerExtract -Times 1 -ParameterFilter {
                $RunnerName -eq 'runner-b' -and $RunnerVersion -eq '2.317.0'
            }
        }
    }

    Context 'runner user derivation' {
        It 'derives the runner user from the entries' {
            Mock Invoke-TarballDownload {}
            Mock Invoke-RunnerExtract   {}

            Invoke-RunnerInstall `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -RunnerEntries @(New-Entry 'runner-a' 'svc-runner') `
                -RunnerVersion '2.317.0'

            Should -Invoke Invoke-TarballDownload -Times 1 -ParameterFilter {
                $RunnerUser -eq 'svc-runner'
            }
            Should -Invoke Invoke-RunnerExtract -Times 1 -ParameterFilter {
                $RunnerUser -eq 'svc-runner'
            }
        }

        It 'throws when entries on the same VM have different runnerUsername values' {
            Mock Invoke-TarballDownload {}
            Mock Invoke-RunnerExtract   {}

            { Invoke-RunnerInstall `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -RunnerEntries @(New-Entry 'runner-a' 'user-one'; New-Entry 'runner-b' 'user-two') `
                -RunnerVersion '2.317.0'
            } | Should -Throw '*All runner entries on a VM must share the same runnerUsername*'
        }
    }
}
