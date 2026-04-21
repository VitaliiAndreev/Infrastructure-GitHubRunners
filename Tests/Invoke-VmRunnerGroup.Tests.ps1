BeforeAll {
    function Get-RunnerPaths                 { param($RunnerUser, $RunnerVersion, $RunnerName)
        [PSCustomObject] @{ CacheDir = '/cache'; TarPath = '/cache/runner.tar.gz'
                            RunnerDir = "/runners/$RunnerName" } }
    function Invoke-RunnerInstall            { param($SshClient, $VmName, $RunnerEntries, $RunnerVersion) }
    function Get-GitHubRunnerRegistration    { param($Pat, $GithubUrl, $RunnerName) }
    function Test-RunnerServiceActive        { param($SshClient, $VmName, $RunnerName) }
    function Start-RunnerService             { param($SshClient, $VmName, $RunnerName) }
    function New-RunnerRegistrationToken     { param($Pat, $GithubUrl) }
    function Invoke-RunnerRegistration       { param($SshClient, $VmName, $RunnerUser, $Entry, $Token, $RunnerDir) }

    . "$PSScriptRoot\..\hyper-v\ubuntu\Invoke-VmRunnerGroup.ps1"

    $Script:FakeSsh = [PSCustomObject] @{}

    function New-Target ([string] $RunnerName, [string] $RunnerUser = 'u-actions-runner',
                         [string] $GithubUrl = 'https://github.com/user/repo-a') {
        [PSCustomObject] @{
            Entry = [PSCustomObject] @{
                runnerName     = $RunnerName
                runnerUsername = $RunnerUser
                githubUrl      = $GithubUrl
                runnerLabels   = @('self-hosted', 'ubuntu', 'x64')
            }
            Password = 'secret'
        }
    }
}

Describe 'Invoke-VmRunnerGroup' {

    Context 'healthy runner' {
        It 'skips install and registration when runner is registered and service is active' {
            Mock Invoke-RunnerInstall         {}
            Mock Get-GitHubRunnerRegistration { [PSCustomObject] @{ id = 1 } }
            Mock Test-RunnerServiceActive     { $true }
            Mock Invoke-RunnerRegistration    {}
            Mock Start-RunnerService          {}

            Invoke-VmRunnerGroup `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -Targets       @(New-Target 'runner-a') `
                -RunnerVersion '2.317.0' `
                -Pat           'pat'

            Should -Invoke Invoke-RunnerRegistration -Times 0
            Should -Invoke Start-RunnerService       -Times 0
        }
    }

    Context 'registered but service down' {
        It 'restarts the service without re-registering' {
            Mock Invoke-RunnerInstall         {}
            Mock Get-GitHubRunnerRegistration { [PSCustomObject] @{ id = 1 } }
            Mock Test-RunnerServiceActive     { $false }
            Mock Start-RunnerService          {}
            Mock Invoke-RunnerRegistration    {}

            Invoke-VmRunnerGroup `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -Targets       @(New-Target 'runner-a') `
                -RunnerVersion '2.317.0' `
                -Pat           'pat'

            Should -Invoke Start-RunnerService       -Times 1
            Should -Invoke Invoke-RunnerRegistration -Times 0
        }
    }

    Context 'not registered' {
        It 'fetches a token and invokes full registration' {
            Mock Invoke-RunnerInstall         {}
            Mock Get-GitHubRunnerRegistration { $null }
            Mock Test-RunnerServiceActive     { $false }
            Mock New-RunnerRegistrationToken  { 'reg_token' }
            Mock Invoke-RunnerRegistration    {}

            Invoke-VmRunnerGroup `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -Targets       @(New-Target 'runner-a') `
                -RunnerVersion '2.317.0' `
                -Pat           'pat'

            Should -Invoke Invoke-RunnerRegistration -Times 1 -ParameterFilter {
                $RunnerUser -eq 'u-actions-runner' -and $Token -eq 'reg_token'
            }
        }
    }

    Context 'multiple runner users on the same VM' {
        It 'calls Invoke-RunnerInstall once per distinct runner user' {
            Mock Invoke-RunnerInstall         {}
            Mock Get-GitHubRunnerRegistration { [PSCustomObject] @{ id = 1 } }
            Mock Test-RunnerServiceActive     { $true }

            Invoke-VmRunnerGroup `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -Targets       @(New-Target 'runner-a' 'user-one'; New-Target 'runner-b' 'user-two') `
                -RunnerVersion '2.317.0' `
                -Pat           'pat'

            Should -Invoke Invoke-RunnerInstall -Times 2
        }

        It 'passes only the matching entries to each Invoke-RunnerInstall call' {
            Mock Invoke-RunnerInstall         {}
            Mock Get-GitHubRunnerRegistration { [PSCustomObject] @{ id = 1 } }
            Mock Test-RunnerServiceActive     { $true }

            Invoke-VmRunnerGroup `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -Targets       @(New-Target 'runner-a' 'user-one'; New-Target 'runner-b' 'user-two') `
                -RunnerVersion '2.317.0' `
                -Pat           'pat'

            Should -Invoke Invoke-RunnerInstall -Times 1 -ParameterFilter {
                $RunnerEntries.Count -eq 1 -and $RunnerEntries[0].runnerName -eq 'runner-a'
            }
            Should -Invoke Invoke-RunnerInstall -Times 1 -ParameterFilter {
                $RunnerEntries.Count -eq 1 -and $RunnerEntries[0].runnerName -eq 'runner-b'
            }
        }
    }
}
