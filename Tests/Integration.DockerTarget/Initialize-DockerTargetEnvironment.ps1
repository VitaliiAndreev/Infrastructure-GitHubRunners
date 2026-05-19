# ---------------------------------------------------------------------------
# Initialize-DockerTargetEnvironment.ps1
#   Shared BeforeAll body for DockerTarget integration tests. Dot-source
#   inside a BeforeAll block:
#       BeforeAll { . "$PSScriptRoot\Initialize-DockerTargetEnvironment.ps1" }
#
#   Starts a Docker container (ubuntu:24.04) and provisions a minimal SSH
#   environment inside it:
#     - Deploy user  (infra-t-deploy): SSH-accessible, sudoers-permitted to
#       run commands as the runner user.
#     - Runner user  (infra-t-runner): no-login service account that owns
#       runner files; matches the role of u-actions-runner in production.
#   Both users and the container are torn down by each test file's AfterAll
#   block via Remove-DockerTargetEnvironment.ps1.
#
#   A minimal fake tarball is pre-created in /tmp so tests that need an
#   extractable archive do not require internet access.
#
#   $Script:ContainerName is set here and used by
#   Remove-DockerTargetEnvironment.ps1 and by direct docker exec calls in
#   each test file's BeforeEach/AfterEach.
# ---------------------------------------------------------------------------

function Write-Step {
    param([int] $Number, [string] $Description)
    $ts = (Get-Date).ToString('HH:mm:ss')
    Write-Host "[$ts] Step $Number - $Description" -ForegroundColor Cyan
}

# Runs a command inside the test container. Available to this script only;
# test files use docker exec $Script:ContainerName directly.
function Invoke-ContainerCommand {
    param([string] $Command)
    docker exec $Script:ContainerName bash -c $Command
}

# -----------------------------------------------------------------------
# 0. Build image and start container
#    The Dockerfile pre-installs openssh-server and sudo so the image layer
#    is cached after the first build - subsequent runs skip all apt work.
#    Port 2222 on the host is mapped to 22 in the container so the SSH
#    client connects to localhost:2222 without conflicting with any host
#    SSH daemon.
# -----------------------------------------------------------------------

$Script:ImageName     = 'infra-ssh-test-image'
$Script:ContainerName = 'infra-ssh-test'

# In CI the build-ssh-test-image action pre-builds the image before Pester
# runs, so docker images returns a non-empty ID and we skip the build.
# In local dev the image is absent on first run; INFRASTRUCTURE_COMMON_PATH
# must point to the Infrastructure-Common repo so the Dockerfile can be found.
$existingImage = docker images -q $Script:ImageName 2>&1
if ($existingImage) {
    Write-Step 0 'SSH test image already present - skipping build'
} else {
    Write-Step 0 'building SSH test image'
    if (-not $env:INFRASTRUCTURE_COMMON_PATH) {
        throw ('INFRASTRUCTURE_COMMON_PATH is not set. ' +
               'Set it to the root of the Infrastructure-Common repository.')
    }
    $dockerfileDir = [IO.Path]::Combine(
        $env:INFRASTRUCTURE_COMMON_PATH,
        '.github', 'actions', 'build-ssh-test-image')
    $buildOutput = docker build -t $Script:ImageName $dockerfileDir 2>&1
    if ($LASTEXITCODE -ne 0) {
        $buildOutput | ForEach-Object { Write-Host $_ }
        throw "Failed to build Docker image '$Script:ImageName'."
    }
}

Write-Step 0 'starting SSH test container'

# Remove any leftover container from a previous failed run.
docker rm -f $Script:ContainerName 2>&1 | Out-Null

docker run -d --name $Script:ContainerName -p 2222:22 $Script:ImageName sleep infinity
if ($LASTEXITCODE -ne 0) {
    throw "Failed to start Docker container '$Script:ContainerName'."
}

# -----------------------------------------------------------------------
# 2. Create users
#    infra-t-deploy: SSH-accessible deploy user.
#    infra-t-runner: no-login service account that owns runner files.
# -----------------------------------------------------------------------

Write-Step 2 'creating deploy user'

$Script:DeployUser = 'infra-t-deploy'
$Script:DeployPass = 'InfraTestDeploy1!'

Invoke-ContainerCommand "useradd -m -s /bin/bash $Script:DeployUser"
Invoke-ContainerCommand "echo '${Script:DeployUser}:${Script:DeployPass}' | chpasswd"

Write-Step 2 'creating runner service user'

$Script:RunnerUser = 'infra-t-runner'

# --no-create-home because the tests create the home directory structure
# explicitly - matching how Infrastructure-Vm-Users provisions the user.
Invoke-ContainerCommand "useradd --system --no-create-home --shell /usr/sbin/nologin $Script:RunnerUser"

