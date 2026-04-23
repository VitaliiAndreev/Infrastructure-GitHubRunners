BeforeAll {
    function Invoke-SshClientCommand  { param($SshClient, $Command, $ErrorAction) }
    function Test-RunnerServiceActive { param($SshClient, $VmName, $RunnerName) }

    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\registration\up\registration\Invoke-RunnerRegistration.ps1"

    $Script:FakeSsh   = [PSCustomObject] @{}
    $Script:RunnerDir = '/home/u-actions-runner/runners/runner-a'

    function New-Entry ([string] $RunnerName, [string[]] $Labels = @('self-hosted','ubuntu','x64')) {
        [PSCustomObject] @{
            runnerName   = $RunnerName
            runnerLabels = $Labels
            githubUrl    = 'https://github.com/user/repo-a'
        }
    }
}

Describe 'Invoke-RunnerRegistration' {

    Context 'config.sh' {
        It 'runs config.sh as the runner user with the correct arguments' {
            Mock Invoke-SshClientCommand { [PSCustomObject] @{ ExitStatus = 0; Error = '' } }
            Mock Test-RunnerServiceActive { $true }

            Invoke-RunnerRegistration `
                -SshClient  $Script:FakeSsh `
                -VmName     'vm-01' `
                -RunnerUser 'u-actions-runner' `
                -Entry      (New-Entry 'runner-a') `
                -Token      'reg_token' `
                -RunnerDir  $Script:RunnerDir

            Should -Invoke Invoke-SshClientCommand -Times 1 -ParameterFilter {
                $Command -like "*sudo -u u-actions-runner*config.sh*" -and
                $Command -like "*--url 'https://github.com/user/repo-a'*" -and
                $Command -like "*--name 'runner-a'*" -and
                $Command -like "*--labels 'self-hosted,ubuntu,x64'*" -and
                $Command -like "*--unattended*"
            }
        }

        It 'throws when config.sh fails' {
            Mock Invoke-SshClientCommand {
                param($SshClient, $Command)
                $exit = if ($Command -like '*config.sh*') { 1 } else { 0 }
                [PSCustomObject] @{ ExitStatus = $exit; Error = 'auth error' }
            }
            Mock Test-RunnerServiceActive { $true }

            { Invoke-RunnerRegistration `
                -SshClient  $Script:FakeSsh `
                -VmName     'vm-01' `
                -RunnerUser 'u-actions-runner' `
                -Entry      (New-Entry 'runner-a') `
                -Token      'reg_token' `
                -RunnerDir  $Script:RunnerDir
            } | Should -Throw '*config.sh failed*'
        }

        It 'throws when Token is empty and -SkipConfig is not set' {
            { Invoke-RunnerRegistration `
                -SshClient  $Script:FakeSsh `
                -VmName     'vm-01' `
                -RunnerUser 'u-actions-runner' `
                -Entry      (New-Entry 'runner-a') `
                -RunnerDir  $Script:RunnerDir
            } | Should -Throw '*Token is required*'
        }
    }

    Context '-SkipConfig' {
        It 'does not call config.sh when -SkipConfig is set' {
            Mock Invoke-SshClientCommand { [PSCustomObject] @{ ExitStatus = 0; Error = '' } }
            Mock Test-RunnerServiceActive { $true }

            Invoke-RunnerRegistration `
                -SshClient  $Script:FakeSsh `
                -VmName     'vm-01' `
                -RunnerUser 'u-actions-runner' `
                -Entry      (New-Entry 'runner-a') `
                -RunnerDir  $Script:RunnerDir `
                -SkipConfig

            Should -Invoke Invoke-SshClientCommand -Times 0 -ParameterFilter {
                $Command -like '*config.sh*'
            }
        }

        It 'still installs and starts the service when -SkipConfig is set' {
            Mock Invoke-SshClientCommand { [PSCustomObject] @{ ExitStatus = 0; Error = '' } }
            Mock Test-RunnerServiceActive { $true }

            Invoke-RunnerRegistration `
                -SshClient  $Script:FakeSsh `
                -VmName     'vm-01' `
                -RunnerUser 'u-actions-runner' `
                -Entry      (New-Entry 'runner-a') `
                -RunnerDir  $Script:RunnerDir `
                -SkipConfig

            Should -Invoke Invoke-SshClientCommand -Times 1 -ParameterFilter {
                $Command -like "*svc.sh' install 'u-actions-runner'*"
            }
            Should -Invoke Invoke-SshClientCommand -Times 1 -ParameterFilter {
                $Command -like "*svc.sh' start*"
            }
        }
    }

    Context 'svc.sh' {
        It 'installs the service with the runner user as argument' {
            Mock Invoke-SshClientCommand { [PSCustomObject] @{ ExitStatus = 0; Error = '' } }
            Mock Test-RunnerServiceActive { $true }

            Invoke-RunnerRegistration `
                -SshClient  $Script:FakeSsh `
                -VmName     'vm-01' `
                -RunnerUser 'u-actions-runner' `
                -Entry      (New-Entry 'runner-a') `
                -Token      'reg_token' `
                -RunnerDir  $Script:RunnerDir

            Should -Invoke Invoke-SshClientCommand -Times 1 -ParameterFilter {
                $Command -like "*svc.sh' install 'u-actions-runner'*"
            }
        }

        It 'starts the service after install' {
            Mock Invoke-SshClientCommand { [PSCustomObject] @{ ExitStatus = 0; Error = '' } }
            Mock Test-RunnerServiceActive { $true }

            Invoke-RunnerRegistration `
                -SshClient  $Script:FakeSsh `
                -VmName     'vm-01' `
                -RunnerUser 'u-actions-runner' `
                -Entry      (New-Entry 'runner-a') `
                -Token      'reg_token' `
                -RunnerDir  $Script:RunnerDir

            Should -Invoke Invoke-SshClientCommand -Times 1 -ParameterFilter {
                $Command -like "*svc.sh' start*"
            }
        }

        It 'throws when svc.sh install fails' {
            Mock Invoke-SshClientCommand {
                param($SshClient, $Command)
                $exit = if ($Command -like '*svc.sh* install*') { 1 } else { 0 }
                [PSCustomObject] @{ ExitStatus = $exit; Error = 'install error' }
            }
            Mock Test-RunnerServiceActive { $true }

            { Invoke-RunnerRegistration `
                -SshClient  $Script:FakeSsh `
                -VmName     'vm-01' `
                -RunnerUser 'u-actions-runner' `
                -Entry      (New-Entry 'runner-a') `
                -Token      'reg_token' `
                -RunnerDir  $Script:RunnerDir
            } | Should -Throw '*svc.sh install failed*'
        }

        It 'throws when svc.sh start fails' {
            Mock Invoke-SshClientCommand {
                param($SshClient, $Command)
                $exit = if ($Command -like "*svc.sh' start*") { 1 } else { 0 }
                [PSCustomObject] @{ ExitStatus = $exit; Error = 'start error' }
            }
            Mock Test-RunnerServiceActive { $true }

            { Invoke-RunnerRegistration `
                -SshClient  $Script:FakeSsh `
                -VmName     'vm-01' `
                -RunnerUser 'u-actions-runner' `
                -Entry      (New-Entry 'runner-a') `
                -Token      'reg_token' `
                -RunnerDir  $Script:RunnerDir
            } | Should -Throw '*svc.sh start failed*'
        }
    }

    Context 'post-start verification' {
        It 'writes an error when service is not active after registration' {
            Mock Invoke-SshClientCommand { [PSCustomObject] @{ ExitStatus = 0; Error = '' } }
            Mock Test-RunnerServiceActive { $false }
            Mock Write-Error { }

            Invoke-RunnerRegistration `
                -SshClient  $Script:FakeSsh `
                -VmName     'vm-01' `
                -RunnerUser 'u-actions-runner' `
                -Entry      (New-Entry 'runner-a') `
                -Token      'reg_token' `
                -RunnerDir  $Script:RunnerDir

            Should -Invoke Write-Error -Times 1
        }
    }
}
