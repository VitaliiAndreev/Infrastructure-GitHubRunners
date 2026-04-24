BeforeAll {
    function Get-RunnerServiceName   { param($SshClient, $RunnerName) }
    function Invoke-SshClientCommand { param($SshClient, $Command, $ErrorAction) }
    function Test-RunnerServiceActive { param($SshClient, $VmName, $RunnerName) }

    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\registration\down\service\Remove-RunnerService.ps1"

    $Script:FakeSsh    = [PSCustomObject] @{}
    $Script:RunnerDir  = '/home/u-actions-runner/runners/runner-a'
    $Script:ServiceOk  = [PSCustomObject] @{ ExitStatus = 0; Error = '' }
}

Describe 'Remove-RunnerService' {

    Context 'stop step' {
        It 'stops the service when it is active' {
            Mock Test-RunnerServiceActive { $true }
            Mock Get-RunnerServiceName    { 'actions.runner.user-repo.runner-a.service' }
            Mock Invoke-SshClientCommand  { $Script:ServiceOk }

            Remove-RunnerService -SshClient $Script:FakeSsh -VmName 'vm-01' `
                -RunnerName 'runner-a' -RunnerDir $Script:RunnerDir

            Should -Invoke Invoke-SshClientCommand -Times 1 -ParameterFilter {
                $Command -like "*systemctl stop 'actions.runner.user-repo.runner-a.service'*"
            }
        }

        It 'does not stop the service when it is already inactive' {
            Mock Test-RunnerServiceActive { $false }
            Mock Get-RunnerServiceName    { 'actions.runner.user-repo.runner-a.service' }
            Mock Invoke-SshClientCommand  { $Script:ServiceOk }

            Remove-RunnerService -SshClient $Script:FakeSsh -VmName 'vm-01' `
                -RunnerName 'runner-a' -RunnerDir $Script:RunnerDir

            Should -Invoke Invoke-SshClientCommand -Times 0 -ParameterFilter {
                $Command -like '*systemctl stop*'
            }
        }

        It 'throws when systemctl stop fails' {
            Mock Test-RunnerServiceActive { $true }
            Mock Get-RunnerServiceName    { 'actions.runner.user-repo.runner-a.service' }
            Mock Invoke-SshClientCommand  {
                param($SshClient, $Command)
                $exit = if ($Command -like '*systemctl stop*') { 1 } else { 0 }
                [PSCustomObject] @{ ExitStatus = $exit; Error = 'stop error' }
            }

            { Remove-RunnerService -SshClient $Script:FakeSsh -VmName 'vm-01' `
                -RunnerName 'runner-a' -RunnerDir $Script:RunnerDir
            } | Should -Throw '*systemctl stop failed*'
        }
    }

    Context 'uninstall step' {
        It 'uninstalls the unit when it is installed' {
            Mock Test-RunnerServiceActive { $false }
            Mock Get-RunnerServiceName    { 'actions.runner.user-repo.runner-a.service' }
            Mock Invoke-SshClientCommand  { $Script:ServiceOk }

            Remove-RunnerService -SshClient $Script:FakeSsh -VmName 'vm-01' `
                -RunnerName 'runner-a' -RunnerDir $Script:RunnerDir

            Should -Invoke Invoke-SshClientCommand -Times 1 -ParameterFilter {
                $Command -like "*cd '$($Script:RunnerDir)'*svc.sh' uninstall*"
            }
        }

        It 'runs svc.sh uninstall from the runner directory' {
            Mock Test-RunnerServiceActive { $false }
            Mock Get-RunnerServiceName    { 'actions.runner.user-repo.runner-a.service' }
            Mock Invoke-SshClientCommand  { $Script:ServiceOk }

            Remove-RunnerService -SshClient $Script:FakeSsh -VmName 'vm-01' `
                -RunnerName 'runner-a' -RunnerDir $Script:RunnerDir

            Should -Invoke Invoke-SshClientCommand -Times 1 -ParameterFilter {
                $Command -like "cd '$($Script:RunnerDir)' &&*"
            }
        }

        It 'skips uninstall when the unit is absent' {
            Mock Test-RunnerServiceActive { $false }
            Mock Get-RunnerServiceName    { $null }
            Mock Invoke-SshClientCommand  { $Script:ServiceOk }

            Remove-RunnerService -SshClient $Script:FakeSsh -VmName 'vm-01' `
                -RunnerName 'runner-a' -RunnerDir $Script:RunnerDir

            Should -Invoke Invoke-SshClientCommand -Times 0
        }

        It 'throws when svc.sh uninstall fails' {
            Mock Test-RunnerServiceActive { $false }
            Mock Get-RunnerServiceName    { 'actions.runner.user-repo.runner-a.service' }
            Mock Invoke-SshClientCommand  {
                [PSCustomObject] @{ ExitStatus = 1; Error = 'uninstall error' }
            }

            { Remove-RunnerService -SshClient $Script:FakeSsh -VmName 'vm-01' `
                -RunnerName 'runner-a' -RunnerDir $Script:RunnerDir
            } | Should -Throw '*svc.sh uninstall failed*'
        }
    }
}