# Create home directory and hand ownership to the runner user.
Invoke-ContainerCommand ("mkdir -p /home/$Script:RunnerUser && " +
    "chown ${Script:RunnerUser}:${Script:RunnerUser} /home/$Script:RunnerUser")

# -----------------------------------------------------------------------
# 3. Configure sudoers
#    These rules mirror the canonical production grants documented in
#    Infrastructure-Vm-Users README under the runner deploy user. Keeping
#    them in lockstep is what allows this E2E to catch sudoers-scope bugs
#    (e.g. a new 'sudo chmod' call missing from the production allowlist)
#    that a blanket NOPASSWD would silently mask.
#    !requiretty allows sudo in non-interactive SSH sessions.
# -----------------------------------------------------------------------

Write-Step 3 'configuring sudoers'

$sudoersPath    = "/etc/sudoers.d/${Script:DeployUser}"
$sudoersContent = @"
${Script:DeployUser} ALL=(${Script:RunnerUser}) NOPASSWD: /usr/bin/mkdir
${Script:DeployUser} ALL=(${Script:RunnerUser}) NOPASSWD: /usr/bin/rm
${Script:DeployUser} ALL=(${Script:RunnerUser}) NOPASSWD: /usr/bin/curl
${Script:DeployUser} ALL=(${Script:RunnerUser}) NOPASSWD: /usr/bin/tar
${Script:DeployUser} ALL=(${Script:RunnerUser}) NOPASSWD: /usr/bin/test
${Script:DeployUser} ALL=(root) NOPASSWD: /usr/bin/mkdir
${Script:DeployUser} ALL=(root) NOPASSWD: /usr/bin/chown
${Script:DeployUser} ALL=(root) NOPASSWD: /usr/bin/rm -rf /opt/runners/*
${Script:DeployUser} ALL=(${Script:RunnerUser}) NOPASSWD: /opt/runners/*/config.sh
${Script:DeployUser} ALL=(root) NOPASSWD: /opt/runners/*/svc.sh
${Script:DeployUser} ALL=(root) NOPASSWD: /bin/systemctl start actions.runner.*
${Script:DeployUser} ALL=(root) NOPASSWD: /bin/systemctl stop actions.runner.*
${Script:DeployUser} ALL=(root) NOPASSWD: /bin/systemctl is-active actions.runner.*
Defaults:${Script:DeployUser} !requiretty
"@

# Pipe via stdin (-i) so the content never appears in the process list.
$sudoersContent | docker exec -i $Script:ContainerName `
    bash -c "cat > $sudoersPath && chmod 0440 $sudoersPath"

# -----------------------------------------------------------------------
# 4. Install host-side modules
#    Done before starting sshd because Wait-VmSshReady (HyperV) is used in
#    step 5 to gate sshd's port-22 bind inside the container. Posh-SSH is
#    installed in the same step because the host opens its own SshClient
#    against the container in step 6.
# -----------------------------------------------------------------------

Write-Step 4 'installing Infrastructure.Common'
$_ic = Get-Module -ListAvailable Infrastructure.Common |
    Where-Object { $_.Version -ge [Version]'5.1.0' } | Select-Object -First 1
if (-not $_ic) {
    # Inline retry for the chicken-and-egg case: Invoke-ModuleInstall
    # (which has retry built in) ships inside Infrastructure.Common, so it
    # cannot be used to install Common itself. Six attempts with
    # exponential backoff (10 s -> 20 -> 40 -> 80 -> 160, capped at 300 s)
    # covers transient PSGallery "Unable to resolve package source" blips
    # without stalling an integration run on a real outage.
    $_installAttempts        = 6
    $_installDelaySeconds    = 10
    $_installMaxDelaySeconds = 300
    for ($_attempt = 1; $_attempt -le $_installAttempts; $_attempt++) {
        try {
            # -ErrorAction Stop promotes the PSGallery resolution warning
            # to a terminating error so the catch block can retry it.
            Install-Module Infrastructure.Common -MinimumVersion '5.1.0' `
                -Scope CurrentUser -Force -SkipPublisherCheck -ErrorAction Stop
            break
        }
        catch {
            if ($_attempt -ge $_installAttempts) { throw }
            Write-Warning (
                "Install-Module Infrastructure.Common failed " +
                "(attempt $_attempt/$_installAttempts): " +
                "$($_.Exception.Message). Retrying in ${_installDelaySeconds}s ..."
            )
            Start-Sleep -Seconds $_installDelaySeconds
            $_installDelaySeconds = [Math]::Min(
                $_installDelaySeconds * 2, $_installMaxDelaySeconds)
        }
    }
    $_ic = Get-Module -ListAvailable Infrastructure.Common |
        Sort-Object Version -Descending | Select-Object -First 1
}
# Reload only when the loaded state differs from the target (multiple
# versions live, or wrong version live). Mirrors the conditional in
# Invoke-ModuleInstall - inlined here because this script runs before
# Infrastructure.Common is available.
$_loaded = @(Get-Module -Name Infrastructure.Common)
if ($_loaded.Count -ne 1 -or $_loaded[0].Version -ne $_ic.Version) {
    if ($_loaded) { $_loaded | Remove-Module -Force }
    Import-Module Infrastructure.Common -Force -ErrorAction Stop
}

Write-Step 4 'installing Infrastructure.HyperV'
# Provides Invoke-SshClientCommand used by Invoke-SshQuery below, plus
# Wait-VmSshReady used to gate sshd startup in step 5.
$_ih = Get-Module -ListAvailable Infrastructure.HyperV |
    Where-Object { $_.Version -ge [Version]'0.3.1' } | Select-Object -First 1
if (-not $_ih) {
    Install-Module Infrastructure.HyperV -MinimumVersion '0.3.1' `
        -Scope CurrentUser -Force -SkipPublisherCheck
}
Import-Module Infrastructure.HyperV -Force -ErrorAction Stop

Write-Step 4 'installing Infrastructure.GitHub'
# Provides Invoke-RunnerTarballDeploy exercised by the DockerTarget tests.
$_ig = Get-Module -ListAvailable Infrastructure.GitHub |
    Where-Object { $_.Version -ge [Version]'0.2.0' } | Select-Object -First 1
if (-not $_ig) {
    Install-Module Infrastructure.GitHub -MinimumVersion '0.2.0' `
        -Scope CurrentUser -Force -SkipPublisherCheck
}
Import-Module Infrastructure.GitHub -Force -ErrorAction Stop

Write-Step 4 'installing Posh-SSH (SSH.NET carrier)'
$_ps = Get-Module -ListAvailable Posh-SSH |
    Where-Object { $_.Version -ge [Version]'3.0.0' } | Select-Object -First 1
if (-not $_ps) {
    Install-Module Posh-SSH -MinimumVersion 3.0.0 `
        -Scope CurrentUser -Force -SkipPublisherCheck
}
Import-Module Posh-SSH

# -----------------------------------------------------------------------
# 5. Configure sshd and start it
# -----------------------------------------------------------------------

Write-Step 5 'configuring sshd'

# Drop a high-priority include to ensure password auth is on regardless of
# what the base config or cloud-init drops into sshd_config.d/.
Invoke-ContainerCommand `
    "mkdir -p /etc/ssh/sshd_config.d && echo 'PasswordAuthentication yes' > /etc/ssh/sshd_config.d/99-password-auth.conf"

Write-Step 5 'starting sshd'
Invoke-ContainerCommand '/usr/sbin/sshd'
# Wait for sshd inside the container to bind port 22 (mapped to 2222 on
# the host). The previous fixed Start-Sleep -Seconds 1 was a guess; on a
# slow host it could race the subsequent SSH connect attempt.
if (-not (Wait-VmSshReady -IpAddress 'localhost' -Port 2222 `
                          -TimeoutSeconds 10 -PollIntervalSeconds 1)) {
    throw "sshd did not become reachable on localhost:2222 within 10s."
}

Write-Step 5 'dot-sourcing install functions'
$src = [IO.Path]::Combine($PSScriptRoot, '..', '..', 'hyper-v', 'ubuntu')
. ([IO.Path]::Combine($src, 'registration', 'common', 'infra',  'Get-RunnerPaths.ps1'))
. ([IO.Path]::Combine($src, 'registration', 'up', 'binary',     'Invoke-RunnerExtract.ps1'))
. ([IO.Path]::Combine($src, 'registration', 'up', 'binary',     'Invoke-RunnerInstall.ps1'))

# -----------------------------------------------------------------------
# 6. Open SSH session
#    Connecting to localhost:2222 which Docker maps to port 22 inside the
#    container (see step 0).
# -----------------------------------------------------------------------

Write-Step 6 'opening SSH session'

$auth             = [Renci.SshNet.PasswordAuthenticationMethod]::new(
                        $Script:DeployUser, $Script:DeployPass)
$connInfo         = [Renci.SshNet.ConnectionInfo]::new(
                        'localhost', 2222, $Script:DeployUser, @($auth))
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

Invoke-ContainerCommand ("echo '#!/bin/bash' > /tmp/run.sh && chmod +x /tmp/run.sh && " +
    "tar -czf '${Script:FakeTarball}' -C /tmp run.sh && rm /tmp/run.sh")

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
