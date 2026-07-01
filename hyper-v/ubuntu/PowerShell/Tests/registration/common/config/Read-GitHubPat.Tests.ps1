# The Read-Host mocks build a SecureString from a throwaway literal PAT to
# exercise the prompt-and-convert path; no real secret is present, so the
# plaintext-conversion rule does not apply. Suppressed file-wide here, it
# stays live in production code.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'Test double converting a throwaway literal PAT, no real secret')]
param()

BeforeAll {
    . "$PSScriptRoot\..\..\..\..\registration\common\config\Read-GitHubPat.ps1"
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
