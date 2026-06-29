# Integration tests for Invoke-RunnerTarballDeploy against a real SSH session.
# See Initialize-DockerTargetEnvironment.ps1 for environment details and isolation notes.
#
# All tests pre-seed the tarball so the function exits at the cache-hit
# branch without attempting a curl download. Integration value: real
# sudo -u ownership assertions that unit tests cannot provide.
# Directory creation and purge logic are covered by unit tests.

BeforeAll {
    . "$PSScriptRoot\Initialize-DockerTargetEnvironment.ps1"
}

AfterAll { . "$PSScriptRoot\Remove-DockerTargetEnvironment.ps1" }

Describe 'Invoke-RunnerTarballDeploy' {

    AfterEach {
        docker exec $Script:ContainerName bash -c "rm -rf '/home/$($Script:RunnerUser)/cache'"
    }

    BeforeEach {
        $Script:Paths = Get-RunnerPaths `
            -RunnerUser    $Script:RunnerUser `
            -RunnerVersion $Script:RunnerVersion

        # Pre-seed the tarball so the function hits the cache-hit branch
        # and does not attempt a real curl download.
        docker exec $Script:ContainerName bash -c ("mkdir -p '$($Script:Paths.CacheDir)' && " +
            "cp '$Script:FakeTarball' '$($Script:Paths.TarPath)' && " +
            "chown -R ${Script:RunnerUser}: '$($Script:Paths.CacheDir)'")

        # URL filename must match the pre-seeded tarball; the host is never
        # contacted because the cache-hit check returns first.
        $Script:TarUrl = "http://fake.test/actions-runner-linux-x64-${Script:RunnerVersion}.tar.gz"
    }

    It 'does not modify the tarball when it is already cached' {
        $mtimeBefore = Invoke-SshQuery "stat -c '%Y' '$($Script:Paths.TarPath)'"

        Invoke-RunnerTarballDeploy `
            -SshClient  $Script:SshClient `
            -TarUrl     $Script:TarUrl `
            -RunnerUser $Script:RunnerUser `
            -CacheDir   $Script:Paths.CacheDir

        $mtimeAfter = Invoke-SshQuery "stat -c '%Y' '$($Script:Paths.TarPath)'"
        $mtimeAfter | Should -Be $mtimeBefore
    }

    It 'leaves the cached tarball owned by the runner user' {
        Invoke-RunnerTarballDeploy `
            -SshClient  $Script:SshClient `
            -TarUrl     $Script:TarUrl `
            -RunnerUser $Script:RunnerUser `
            -CacheDir   $Script:Paths.CacheDir

        $owner = Invoke-SshQuery "stat -c '%U' '$($Script:Paths.TarPath)'"
        $owner | Should -Be $Script:RunnerUser
    }
}
