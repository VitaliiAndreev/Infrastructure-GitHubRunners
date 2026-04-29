BeforeAll {
    function Invoke-GitHubApi { param($Token, $Endpoint, $Uri, $Method) }

    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\registration\common\github\Get-GitHubRunnerRegistration.ps1"
}

Describe 'Get-GitHubRunnerRegistration' {

    Context 'API request' {
        It 'queries the runners collection with per_page=100' {
            Mock Invoke-GitHubApi { [PSCustomObject] @{ runners = @() } }

            Get-GitHubRunnerRegistration `
                -Token      'ghp_test' `
                -GithubUrl  'https://github.com/user/repo-a' `
                -RunnerName 'runner-a'

            Should -Invoke Invoke-GitHubApi -Times 1 -ParameterFilter {
                $Endpoint -like '*runners?per_page=100'
            }
        }

        It 'builds the endpoint from the owner and repo parsed from GithubUrl' {
            Mock Invoke-GitHubApi { [PSCustomObject]@{ runners = @() } }

            Get-GitHubRunnerRegistration `
                -Token      'ghp_test' `
                -GithubUrl  'https://github.com/myorg/myrepo' `
                -RunnerName 'runner-a'

            Should -Invoke Invoke-GitHubApi -ParameterFilter {
                $Endpoint -eq 'repos/myorg/myrepo/actions/runners?per_page=100'
            }
        }

        It 'passes the token to Invoke-GitHubApi' {
            Mock Invoke-GitHubApi { [PSCustomObject]@{ runners = @() } }

            Get-GitHubRunnerRegistration `
                -Token      'ghp_test' `
                -GithubUrl  'https://github.com/user/repo-a' `
                -RunnerName 'runner-a'

            Should -Invoke Invoke-GitHubApi -ParameterFilter { $Token -eq 'ghp_test' }
        }
    }

    Context 'return value' {
        It 'returns the matching runner object when the runner is registered' {
            Mock Invoke-GitHubApi {
                [PSCustomObject]@{ runners = @(
                    [PSCustomObject]@{ name = 'other-runner'; id = 1 },
                    [PSCustomObject]@{ name = 'runner-a';    id = 2 }
                )}
            }

            $result = Get-GitHubRunnerRegistration `
                -Token      'ghp_test' `
                -GithubUrl  'https://github.com/user/repo-a' `
                -RunnerName 'runner-a'

            $result.id | Should -Be 2
        }

        It 'returns $null when the runner is not in the list' {
            Mock Invoke-GitHubApi {
                [PSCustomObject]@{ runners = @([PSCustomObject]@{ name = 'other-runner'; id = 1 }) }
            }

            $result = Get-GitHubRunnerRegistration `
                -Token      'ghp_test' `
                -GithubUrl  'https://github.com/user/repo-a' `
                -RunnerName 'runner-a'

            $result | Should -BeNullOrEmpty
        }

        It 'returns $null when the runners list is empty' {
            Mock Invoke-GitHubApi { [PSCustomObject]@{ runners = @() } }

            $result = Get-GitHubRunnerRegistration `
                -Token      'ghp_test' `
                -GithubUrl  'https://github.com/user/repo-a' `
                -RunnerName 'runner-a'

            $result | Should -BeNullOrEmpty
        }

        It 'returns $null when the response has no runners property' {
            Mock Invoke-GitHubApi { [PSCustomObject]@{} }

            $result = Get-GitHubRunnerRegistration `
                -Token      'ghp_test' `
                -GithubUrl  'https://github.com/user/repo-a' `
                -RunnerName 'runner-a'

            $result | Should -BeNullOrEmpty
        }

        It 'returns only the first match when multiple runners share the same name' {
            Mock Invoke-GitHubApi {
                [PSCustomObject]@{ runners = @(
                    [PSCustomObject]@{ name = 'runner-a'; id = 1 },
                    [PSCustomObject]@{ name = 'runner-a'; id = 2 }
                )}
            }

            $result = Get-GitHubRunnerRegistration `
                -Token      'ghp_test' `
                -GithubUrl  'https://github.com/user/repo-a' `
                -RunnerName 'runner-a'

            @($result).Count | Should -Be 1
            $result.id       | Should -Be 1
        }
    }
}
