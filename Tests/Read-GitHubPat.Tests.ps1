BeforeAll {
    . "$PSScriptRoot\..\hyper-v\ubuntu\resolve\Read-GitHubPat.ps1"
}

Describe 'Read-GitHubPat' {

    Context 'prompt and conversion' {
        It 'calls Read-Host with -AsSecureString' {
            Mock Read-Host { ConvertTo-SecureString 'ghp_test' -AsPlainText -Force }
            Read-GitHubPat
            Should -Invoke Read-Host -Times 1 -ParameterFilter {
                $AsSecureString -eq $true
            }
        }

        It 'returns the PAT as a plain-text string' {
            Mock Read-Host { ConvertTo-SecureString 'ghp_abc123' -AsPlainText -Force }
            $result = Read-GitHubPat
            $result | Should -Be 'ghp_abc123'
        }
    }
}
