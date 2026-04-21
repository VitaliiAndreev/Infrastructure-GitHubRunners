BeforeAll {
    function Get-InfrastructureSecret { param($VaultName, $SecretName) }

    . "$PSScriptRoot\..\hyper-v\ubuntu\resolve\Read-VmDeployPasswords.ps1"
}

Describe 'Read-VmDeployPasswords' {

    Context 'vault read and indexing' {
        It 'calls Get-InfrastructureSecret with the correct vault and secret names' {
            Mock Get-InfrastructureSecret { '[{"vmName":"vm1","users":[]}]' }
            Read-VmDeployPasswords
            Should -Invoke Get-InfrastructureSecret -Times 1 -ParameterFilter {
                $VaultName -eq 'VmUsers' -and $SecretName -eq 'VmUsersConfig'
            }
        }

        It 'indexes a user with a password by vmName|username' {
            Mock Get-InfrastructureSecret {
                '[{"vmName":"ubuntu-01","users":[{"username":"u-runner-deploy","password":"s3cr3t"}]}]'
            }
            $result = Read-VmDeployPasswords
            $result['ubuntu-01|u-runner-deploy'] | Should -Be 's3cr3t'
        }

        It 'skips users without a password field' {
            Mock Get-InfrastructureSecret {
                '[{"vmName":"ubuntu-01","users":[{"username":"u-no-pass","shell":"/bin/bash"}]}]'
            }
            $result = Read-VmDeployPasswords
            $result.Count | Should -Be 0
        }

        It 'skips a VM with an empty users array' {
            Mock Get-InfrastructureSecret {
                '[{"vmName":"ubuntu-01","users":[]}]'
            }
            $result = Read-VmDeployPasswords
            $result.Count | Should -Be 0
        }

        It 'indexes multiple users across multiple VMs' {
            Mock Get-InfrastructureSecret {
                @'
[
  {"vmName":"vm-a","users":[{"username":"u-deploy","password":"pa"},{"username":"u-runner","password":"pb"}]},
  {"vmName":"vm-b","users":[{"username":"u-deploy","password":"pc"}]}
]
'@
            }
            $result = Read-VmDeployPasswords
            $result.Count              | Should -Be 3
            $result['vm-a|u-deploy']   | Should -Be 'pa'
            $result['vm-a|u-runner']   | Should -Be 'pb'
            $result['vm-b|u-deploy']   | Should -Be 'pc'
        }

        It 'propagates errors from Get-InfrastructureSecret' {
            Mock Get-InfrastructureSecret { throw 'vault unavailable' }
            { Read-VmDeployPasswords } | Should -Throw -ExpectedMessage '*vault unavailable*'
        }
    }
}
