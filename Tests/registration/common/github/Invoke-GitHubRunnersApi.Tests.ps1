BeforeAll {
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\registration\common\github\Invoke-GitHubRunnersApi.ps1"
}

Describe 'Invoke-GitHubRunnersApi' {

    Context 'URI construction' {
        It 'addresses the runners collection when Suffix is omitted' {
            Mock Invoke-RestMethod { @{} }

            Invoke-GitHubRunnersApi -Pat 'ghp_test' -GithubUrl 'https://github.com/user/repo-a'

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri -eq 'https://api.github.com/repos/user/repo-a/actions/runners'
            }
        }

        It 'appends a path segment suffix with a slash separator' {
            Mock Invoke-RestMethod { @{} }

            Invoke-GitHubRunnersApi -Pat 'ghp_test' -GithubUrl 'https://github.com/user/repo-a' `
                -Suffix 'registration-token'

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri -eq 'https://api.github.com/repos/user/repo-a/actions/runners/registration-token'
            }
        }

        It 'appends a query string suffix without a slash separator' {
            Mock Invoke-RestMethod { @{} }

            Invoke-GitHubRunnersApi -Pat 'ghp_test' -GithubUrl 'https://github.com/user/repo-a' `
                -Suffix '?per_page=100'

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri -eq 'https://api.github.com/repos/user/repo-a/actions/runners?per_page=100'
            }
        }

        It 'parses owner and repo from a URL with a trailing slash' {
            Mock Invoke-RestMethod { @{} }

            Invoke-GitHubRunnersApi -Pat 'ghp_test' -GithubUrl 'https://github.com/user/repo-a/'

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri -like '*repos/user/repo-a/actions/runners*'
            }
        }
    }

    Context 'request headers and method' {
        It 'sends the correct Authorization and User-Agent headers' {
            Mock Invoke-RestMethod { @{} }

            Invoke-GitHubRunnersApi -Pat 'ghp_test' -GithubUrl 'https://github.com/user/repo-a'

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Headers['Authorization'] -eq 'Bearer ghp_test' -and
                $Headers['User-Agent']    -eq 'Infrastructure-GitHubRunners'
            }
        }

        It 'defaults to GET when Method is not specified' {
            Mock Invoke-RestMethod { @{} }

            Invoke-GitHubRunnersApi -Pat 'ghp_test' -GithubUrl 'https://github.com/user/repo-a'

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Method -eq 'Get'
            }
        }

        It 'passes the specified Method to Invoke-RestMethod' {
            Mock Invoke-RestMethod { @{} }

            Invoke-GitHubRunnersApi -Pat 'ghp_test' -GithubUrl 'https://github.com/user/repo-a' `
                -Suffix 'registration-token' -Method 'Post'

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Method -eq 'Post'
            }
        }
    }

    Context 'return value' {
        It 'returns the raw response object from Invoke-RestMethod' {
            $expected = [PSCustomObject] @{ token = 'abc123' }
            Mock Invoke-RestMethod { $expected }

            $result = Invoke-GitHubRunnersApi `
                -Pat 'ghp_test' -GithubUrl 'https://github.com/user/repo-a'

            $result | Should -Be $expected
        }
    }
}
