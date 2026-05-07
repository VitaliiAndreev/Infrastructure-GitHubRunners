# ---------------------------------------------------------------------------
# Remove-SshEnvironment.ps1
#   Shared AfterAll body for integration tests. Dot-source this file
#   inside an AfterAll block:
#       AfterAll { . "$PSScriptRoot\Remove-SshEnvironment.ps1" }
# ---------------------------------------------------------------------------

if ($null -ne $Script:SshClient) {
    if ($Script:SshClient.IsConnected) { $Script:SshClient.Disconnect() }
    $Script:SshClient.Dispose()
}

docker stop $Script:ContainerName 2>&1 | Out-Null
docker rm   $Script:ContainerName 2>&1 | Out-Null
