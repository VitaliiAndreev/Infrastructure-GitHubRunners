BeforeAll {
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\registration\common\github\Get-GitHubRunnerRegistration.ps1"
}

Describe 'Get-GitHubRunnerRegistration' {

    Context 'API request' {
        It 'calls the runners endpoint with the correct URI, headers, and per_page' {
            Mock Invoke-RestMethod { @{ runners = @() } }

            Get-GitHubRunnerRegistration `
                -Pat        'ghp_test' `
                -GithubUrl  'https://github.com/user/repo-a' `
                -RunnerName 'runner-a'

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri -eq 'https://api.github.com/repos/user/repo-a/actions/runners?per_page=100' -and
                $Headers['Authorization'] -eq 'Bearer ghp_test' -and
                $Headers['User-Agent']    -eq 'Infrastructure-GitHubRunners'
            }
        }

        It 'parses owner and repo from a URL with a trailing slash' {
            Mock Invoke-RestMethod { @{ runners = @() } }

            Get-GitHubRunnerRegistration `
                -Pat        'ghp_test' `
                -GithubUrl  'https://github.com/user/repo-a/' `
                -RunnerName 'runner-a'

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri -like '*repos/user/repo-a/actions/runners*'
            }
        }
    }

    Context 'return value' {
        It 'returns the matching runner object when the runner is registered' {
            Mock Invoke-RestMethod {
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
            Mock Invoke-RestMethod {
                [PSCustomObject]@{ runners = @([PSCustomObject]@{ name = 'other-runner'; id = 1 }) }
            }

            $result = Get-GitHubRunnerRegistration `
                -Pat        'ghp_test' `
                -GithubUrl  'https://github.com/user/repo-a' `
                -RunnerName 'runner-a'

            $result | Should -BeNullOrEmpty
        }

        It 'returns $null when the runners list is empty' {
            Mock Invoke-RestMethod { [PSCustomObject]@{ runners = @() } }

            $result = Get-GitHubRunnerRegistration `
                -Pat        'ghp_test' `
                -GithubUrl  'https://github.com/user/repo-a' `
                -RunnerName 'runner-a'

            $result | Should -BeNullOrEmpty
        }

        It 'returns $null when the response has no runners property' {
            Mock Invoke-RestMethod { [PSCustomObject]@{} }

            $result = Get-GitHubRunnerRegistration `
                -Pat        'ghp_test' `
                -GithubUrl  'https://github.com/user/repo-a' `
                -RunnerName 'runner-a'

            $result | Should -BeNullOrEmpty
        }

        It 'returns only the first match when multiple runners share the same name' {
            Mock Invoke-RestMethod {
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
