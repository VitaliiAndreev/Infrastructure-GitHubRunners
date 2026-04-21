BeforeAll {
    # Stub Assert-RequiredProperties before dot-sourcing so the function exists
    # when ConvertFrom-GitHubRunnersConfigJson.ps1 is loaded. The real
    # implementation lives in Infrastructure.Common, which is not required in
    # the test environment.
    function Assert-RequiredProperties {
        param($Object, $Properties, $Context)
    }

    . "$PSScriptRoot\..\hyper-v\ubuntu\resolve\ConvertFrom-GitHubRunnersConfigJson.ps1"

    # Builds a minimal valid runner entry JSON string with all required fields.
    # Individual tests override specific fields as needed.
    function New-ValidEntryJson {
        param(
            [string] $VmName         = 'ubuntu-01-ci',
            [string] $IpAddress      = '192.168.1.101',
            [string] $DeployUser     = 'u-runner-deploy',
            [string] $GithubUrl      = 'https://github.com/user/repo',
            [string] $RunnerName     = 'ubuntu-01-ci',
            [string] $LabelsJson     = '["self-hosted","ubuntu","x64"]'
        )
        @"
{
    "vmName":          "$VmName",
    "ipAddress":       "$IpAddress",
    "deployUsername":  "$DeployUser",
    "githubUrl":       "$GithubUrl",
    "runnerName":      "$RunnerName",
    "runnerLabels":    $LabelsJson
}
"@
    }

    # Joins one or more entry JSON strings into a JSON array string.
    function ConvertTo-JsonArray([string[]] $items) {
        '[' + ($items -join ', ') + ']'
    }
}

Describe 'ConvertFrom-GitHubRunnersConfigJson' {

    Context 'valid input' {
        It 'returns a runner entry for a single-element JSON array' {
            $result = @(ConvertFrom-GitHubRunnersConfigJson -Json (ConvertTo-JsonArray (New-ValidEntryJson)))
            $result | Should -HaveCount 1
            $result[0].vmName | Should -Be 'ubuntu-01-ci'
        }

        It 'normalises a bare JSON object to a 1-element array (PS 5.1 unwrap)' {
            # ConvertFrom-Json in PS 5.1 unwraps a single-element JSON array
            # into a bare PSCustomObject. @() in the function normalises this
            # so callers always receive an array.
            $result = @(ConvertFrom-GitHubRunnersConfigJson -Json (New-ValidEntryJson))
            $result | Should -HaveCount 1
        }

        It 'returns all entries for a multi-runner JSON array' {
            $json = ConvertTo-JsonArray (New-ValidEntryJson 'ubuntu-01-ci'), (New-ValidEntryJson 'ubuntu-02-ci')
            $result = @(ConvertFrom-GitHubRunnersConfigJson -Json $json)
            $result | Should -HaveCount 2
            $result[0].vmName | Should -Be 'ubuntu-01-ci'
            $result[1].vmName | Should -Be 'ubuntu-02-ci'
        }

        It 'accepts a single-label runnerLabels array' {
            $json = ConvertTo-JsonArray (New-ValidEntryJson -LabelsJson '["self-hosted"]')
            { @(ConvertFrom-GitHubRunnersConfigJson -Json $json) } | Should -Not -Throw
        }
    }

    Context 'invalid JSON' {
        It 'throws "Invalid JSON" for a malformed JSON string' {
            { ConvertFrom-GitHubRunnersConfigJson -Json '{not valid json' } |
                Should -Throw -ExpectedMessage '*Invalid JSON*'
        }

        It 'throws on an empty string' {
            # PS 5.1 rejects an empty [string] parameter before the function
            # body runs, so the error comes from parameter binding rather than
            # the "Invalid JSON" catch block. The function still throws - this
            # test pins that boundary behaviour.
            { ConvertFrom-GitHubRunnersConfigJson -Json '' } |
                Should -Throw -ExpectedMessage '*empty string*'
        }
    }

    Context 'empty config' {
        It 'throws when the JSON array is empty' {
            { ConvertFrom-GitHubRunnersConfigJson -Json '[]' } |
                Should -Throw -ExpectedMessage '*non-empty*'
        }
    }

    Context 'required field validation' {
        It 'calls Assert-RequiredProperties once per entry' {
            Mock Assert-RequiredProperties {}
            $json = ConvertTo-JsonArray (New-ValidEntryJson 'ubuntu-01-ci'), (New-ValidEntryJson 'ubuntu-02-ci')
            @(ConvertFrom-GitHubRunnersConfigJson -Json $json)
            Should -Invoke Assert-RequiredProperties -Times 2 -Exactly
        }

        It 'passes all six required field names to Assert-RequiredProperties' {
            Mock Assert-RequiredProperties {}
            @(ConvertFrom-GitHubRunnersConfigJson -Json (ConvertTo-JsonArray (New-ValidEntryJson)))
            Should -Invoke Assert-RequiredProperties -Times 1 -Exactly -ParameterFilter {
                $Properties -contains 'vmName'          -and
                $Properties -contains 'ipAddress'       -and
                $Properties -contains 'deployUsername'  -and
                $Properties -contains 'githubUrl'       -and
                $Properties -contains 'runnerName'      -and
                $Properties -contains 'runnerLabels'
            }
        }

        It 'throws when Assert-RequiredProperties throws for an entry' {
            Mock Assert-RequiredProperties { throw "Runner entry is missing required property 'vmName'." }
            { ConvertFrom-GitHubRunnersConfigJson -Json (ConvertTo-JsonArray (New-ValidEntryJson)) } |
                Should -Throw -ExpectedMessage '*missing required property*'
        }
    }

    Context 'runnerLabels validation' {
        It 'throws when runnerLabels is an empty array' {
            $json = ConvertTo-JsonArray (New-ValidEntryJson -LabelsJson '[]')
            { ConvertFrom-GitHubRunnersConfigJson -Json $json } |
                Should -Throw -ExpectedMessage '*runnerLabels must not be empty*'
        }
    }
}
