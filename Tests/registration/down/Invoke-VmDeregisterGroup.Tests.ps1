BeforeAll {
    function Get-GitHubRunnerRegistration { param($Pat, $GithubUrl, $RunnerName) }
    function Get-RunnerPaths              { param($RunnerUser, $RunnerName)
        [PSCustomObject] @{ RunnerDir = "/runners/$RunnerName" } }
    function Invoke-RunnerConfigRemove    { param($SshClient, $VmName, $RunnerUser,
                                                  $Entry, $RunnerDir, $Pat) }
    function Remove-RunnerFiles           { param($SshClient, $VmName, $RunnerName, $RunnerDir) }
    function Remove-RunnerService         { param($SshClient, $VmName, $RunnerName, $RunnerDir) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\registration\down\Invoke-VmDeregisterGroup.ps1"

    $Script:FakeSsh = [PSCustomObject] @{}

    function New-Target ([string] $RunnerName, [string] $RunnerUser = 'u-actions-runner') {
        [PSCustomObject] @{
            Entry = [PSCustomObject] @{
                runnerName     = $RunnerName
                runnerUsername = $RunnerUser
                githubUrl      = 'https://github.com/user/repo-a'
            }
            Password = 'secret'
        }
    }
}

Describe 'Invoke-VmDeregisterGroup' {

    Context 'service cleanup' {
        It 'always calls Remove-RunnerService' {
            Mock Remove-RunnerService         {}
            Mock Get-GitHubRunnerRegistration { $null }
            Mock Invoke-RunnerConfigRemove    {}
            Mock Remove-RunnerFiles           {}

            Invoke-VmDeregisterGroup -SshClient $Script:FakeSsh -VmName 'vm-01' `
                -Targets @(New-Target 'runner-a') -Pat 'pat'

            Should -Invoke Remove-RunnerService -Times 1
        }
    }

    Context 'GitHub deregistration' {
        It 'calls Invoke-RunnerConfigRemove when runner is registered on GitHub' {
            Mock Remove-RunnerService         {}
            Mock Get-GitHubRunnerRegistration { [PSCustomObject] @{ id = 1 } }
            Mock Invoke-RunnerConfigRemove    {}
            Mock Remove-RunnerFiles           {}

            Invoke-VmDeregisterGroup -SshClient $Script:FakeSsh -VmName 'vm-01' `
                -Targets @(New-Target 'runner-a') -Pat 'pat'

            Should -Invoke Invoke-RunnerConfigRemove -Times 1
        }

        It 'does not call Invoke-RunnerConfigRemove when runner is absent on GitHub' {
            Mock Remove-RunnerService         {}
            Mock Get-GitHubRunnerRegistration { $null }
            Mock Invoke-RunnerConfigRemove    {}
            Mock Remove-RunnerFiles           {}

            Invoke-VmDeregisterGroup -SshClient $Script:FakeSsh -VmName 'vm-01' `
                -Targets @(New-Target 'runner-a') -Pat 'pat'

            Should -Invoke Invoke-RunnerConfigRemove -Times 0
        }
    }

    Context 'file cleanup' {
        It 'always calls Remove-RunnerFiles' {
            Mock Remove-RunnerService         {}
            Mock Get-GitHubRunnerRegistration { $null }
            Mock Invoke-RunnerConfigRemove    {}
            Mock Remove-RunnerFiles           {}

            Invoke-VmDeregisterGroup -SshClient $Script:FakeSsh -VmName 'vm-01' `
                -Targets @(New-Target 'runner-a') -Pat 'pat'

            Should -Invoke Remove-RunnerFiles -Times 1
        }

        It 'calls Remove-RunnerFiles even when runner is registered on GitHub' {
            Mock Remove-RunnerService         {}
            Mock Get-GitHubRunnerRegistration { [PSCustomObject] @{ id = 1 } }
            Mock Invoke-RunnerConfigRemove    {}
            Mock Remove-RunnerFiles           {}

            Invoke-VmDeregisterGroup -SshClient $Script:FakeSsh -VmName 'vm-01' `
                -Targets @(New-Target 'runner-a') -Pat 'pat'

            Should -Invoke Remove-RunnerFiles -Times 1
        }
    }

    Context 'multiple runners' {
        It 'processes each runner entry independently' {
            Mock Remove-RunnerService         {}
            Mock Get-GitHubRunnerRegistration { $null }
            Mock Invoke-RunnerConfigRemove    {}
            Mock Remove-RunnerFiles           {}

            Invoke-VmDeregisterGroup -SshClient $Script:FakeSsh -VmName 'vm-01' `
                -Targets @(New-Target 'runner-a'; New-Target 'runner-b') -Pat 'pat'

            Should -Invoke Remove-RunnerService -Times 2
            Should -Invoke Remove-RunnerFiles   -Times 2
        }
    }
}
