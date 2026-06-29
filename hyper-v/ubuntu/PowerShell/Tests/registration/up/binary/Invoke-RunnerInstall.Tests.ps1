BeforeAll {
    function Get-RunnerPaths             { param($RunnerUser, $RunnerVersion, $RunnerName)
        [PSCustomObject] @{ CacheDir = '/cache'; TarPath = '/cache/runner.tar.gz'
                            RunnerDir = "/runners/$RunnerName" } }
    function Invoke-RunnerTarballDeploy  { param($SshClient, $TarUrl, $RunnerUser, $CacheDir, $Label) }
    function Invoke-RunnerExtract        { param($SshClient, $VmName, $RunnerUser, $RunnerVersion, $RunnerName, $RunnerDir, $TarPath) }

    . "$PSScriptRoot\..\..\..\..\registration\up\binary\Invoke-RunnerInstall.ps1"

    $Script:FakeSsh = [PSCustomObject] @{}

    function New-Entry ([string] $RunnerName, [string] $RunnerUser = 'u-actions-runner') {
        [PSCustomObject] @{ runnerName = $RunnerName; runnerUsername = $RunnerUser }
    }
}

Describe 'Invoke-RunnerInstall' {

    Context 'host base URL forwarding' {
        It 'uses the host URL when HostBaseUrl is provided' {
            Mock Invoke-RunnerTarballDeploy {}
            Mock Invoke-RunnerExtract       {}

            Invoke-RunnerInstall `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -RunnerEntries @(New-Entry 'runner-a') `
                -RunnerVersion '2.317.0' `
                -HostBaseUrl   'http://10.10.0.1:8745'

            Should -Invoke Invoke-RunnerTarballDeploy -Times 1 -ParameterFilter {
                $TarUrl -like 'http://10.10.0.1:8745/*'
            }
        }

        It 'uses the GitHub URL when HostBaseUrl is empty' {
            Mock Invoke-RunnerTarballDeploy {}
            Mock Invoke-RunnerExtract       {}

            Invoke-RunnerInstall `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -RunnerEntries @(New-Entry 'runner-a') `
                -RunnerVersion '2.317.0'

            Should -Invoke Invoke-RunnerTarballDeploy -Times 1 -ParameterFilter {
                $TarUrl -like 'https://github.com/actions/runner/*'
            }
        }
    }

    Context 'tarball deployment' {
        It 'deploys once with the correct runner user, version URL, and label' {
            Mock Invoke-RunnerTarballDeploy {}
            Mock Invoke-RunnerExtract       {}

            Invoke-RunnerInstall `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -RunnerEntries @(New-Entry 'runner-a') `
                -RunnerVersion '2.317.0'

            Should -Invoke Invoke-RunnerTarballDeploy -Times 1 -ParameterFilter {
                $TarUrl     -like '*2.317.0*'  -and
                $RunnerUser -eq 'u-actions-runner' -and
                $Label      -eq 'vm-01'
            }
        }

        It 'deploys once even for multiple runner entries' {
            Mock Invoke-RunnerTarballDeploy {}
            Mock Invoke-RunnerExtract       {}

            Invoke-RunnerInstall `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -RunnerEntries @(New-Entry 'runner-a'; New-Entry 'runner-b') `
                -RunnerVersion '2.317.0'

            Should -Invoke Invoke-RunnerTarballDeploy -Times 1
        }
    }

    Context 'runner extraction' {
        It 'calls Invoke-RunnerExtract once per entry' {
            Mock Invoke-RunnerTarballDeploy {}
            Mock Invoke-RunnerExtract       {}

            Invoke-RunnerInstall `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -RunnerEntries @(New-Entry 'runner-a'; New-Entry 'runner-b') `
                -RunnerVersion '2.317.0'

            Should -Invoke Invoke-RunnerExtract -Times 2
        }

        It 'passes the correct runner name and version to each Invoke-RunnerExtract call' {
            Mock Invoke-RunnerTarballDeploy {}
            Mock Invoke-RunnerExtract       {}

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
            Mock Invoke-RunnerTarballDeploy {}
            Mock Invoke-RunnerExtract       {}

            Invoke-RunnerInstall `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -RunnerEntries @(New-Entry 'runner-a' 'svc-runner') `
                -RunnerVersion '2.317.0'

            Should -Invoke Invoke-RunnerTarballDeploy -Times 1 -ParameterFilter {
                $RunnerUser -eq 'svc-runner'
            }
            Should -Invoke Invoke-RunnerExtract -Times 1 -ParameterFilter {
                $RunnerUser -eq 'svc-runner'
            }
        }

        It 'throws when entries on the same VM have different runnerUsername values' {
            Mock Invoke-RunnerTarballDeploy {}
            Mock Invoke-RunnerExtract       {}

            { Invoke-RunnerInstall `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -RunnerEntries @(New-Entry 'runner-a' 'user-one'; New-Entry 'runner-b' 'user-two') `
                -RunnerVersion '2.317.0'
            } | Should -Throw '*All runner entries on a VM must share the same runnerUsername*'
        }
    }
}
