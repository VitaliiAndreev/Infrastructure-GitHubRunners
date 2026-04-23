# ---------------------------------------------------------------------------
# Initialize-SshEnvironment.ps1
#   Shared BeforeAll body for install-path integration tests. Dot-source
#   inside a BeforeAll block:
#       BeforeAll { . "$PSScriptRoot\Initialize-SshEnvironment.ps1" }
#
#   Provisions a minimal SSH environment in the container:
#     - Deploy user  (infra-t-deploy): SSH-accessible, sudoers-permitted to
#       run commands as the runner user.
#     - Runner user  (infra-t-runner): no-login service account that owns
#       runner files; matches the role of u-actions-runner in production.
#   Both users are torn down by each test file's AfterAll block.
#
#   A minimal fake tarball is pre-created in /tmp so tests that need an
#   extractable archive do not require internet access.
# ---------------------------------------------------------------------------

function Write-Step {
    param([int] $Number, [string] $Description)
    $ts = (Get-Date).ToString('HH:mm:ss')
    Write-Host "[$ts] Step $Number - $Description" -ForegroundColor Cyan
}

# -----------------------------------------------------------------------
# 1. Install openssh-server and sudo
# -----------------------------------------------------------------------

Write-Step 1 'configuring apt sources'

# Switching sources from http:// to https:// avoids Docker Desktop on
# Windows silently dropping TCP connections on port 80, which otherwise
# causes apt-get update to time out for every mirror and take ~9 minutes.
$env:DEBIAN_FRONTEND = 'noninteractive'
& bash -c 'sed -i "s|http://|https://|g" /etc/apt/sources.list;
    find /etc/apt/sources.list.d -name "*.list" \
    -exec sed -i "s|http://|https://|g" {} + 2>/dev/null; true'

Write-Step 1 'apt-get update'
& bash -c 'apt-get update -qq 2>&1' | Out-Null

Write-Step 1 'apt-get install openssh-server sudo'
$aptOutput = & bash -c 'apt-get install -y --no-install-recommends openssh-server sudo 2>&1'
if ($LASTEXITCODE -ne 0) {
    Write-Host 'apt-get install failed:' -ForegroundColor Red
    $aptOutput | ForEach-Object { Write-Host $_ }
    throw "apt-get install exited $LASTEXITCODE - cannot continue."
}

Write-Step 1 'generating SSH host keys'
& ssh-keygen -A 2>&1 | Out-Null
New-Item -ItemType Directory -Path '/run/sshd' -Force | Out-Null

# -----------------------------------------------------------------------
# 2. Create users
#    infra-t-deploy: SSH-accessible deploy user.
#    infra-t-runner: no-login service account that owns runner files.
# -----------------------------------------------------------------------

Write-Step 2 'creating deploy user'

$Script:DeployUser = 'infra-t-deploy'
$Script:DeployPass = 'InfraTestDeploy1!'

& useradd -m -s /bin/bash $Script:DeployUser 2>&1 | Out-Null
& bash -c "echo '${Script:DeployUser}:${Script:DeployPass}' | chpasswd"

Write-Step 2 'creating runner service user'

$Script:RunnerUser = 'infra-t-runner'

# --no-create-home because the tests create the home directory structure
# explicitly - matching how Infrastructure-Vm-Users provisions the user.
& useradd --system --no-create-home --shell /usr/sbin/nologin $Script:RunnerUser 2>&1 |
    Out-Null

# Create home directory and hand ownership to the runner user. In
# production, useradd -m does this; here we do it explicitly so tests
# start with a clean, predictable layout.
New-Item -ItemType Directory -Path "/home/$($Script:RunnerUser)" -Force | Out-Null
& chown "${Script:RunnerUser}:${Script:RunnerUser}" "/home/$($Script:RunnerUser)"

# -----------------------------------------------------------------------
# 3. Configure sudoers
#    Deploy user needs:
#      - sudo -u infra-t-runner <cmd>   (mkdir, tar, curl as service user)
#      - sudo systemctl <cmd>           (service management)
#    !requiretty allows sudo in non-interactive SSH sessions.
# -----------------------------------------------------------------------

Write-Step 3 'configuring sudoers'

