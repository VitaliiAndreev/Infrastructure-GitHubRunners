<#
.SYNOPSIS
    Structural wiring checks for register-runners.ps1.

.DESCRIPTION
    register-runners.ps1 has top-level side effects (module install/
    import, two helper-driven vault reads, SSH connect loop) that
    make it impractical to dot-source from a test. These tests parse
    the file via AST and assert the parts of the SecretSuffix contract
    that would otherwise silently regress:

      - $SecretSuffix is a Mandatory + ValidateNotNullOrEmpty script
        parameter.
      - Both vault-reading helpers (Read-GitHubRunnersConfig and
        Read-VmDeployPasswords) are called exactly once each and
        receive -SecretSuffix bound to the script-level $SecretSuffix
        variable. A regression that hard-codes the suffix or drops
        the forward would defeat the per-lifecycle isolation the
        parameter exists to enforce.
#>

BeforeAll {
    $script:scriptPath = Join-Path $PSScriptRoot '..\hyper-v\ubuntu\register-runners.ps1'

    $tokens    = $null
    $parseErrs = $null
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:scriptPath, [ref] $tokens, [ref] $parseErrs)
    if ($parseErrs.Count -gt 0) {
        throw "register-runners.ps1 has parse errors: $($parseErrs -join '; ')"
    }

    $script:commands = $script:ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true)

    # Returns $true if $Call passes `-SecretSuffix $SecretSuffix`
    # (the script-level variable, not a literal). Walks CommandElements
    # in pairs looking for the parameter / variable-expression pair.
    function Test-ForwardsSecretSuffix {
        param([System.Management.Automation.Language.CommandAst] $Call)
        for ($i = 1; $i -lt $Call.CommandElements.Count - 1; $i++) {
            $cur  = $Call.CommandElements[$i]
            $next = $Call.CommandElements[$i + 1]
            if ($cur -is [System.Management.Automation.Language.CommandParameterAst] -and
                $cur.ParameterName -eq 'SecretSuffix' -and
                $next -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $next.VariablePath.UserPath -eq 'SecretSuffix') {
                return $true
            }
        }
        return $false
    }
}

Describe 'register-runners.ps1 - SecretSuffix parameter contract' {

    It 'declares -SecretSuffix as a script parameter' {
        $param = $script:ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'SecretSuffix' } |
            Select-Object -First 1
        $param | Should -Not -BeNullOrEmpty
    }

    It 'marks -SecretSuffix Mandatory' {
        $param = $script:ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'SecretSuffix' } |
            Select-Object -First 1
        $hasMandatory = $param.Attributes | Where-Object {
            $_.TypeName.Name -eq 'Parameter' -and
            ($_.NamedArguments | Where-Object {
                $_.ArgumentName -eq 'Mandatory'
            })
        }
        $hasMandatory | Should -Not -BeNullOrEmpty
    }

    It 'marks -SecretSuffix ValidateNotNullOrEmpty' {
        $param = $script:ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'SecretSuffix' } |
            Select-Object -First 1
        $hasValidator = $param.Attributes | Where-Object {
            $_.TypeName.Name -eq 'ValidateNotNullOrEmpty'
        }
        $hasValidator | Should -Not -BeNullOrEmpty
    }
}

Describe 'register-runners.ps1 - suffix forwarding to vault helpers' {

    # Each helper read must receive the script-level $SecretSuffix
    # verbatim. Both helpers' own suites (Tests/registration/common/
    # config/*.Tests.ps1) prove they reject missing/empty input - so
    # the wiring here is the missing link end-to-end.

    It 'invokes Read-GitHubRunnersConfig exactly once' {
        $calls = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Read-GitHubRunnersConfig' }
        @($calls).Count | Should -Be 1
    }

    It 'forwards $SecretSuffix to Read-GitHubRunnersConfig' {
        $call = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Read-GitHubRunnersConfig' } |
            Select-Object -First 1
        Test-ForwardsSecretSuffix -Call $call | Should -BeTrue
    }

    It 'invokes Read-VmDeployPasswords exactly once' {
        $calls = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Read-VmDeployPasswords' }
        @($calls).Count | Should -Be 1
    }

    It 'forwards $SecretSuffix to Read-VmDeployPasswords' {
        $call = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Read-VmDeployPasswords' } |
            Select-Object -First 1
        Test-ForwardsSecretSuffix -Call $call | Should -BeTrue
    }
}
