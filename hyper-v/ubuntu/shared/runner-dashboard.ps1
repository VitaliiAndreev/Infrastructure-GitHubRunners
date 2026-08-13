<#
.SYNOPSIS
    Live board of every self-hosted GitHub Actions runner in the fleet and the
    job each one is executing right now.

.DESCRIPTION
    Read-only. Polls the GitHub API on a fixed interval and repaints one screen
    per tick: a row per registered runner (online / offline / busy, plus the
    workflow, job, step and elapsed time when it is working), the jobs queued
    against this fleet's labels, and any repository that could not be polled.

    Complements runner-status.sh rather than replacing it. That probe SSHes
    into each VM to join systemd's view with GitHub's - authoritative about
    whether a runner is genuinely healthy, and far too slow to poll. This one
    never leaves the API, which is what lets it refresh in seconds; it can say
    what the fleet is doing, not why a listener is down.

    Which repositories to poll is derived from the GitHubRunnersConfig vault
    entry, collapsed to distinct owner/repo. Registering a runner on a new
    repository via setup-secrets.ps1 is therefore all it takes for that repo to
    appear here.

    Rate limit: the API budget is 5000 requests/hour for a PAT. A tick costs
    two conditional list calls per repository plus one live call per active
    workflow run. The conditional calls answer 304 whenever nothing changed and
    304s are not charged, so a quiet fleet costs almost nothing and the header
    shows the remaining budget on every frame. -RefreshSeconds has a floor of 5
    for the same reason.

    Security: the token is held in memory for the life of the process only. It
    is never written to disk, logged, or passed on a command line - which is
    why -Token exists for unattended callers but the interactive path prompts
    for it instead of accepting an argument.

.PARAMETER SecretSuffix
    Required. The vault read targets `GitHubRunnersConfig-<Suffix>`. Operator
    runs pass `Production`.

.PARAMETER Token
    GitHub token. When omitted, GH_TOKEN is used if set, otherwise the script
    prompts. Needs read access to Actions and to self-hosted runner
    administration on every polled repository.

.PARAMETER RefreshSeconds
    Seconds between polls. Default 10.

.PARAMETER Once
    Render a single frame and exit instead of looping. For a scripted check or
    a quick glance without taking over the terminal.

.EXAMPLE
    .\runner-dashboard.ps1 -SecretSuffix Production

.EXAMPLE
    .\runner-dashboard.ps1 -SecretSuffix Production -RefreshSeconds 30

.EXAMPLE
    .\runner-dashboard.ps1 -SecretSuffix Production -Once
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SecretSuffix,

    # Supplied by unattended callers; interactive runs leave it empty and are
    # prompted. See the security note above.
    [Parameter()]
    [string] $Token = '',

    # Floor of 5s keeps a mistyped value from burning the hourly API budget;
    # ceiling of 3600s is the outer bound Wait-RunnerDashboardKey accepts.
    [Parameter()]
    [ValidateRange(5, 3600)]
    [int] $RefreshSeconds = 10,

    [Parameter()]
    [switch] $Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Install / import every required PowerShell module. The helper owns the
# dependency list for this repo so each entry-point script does not repeat
# the bootstrap block.
. "$PSScriptRoot\Install-ModuleDependencies.ps1"

# Config parsing and the PAT prompt are shared with the register/deregister
# entry points; the dashboard-specific helpers live beside this script.
. "$PSScriptRoot\..\PowerShell\registration\common\config\ConvertFrom-GitHubRunnersConfigJson.ps1"
. "$PSScriptRoot\..\PowerShell\registration\common\config\Read-GitHubPat.ps1"
. "$PSScriptRoot\..\PowerShell\registration\common\config\Read-GitHubRunnersConfig.ps1"
. "$PSScriptRoot\dashboard\Format-FixedWidthColumn.ps1"
. "$PSScriptRoot\dashboard\Format-RunnerElapsed.ps1"
. "$PSScriptRoot\dashboard\Format-RunnerDashboardFrame.ps1"
. "$PSScriptRoot\dashboard\Get-RunnerDashboardRepository.ps1"
. "$PSScriptRoot\dashboard\Wait-RunnerDashboardKey.ps1"
. "$PSScriptRoot\dashboard\Write-RunnerDashboardFrame.ps1"

# ---------------------------------------------------------------------------
# Register the SecretStore provider for the vault read below.
# ---------------------------------------------------------------------------

Use-MicrosoftPowerShellSecretStoreProvider

# ---------------------------------------------------------------------------
# Acquire the token
#    Same resolution order as the bash ops wrappers' require_gh_token: an
#    already-set GH_TOKEN wins so an unattended caller never hits a prompt it
#    cannot answer, then the explicit parameter, then the interactive prompt.
# ---------------------------------------------------------------------------

if (-not $Token) { $Token = $env:GH_TOKEN }
if (-not $Token) {
    if ([Console]::IsInputRedirected) {
        throw 'No GitHub token. Set GH_TOKEN or pass -Token; there is no TTY to prompt on.'
    }
    $Token = Read-GitHubPat
}

# ---------------------------------------------------------------------------
# Resolve the repositories to poll from the vault
# ---------------------------------------------------------------------------

$runnerEntries = Read-GitHubRunnersConfig -SecretSuffix $SecretSuffix
$repositories  = Get-RunnerDashboardRepository -RunnerEntry $runnerEntries

if ($repositories.Count -eq 0) {
    throw "No repositories to poll - GitHubRunnersConfig-$SecretSuffix declares no runner entries."
}

Write-Host ""
Write-Host "Polling $($repositories.Count) repository/repositories every ${RefreshSeconds}s ..." `
    -ForegroundColor Cyan
Write-Host ($repositories -join ', ') -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Poll loop
#    $cache carries the ETags between ticks and is handed back to
#    Get-GitHubRunnerActivity untouched - that is what turns an unchanged
#    list into a free 304 instead of a charged 200.
#
#    Ctrl+C is left to terminate the process normally: there is nothing to
#    clean up (no sessions, no temp files, no remote state), and the menu's
#    own handler keeps the parent shell alive.
# ---------------------------------------------------------------------------

$cache          = @{}
$paintedLines   = 0

if (-not $Once -and -not [Console]::IsOutputRedirected) { Clear-Host }

while ($true) {
    $activity = Get-GitHubRunnerActivity `
        -Token      $Token `
        -Repository $repositories `
        -Cache      $cache

    $frame = Format-RunnerDashboardFrame `
        -Activity       $activity `
        -RefreshSeconds $RefreshSeconds

    $paintedLines = Write-RunnerDashboardFrame -Line $frame -PreviousLineCount $paintedLines

    if ($Once) { break }

    if ((Wait-RunnerDashboardKey -TimeoutSeconds $RefreshSeconds) -eq 'Quit') { break }
}
