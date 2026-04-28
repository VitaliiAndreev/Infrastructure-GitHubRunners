BeforeAll {
    function Invoke-GitHubApi { param($Token, $Endpoint, $Uri, $Method) }

    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\registration\up\github\Resolve-RunnerVersion.ps1"
}

Describe 'Resolve-RunnerVersion' {

    Context 'API request' {
        It 'calls the GitHub Releases API with the correct URI and token' {
            Mock Invoke-GitHubApi { @{ tag_name = 'v2.317.0' } }

            Resolve-RunnerVersion -Token 'ghp_test'

            Should -Invoke Invoke-GitHubApi -Times 1 -ParameterFilter {
                $Endpoint -eq 'repos/actions/runner/releases/latest' -and
                $Token    -eq 'ghp_test'
            }
        }
    }

    Context 'version string' {
        It 'strips the leading v prefix from tag_name' {
            Mock Invoke-GitHubApi { @{ tag_name = 'v2.317.0' } }

            $result = Resolve-RunnerVersion -Token 'ghp_test'

            $result | Should -Be '2.317.0'
        }

        It 'handles a tag_name that has no v prefix' {
            Mock Invoke-GitHubApi { @{ tag_name = '2.100.0' } }

            $result = Resolve-RunnerVersion -Token 'ghp_test'

            $result | Should -Be '2.100.0'
        }
    }
}
