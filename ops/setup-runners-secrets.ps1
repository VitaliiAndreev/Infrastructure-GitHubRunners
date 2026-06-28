<#
.SYNOPSIS
    Stores GitHubRunnersConfig in the local SecretStore vault by delegating
    to this repo's canonical setup script.

.DESCRIPTION
    Thin wrapper. The real validation and vault-write logic lives in this
    repo's hyper-v/ubuntu/setup-secrets.ps1 - this file exists so the
    Ansible operator surface stays consistent: `ops/setup-runners-secrets.{ps1,bat}`
    sit next to the rest of the `ops/` runner wrappers, without duplicating
    the schema validator and the Initialize-MicrosoftPowerShellSecretStoreVault
    call site.

    The Ansible flow's bash bridge (Common-Ansible ops/_run-playbook.sh)
    reads the same vault (`GitHubRunners`) and secret name
    (`GitHubRunnersConfig-<Suffix>`) when a wrapper declares it via
    `CA_EXTRA_VAULTS=GitHubRunners`, so both the PowerShell and Ansible runner
    flows in this repo share one secret. Keeping a single writer avoids a
    second place to keep in lock-step.

.PARAMETER ConfigFile
    Path to the GitHubRunnersConfig JSON file. Mutually exclusive with
    -ConfigJson. Forwarded verbatim to the setup script.

.PARAMETER ConfigJson
    The runner config as a raw JSON string. Mutually exclusive with
    -ConfigFile. Forwarded verbatim.

.PARAMETER RequireVaultPassword
    When specified, the SecretStore vault requires a password each session.
    Recommended on shared or less-trusted machines. Forwarded verbatim.

.PARAMETER SecretSuffix
    Selects the lifecycle/environment label appended to the secret name
    (`GitHubRunnersConfig-<Suffix>`). Operator runs pass `Production`;
    ephemeral fixtures pass their own label. Forwarded verbatim.

.EXAMPLE
    pwsh ./ops/setup-runners-secrets.ps1 `
        -ConfigFile C:\private\runners-config.json `
        -SecretSuffix Production
#>

[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string] $ConfigFile,

    [Parameter(Mandatory, ParameterSetName = 'Json')]
    [string] $ConfigJson,

    [Parameter()]
    [switch] $RequireVaultPassword,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SecretSuffix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Fail fast before resolving the setup script - a missing config file is the
# operator's typo, not a missing dependency, so surface that first with a
# path-named error.
if ($PSCmdlet.ParameterSetName -eq 'File' `
        -and -not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
    throw "ConfigFile not found: $ConfigFile"
}

# This repo's canonical runner-secrets writer lives under hyper-v/ubuntu/,
# resolved relative to this script's own location (ops/ -> repo root).
$repoRoot   = Split-Path -Parent $PSScriptRoot
$runnersPs1 = [IO.Path]::Combine(
    $repoRoot, 'hyper-v', 'ubuntu', 'setup-secrets.ps1'
)

if (-not (Test-Path -LiteralPath $runnersPs1 -PathType Leaf)) {
    throw "Runner secrets setup script not found at:`n  $runnersPs1"
}

# Forward only the params the delegate actually accepts. Splatting the whole
# $PSBoundParameters would pass through nothing extra today, but building the
# hashtable explicitly keeps the contract obvious if a future PowerShell
# common-parameter sneaks in.
$forward = @{ SecretSuffix = $SecretSuffix }
if ($PSCmdlet.ParameterSetName -eq 'File') { $forward.ConfigFile = $ConfigFile }
if ($PSCmdlet.ParameterSetName -eq 'Json') { $forward.ConfigJson = $ConfigJson }
if ($RequireVaultPassword)                 { $forward.RequireVaultPassword = $true }

& $runnersPs1 @forward