$sudoersPath = "/etc/sudoers.d/${Script:DeployUser}"
Set-Content -Path $sudoersPath -Value @"
${Script:DeployUser} ALL=(${Script:RunnerUser}) NOPASSWD: ALL
${Script:DeployUser} ALL=(root) NOPASSWD: /bin/systemctl
Defaults:${Script:DeployUser} !requiretty
"@
& chmod 0440 $sudoersPath

# -----------------------------------------------------------------------
# 4. Configure sshd and start it
# -----------------------------------------------------------------------

Write-Step 4 'configuring sshd'

$sshdConfigPath = '/etc/ssh/sshd_config'
$sshdConfig = Get-Content $sshdConfigPath -Raw
if ($sshdConfig -match '(?m)^#?PasswordAuthentication') {
    $sshdConfig = $sshdConfig -replace `
        '(?m)^#?PasswordAuthentication\s+\w+', `
        'PasswordAuthentication yes'
} else {
    $sshdConfig += "`nPasswordAuthentication yes"
}
Set-Content -Path $sshdConfigPath -Value $sshdConfig

Write-Step 4 'starting sshd'
& /usr/sbin/sshd
Start-Sleep -Seconds 1

# -----------------------------------------------------------------------
# 5. Install modules and dot-source functions
# -----------------------------------------------------------------------

Write-Step 5 'installing Infrastructure.Common'
Install-Module Infrastructure.Common -MinimumVersion '1.2.1' `
    -Scope CurrentUser -Force -SkipPublisherCheck
Import-Module Infrastructure.Common -Force -ErrorAction Stop

Write-Step 5 'installing Posh-SSH (SSH.NET carrier)'
Install-Module Posh-SSH -MinimumVersion 3.0.0 `
    -Scope CurrentUser -Force -SkipPublisherCheck
Import-Module Posh-SSH

Write-Step 5 'dot-sourcing install functions'
$src = [IO.Path]::Combine($PSScriptRoot, '..', '..', 'hyper-v', 'ubuntu')
. ([IO.Path]::Combine($src, 'registration', 'common', 'infra',       'Get-RunnerPaths.ps1'))
. ([IO.Path]::Combine($src, 'registration', 'up',     'binary', 'Invoke-TarballDownload.ps1'))
. ([IO.Path]::Combine($src, 'registration', 'up',     'binary', 'Invoke-RunnerExtract.ps1'))
. ([IO.Path]::Combine($src, 'registration', 'up',     'binary', 'Invoke-RunnerInstall.ps1'))

# -----------------------------------------------------------------------
# 6. Open SSH session
# -----------------------------------------------------------------------

Write-Step 6 'opening SSH session'

$auth             = [Renci.SshNet.PasswordAuthenticationMethod]::new(
                        $Script:DeployUser, $Script:DeployPass)
$connInfo         = [Renci.SshNet.ConnectionInfo]::new(
                        'localhost', $Script:DeployUser, @($auth))
$Script:SshClient = [Renci.SshNet.SshClient]::new($connInfo)
$Script:SshClient.Connect()
$Script:VmName    = 'test-vm'

# -----------------------------------------------------------------------
# 7. Create a minimal fake tarball in /tmp
#    Tests that exercise extraction use this instead of downloading the
#    real ~150 MB runner binary. The tarball contains a single dummy file
#    (run.sh) so test assertions can verify extraction occurred.
# -----------------------------------------------------------------------

Write-Step 7 'creating fake runner tarball'

$Script:RunnerVersion = '2.317.0'
$Script:FakeTarball   = "/tmp/actions-runner-linux-x64-${Script:RunnerVersion}.tar.gz"

& bash -c "echo '#!/bin/bash' > /tmp/run.sh && chmod +x /tmp/run.sh && \
    tar -czf '${Script:FakeTarball}' -C /tmp run.sh && \
    rm /tmp/run.sh"

# -----------------------------------------------------------------------
# 8. Define shared helpers
# -----------------------------------------------------------------------

Write-Step 8 'defining shared helpers'

function Invoke-SshQuery {
    param([string] $Command)
    $r = Invoke-SshClientCommand -SshClient $Script:SshClient -Command $Command `
        -ErrorAction Stop
    return ($r.Output -join '').Trim()
}

Write-Step 8 'BeforeAll complete'
