BeforeAll {
    function Get-InfrastructureSecret { param($VaultName, $SecretName) }

    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\registration\common\config\Read-VmDeployPasswords.ps1"

    $script:TestSuffix     = 'Production'
    $script:TestSecretName = "VmUsersConfig-$script:TestSuffix"
}

Describe 'Read-VmDeployPasswords' {

    Context 'vault read and indexing' {
        It 'calls Get-InfrastructureSecret with the suffixed secret name' {
            Mock Get-InfrastructureSecret { '[{"vmName":"vm1","users":[]}]' }
            Read-VmDeployPasswords -SecretSuffix $script:TestSuffix | Out-Null
            $expectedName = $script:TestSecretName
            Should -Invoke Get-InfrastructureSecret -Times 1 -ParameterFilter {
                $VaultName  -eq 'VmUsers' -and
                $SecretName -eq $expectedName
            }
        }

        It 'indexes a user with a password by vmName|username' {
            Mock Get-InfrastructureSecret {
                '[{"vmName":"ubuntu-01","users":[{"username":"u-runner-deploy","password":"s3cr3t"}]}]'
            }
            $result = Read-VmDeployPasswords -SecretSuffix $script:TestSuffix
            $result['ubuntu-01|u-runner-deploy'] | Should -Be 's3cr3t'
        }

        It 'skips users without a password field' {
            Mock Get-InfrastructureSecret {
                '[{"vmName":"ubuntu-01","users":[{"username":"u-no-pass","shell":"/bin/bash"}]}]'
            }
            $result = Read-VmDeployPasswords -SecretSuffix $script:TestSuffix
            $result.Count | Should -Be 0
        }

        It 'skips a VM with an empty users array' {
            Mock Get-InfrastructureSecret {
                '[{"vmName":"ubuntu-01","users":[]}]'
            }
            $result = Read-VmDeployPasswords -SecretSuffix $script:TestSuffix
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
            $result = Read-VmDeployPasswords -SecretSuffix $script:TestSuffix
            $result.Count              | Should -Be 3
            $result['vm-a|u-deploy']   | Should -Be 'pa'
            $result['vm-a|u-runner']   | Should -Be 'pb'
            $result['vm-b|u-deploy']   | Should -Be 'pc'
        }

        It 'skips a VM entry where the users property is absent' {
            Mock Get-InfrastructureSecret {
                '[{"vmName":"ubuntu-01"}]'
            }
            $result = Read-VmDeployPasswords -SecretSuffix $script:TestSuffix
            $result.Count | Should -Be 0
        }
    }

    Context 'SecretSuffix parameter contract' {

        # See Read-GitHubRunnersConfig.Tests.ps1 for the rationale.

        BeforeEach {
            Mock Get-InfrastructureSecret { '[]' }
        }

        It 'rejects missing -SecretSuffix with a ParameterBinding error' {
            { Read-VmDeployPasswords } | Should -Throw `
                -ExpectedMessage '*SecretSuffix*'
        }

        It 'rejects an empty -SecretSuffix value (ValidateNotNullOrEmpty)' {
            { Read-VmDeployPasswords -SecretSuffix '' } | Should -Throw
        }

        It 'rejects a $null -SecretSuffix value' {
            { Read-VmDeployPasswords -SecretSuffix $null } | Should -Throw
        }

        It 'interpolates the suffix into the Get-InfrastructureSecret -SecretName' {
            Read-VmDeployPasswords -SecretSuffix 'CI-42' | Out-Null
            Should -Invoke Get-InfrastructureSecret -Times 1 -ParameterFilter {
                $SecretName -eq 'VmUsersConfig-CI-42'
            }
        }
    }
}
