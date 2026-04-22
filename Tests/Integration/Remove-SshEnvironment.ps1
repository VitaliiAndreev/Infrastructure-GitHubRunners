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
& bash -c "userdel -r $($Script:DeployUser) 2>/dev/null; \
           userdel -r $($Script:RunnerUser) 2>/dev/null; true"
