BeforeAll {
    function Invoke-GitHubRunnersApi { param($Pat, $GithubUrl, $Suffix, $Method) }

    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\registration\down\github\Remove-GitHubRunner.ps1"

    # Builds a fake HTTP exception with a StatusCode on the Response, which
    # mirrors the shape of System.Net.WebException thrown by Invoke-RestMethod.
    function New-FakeHttpException ([int] $StatusCode) {
        $ex       = [System.Exception]::new("HTTP $StatusCode")
        $response = [PSCustomObject] @{ StatusCode = $StatusCode }
        $ex | Add-Member -NotePropertyName Response -NotePropertyValue $response
        $ex
    }
}

Describe 'Remove-GitHubRunner' {

    Context 'DELETE request' {
        It 'calls the DELETE endpoint with the runner ID as the suffix' {
            Mock Invoke-GitHubRunnersApi {}

            Remove-GitHubRunner -Pat 'ghp_test' `
                -GithubUrl 'https://github.com/user/repo-a' -RunnerId 42

            Should -Invoke Invoke-GitHubRunnersApi -Times 1 -ParameterFilter {
                $Suffix -eq 42 -and $Method -eq 'Delete'
            }
        }
    }

    Context '404 handling' {
        It 'does not throw when the runner is already gone (404)' {
            Mock Invoke-GitHubRunnersApi { throw (New-FakeHttpException 404) }

            { Remove-GitHubRunner -Pat 'ghp_test' `
                -GithubUrl 'https://github.com/user/repo-a' -RunnerId 42 `
            } | Should -Not -Throw
        }

        It 'rethrows non-404 errors' {
            Mock Invoke-GitHubRunnersApi { throw (New-FakeHttpException 403) }

            { Remove-GitHubRunner -Pat 'ghp_test' `
                -GithubUrl 'https://github.com/user/repo-a' -RunnerId 42 `
            } | Should -Throw
        }
    }
}
