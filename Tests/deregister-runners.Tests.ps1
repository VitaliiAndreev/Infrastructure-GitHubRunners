<#
.SYNOPSIS
    Structural wiring checks for deregister-runners.ps1.

.DESCRIPTION
    See register-runners.Tests.ps1 for the rationale - deregister-
    runners.ps1 has the same two-helper read shape and the same
    SecretSuffix contract, so the checks mirror that file with the
    script path swapped.
#>

BeforeAll {
    $script:scriptPath = Join-Path $PSScriptRoot '..\hyper-v\ubuntu\deregister-runners.ps1'

    $tokens    = $null
    $parseErrs = $null
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:scriptPath, [ref] $tokens, [ref] $parseErrs)
    if ($parseErrs.Count -gt 0) {
        throw "deregister-runners.ps1 has parse errors: $($parseErrs -join '; ')"
    }

    $script:commands = $script:ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true)

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

Describe 'deregister-runners.ps1 - SecretSuffix parameter contract' {

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

Describe 'deregister-runners.ps1 - suffix forwarding to vault helpers' {

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


Describe 'deregister-runners.ps1 - jump-host wiring (feature 53 NAT topology)' {

    # Symmetric to register-runners.ps1's jump-host wiring. The down
    # path opens an SSH session per reachable VM and does not run a
    # host file server, so the Get-VmSwitchHostIp leg of the wiring
    # is intentionally absent here.

    It 'reads VmProvisionerConfig to locate the router row' {
        $text = Get-Content -LiteralPath $script:scriptPath -Raw
        $text | Should -Match 'VmProvisionerConfig-\$SecretSuffix'
    }

    It 'calls Get-VmKvpIpAddress to discover the router upstream IP' {
        $call = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Get-VmKvpIpAddress' } |
            Select-Object -First 1
        $call | Should -Not -BeNullOrEmpty
    }

    It 'calls New-VmSshClientWithJump for the per-VM SSH session' {
        $call = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'New-VmSshClientWithJump' } |
            Select-Object -First 1
        $call | Should -Not -BeNullOrEmpty
    }

    It 'stamps _RouterVm onto entries via Add-Member' {
        $text = Get-Content -LiteralPath $script:scriptPath -Raw
        $text | Should -Match "(?s)Add-Member[^']*-Name\s+'_RouterVm'"
    }

    It 'no longer constructs Renci.SshNet.SshClient directly' {
        $text = Get-Content -LiteralPath $script:scriptPath -Raw
        $text | Should -Not -Match '\[Renci\.SshNet\.SshClient\]::new'
    }
}
