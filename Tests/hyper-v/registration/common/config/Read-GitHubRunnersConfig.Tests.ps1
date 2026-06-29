BeforeAll {
    # Stub Infrastructure.* and helper functions the SUT depends on, so the
    # unit test stays unit-scoped (no Import-Module Common.PowerShell).
    function Get-InfrastructureSecret            { param($VaultName, $SecretName) }
    function ConvertFrom-GitHubRunnersConfigJson { param($Json) }
    function ConvertTo-Array                     { param($Value) ,@($Value) }

    . "$PSScriptRoot\..\..\..\..\..\hyper-v\ubuntu\registration\common\config\Read-GitHubRunnersConfig.ps1"

    # Suffix used by every happy-path call. One literal here means a
    # future rename of the suffix contract only touches one place.
    $script:TestSuffix     = 'Production'
    $script:TestSecretName = "GitHubRunnersConfig-$script:TestSuffix"
}

Describe 'Read-GitHubRunnersConfig' {

    Context 'vault read' {
        It 'calls Get-InfrastructureSecret with the suffixed secret name' {
            Mock Get-InfrastructureSecret { '[]' }
            Mock ConvertFrom-GitHubRunnersConfigJson { }
            Read-GitHubRunnersConfig -SecretSuffix $script:TestSuffix
            $expectedName = $script:TestSecretName
            Should -Invoke Get-InfrastructureSecret -Times 1 -ParameterFilter {
                $VaultName  -eq 'GitHubRunners' -and
                $SecretName -eq $expectedName
            }
        }

        It 'passes the vault JSON to ConvertFrom-GitHubRunnersConfigJson' {
            Mock Get-InfrastructureSecret { '["sentinel"]' }
            Mock ConvertFrom-GitHubRunnersConfigJson { }
            Read-GitHubRunnersConfig -SecretSuffix $script:TestSuffix
            Should -Invoke ConvertFrom-GitHubRunnersConfigJson -Times 1 -ParameterFilter {
                $Json -eq '["sentinel"]'
            }
        }

        It 'returns the entries from ConvertFrom-GitHubRunnersConfigJson' {
            Mock Get-InfrastructureSecret { '[]' }
            Mock ConvertFrom-GitHubRunnersConfigJson {
                [PSCustomObject]@{ runnerName = 'ubuntu-01-ci' }
            }
            $result = @(Read-GitHubRunnersConfig -SecretSuffix $script:TestSuffix)
            $result | Should -HaveCount 1
            $result[0].runnerName | Should -Be 'ubuntu-01-ci'
        }
    }

    Context 'SecretSuffix parameter contract' {

        # Pins the param attributes added alongside the suffix work.
        # Mandatory + ValidateNotNullOrEmpty is the safety guard that
        # prevents a caller from silently falling through to a default
        # name and colliding with another lifecycle's secret.

        BeforeEach {
            Mock Get-InfrastructureSecret { '[]' }
            Mock ConvertFrom-GitHubRunnersConfigJson { }
        }

        It 'rejects missing -SecretSuffix with a ParameterBinding error' {
            { Read-GitHubRunnersConfig } | Should -Throw `
                -ExpectedMessage '*SecretSuffix*'
        }

        It 'rejects an empty -SecretSuffix value (ValidateNotNullOrEmpty)' {
            { Read-GitHubRunnersConfig -SecretSuffix '' } | Should -Throw
        }

        It 'rejects a $null -SecretSuffix value' {
            { Read-GitHubRunnersConfig -SecretSuffix $null } | Should -Throw
        }

        It 'interpolates the suffix into the Get-InfrastructureSecret -SecretName' {
            Read-GitHubRunnersConfig -SecretSuffix 'CI-42'
            Should -Invoke Get-InfrastructureSecret -Times 1 -ParameterFilter {
                $SecretName -eq 'GitHubRunnersConfig-CI-42'
            }
        }
    }
}
