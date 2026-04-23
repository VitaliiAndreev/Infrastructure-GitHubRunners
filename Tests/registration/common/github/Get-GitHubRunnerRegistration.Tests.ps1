BeforeAll {
    function Invoke-GitHubRunnersApi { param($Pat, $GithubUrl, $Suffix, $Method) }

    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\registration\common\github\Get-GitHubRunnerRegistration.ps1"
}

Describe 'Get-GitHubRunnerRegistration' {

    Context 'API request' {
        It 'queries the runners collection with per_page=100' {
            Mock Invoke-GitHubRunnersApi { [PSCustomObject] @{ runners = @() } }

            Get-GitHubRunnerRegistration `
                -Pat        'ghp_test' `
                -GithubUrl  'https://github.com/user/repo-a' `
                -RunnerName 'runner-a'

            Should -Invoke Invoke-GitHubRunnersApi -Times 1 -ParameterFilter {
                $Suffix -eq '?per_page=100'
            }
        }
    }

    Context 'return value' {
        It 'returns the matching runner object when the runner is registered' {
            Mock Invoke-GitHubRunnersApi {
                [PSCustomObject]@{ runners = @(
                    [PSCustomObject]@{ name = 'other-runner'; id = 1 },
                    [PSCustomObject]@{ name = 'runner-a';    id = 2 }
                )}
            }

            $result = Get-GitHubRunnerRegistration `
                -Pat        'ghp_test' `
                -GithubUrl  'https://github.com/user/repo-a' `
                -RunnerName 'runner-a'

            $result.id | Should -Be 2
        }

        It 'returns $null when the runner is not in the list' {
            Mock Invoke-GitHubRunnersApi {
                [PSCustomObject]@{ runners = @([PSCustomObject]@{ name = 'other-runner'; id = 1 }) }
            }

            $result = Get-GitHubRunnerRegistration `
                -Pat        'ghp_test' `
                -GithubUrl  'https://github.com/user/repo-a' `
                -RunnerName 'runner-a'

            $result | Should -BeNullOrEmpty
        }

        It 'returns $null when the runners list is empty' {
            Mock Invoke-GitHubRunnersApi { [PSCustomObject]@{ runners = @() } }

            $result = Get-GitHubRunnerRegistration `
                -Pat        'ghp_test' `
                -GithubUrl  'https://github.com/user/repo-a' `
                -RunnerName 'runner-a'

            $result | Should -BeNullOrEmpty
        }

        It 'returns $null when the response has no runners property' {
            Mock Invoke-GitHubRunnersApi { [PSCustomObject]@{} }

            $result = Get-GitHubRunnerRegistration `
                -Pat        'ghp_test' `
                -GithubUrl  'https://github.com/user/repo-a' `
                -RunnerName 'runner-a'

            $result | Should -BeNullOrEmpty
        }

        It 'returns only the first match when multiple runners share the same name' {
            Mock Invoke-GitHubRunnersApi {
                [PSCustomObject]@{ runners = @(
                    [PSCustomObject]@{ name = 'runner-a'; id = 1 },
                    [PSCustomObject]@{ name = 'runner-a'; id = 2 }
                )}
            }

            $result = Get-GitHubRunnerRegistration `
                -Pat        'ghp_test' `
                -GithubUrl  'https://github.com/user/repo-a' `
                -RunnerName 'runner-a'

            @($result).Count | Should -Be 1
            $result.id       | Should -Be 1
        }
    }
}
