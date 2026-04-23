BeforeAll {
    function Get-InfrastructureSecret         { param($VaultName, $SecretName) }
    function ConvertFrom-GitHubRunnersConfigJson { param($Json) }

    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\registration\common\config\Read-GitHubRunnersConfig.ps1"
}

Describe 'Read-GitHubRunnersConfig' {

    Context 'vault read' {
        It 'calls Get-InfrastructureSecret with the correct vault and secret names' {
            Mock Get-InfrastructureSecret { '[]' }
            Mock ConvertFrom-GitHubRunnersConfigJson { }
            Read-GitHubRunnersConfig
            Should -Invoke Get-InfrastructureSecret -Times 1 -ParameterFilter {
                $VaultName -eq 'GitHubRunners' -and $SecretName -eq 'GitHubRunnersConfig'
            }
        }

        It 'passes the vault JSON to ConvertFrom-GitHubRunnersConfigJson' {
            Mock Get-InfrastructureSecret { '["sentinel"]' }
            Mock ConvertFrom-GitHubRunnersConfigJson { }
            Read-GitHubRunnersConfig
            Should -Invoke ConvertFrom-GitHubRunnersConfigJson -Times 1 -ParameterFilter {
                $Json -eq '["sentinel"]'
            }
        }

        It 'returns the entries from ConvertFrom-GitHubRunnersConfigJson' {
            Mock Get-InfrastructureSecret { '[]' }
            Mock ConvertFrom-GitHubRunnersConfigJson {
                [PSCustomObject]@{ runnerName = 'ubuntu-01-ci' }
            }
            $result = @(Read-GitHubRunnersConfig)
            $result | Should -HaveCount 1
            $result[0].runnerName | Should -Be 'ubuntu-01-ci'
        }

    }
}
