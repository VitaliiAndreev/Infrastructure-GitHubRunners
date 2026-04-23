BeforeAll {
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\registration\up\github\New-RunnerRegistrationToken.ps1"
}

Describe 'New-RunnerRegistrationToken' {

    Context 'API request' {
        It 'calls the registration-token endpoint with POST, correct URI, and headers' {
            Mock Invoke-RestMethod { @{ token = 'tok_abc' } }

            New-RunnerRegistrationToken `
                -Pat       'ghp_test' `
                -GithubUrl 'https://github.com/user/repo-a'

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri    -eq 'https://api.github.com/repos/user/repo-a/actions/runners/registration-token' -and
                $Method -eq 'Post' -and
                $Headers['Authorization'] -eq 'Bearer ghp_test' -and
                $Headers['User-Agent']    -eq 'Infrastructure-GitHubRunners'
            }
        }

        It 'parses owner and repo from a URL with a trailing slash' {
            Mock Invoke-RestMethod { @{ token = 'tok_abc' } }

            New-RunnerRegistrationToken `
                -Pat       'ghp_test' `
                -GithubUrl 'https://github.com/user/repo-a/'

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri -like '*repos/user/repo-a/actions/runners/registration-token*'
            }
        }
    }

    Context 'return value' {
        It 'returns the token string from the API response' {
            Mock Invoke-RestMethod { @{ token = 'LLBF3JGZDX3P5PTWE5GS2LNRB44P' } }

            $result = New-RunnerRegistrationToken `
                -Pat       'ghp_test' `
                -GithubUrl 'https://github.com/user/repo-a'

            $result | Should -Be 'LLBF3JGZDX3P5PTWE5GS2LNRB44P'
        }
    }
}
