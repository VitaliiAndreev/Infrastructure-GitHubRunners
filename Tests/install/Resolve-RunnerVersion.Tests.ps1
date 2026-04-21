BeforeAll {
    . "$PSScriptRoot\..\..\hyper-v\ubuntu\install\Resolve-RunnerVersion.ps1"
}

Describe 'Resolve-RunnerVersion' {

    Context 'API request' {
        It 'calls the GitHub Releases API with the correct URI and headers' {
            Mock Invoke-RestMethod { @{ tag_name = 'v2.317.0' } }

            Resolve-RunnerVersion -Pat 'ghp_test'

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri -eq 'https://api.github.com/repos/actions/runner/releases/latest' -and
                $Headers['User-Agent'] -eq 'Infrastructure-GitHubRunners' -and
                $Headers['Authorization'] -eq 'Bearer ghp_test'
            }
        }
    }

    Context 'version string' {
        It 'strips the leading v prefix from tag_name' {
            Mock Invoke-RestMethod { @{ tag_name = 'v2.317.0' } }

            $result = Resolve-RunnerVersion -Pat 'ghp_test'

            $result | Should -Be '2.317.0'
        }

        It 'handles a tag_name that has no v prefix' {
            Mock Invoke-RestMethod { @{ tag_name = '2.100.0' } }

            $result = Resolve-RunnerVersion -Pat 'ghp_test'

            $result | Should -Be '2.100.0'
        }
    }
}
