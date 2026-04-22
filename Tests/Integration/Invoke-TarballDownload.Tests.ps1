# Integration tests for Invoke-TarballDownload against a real SSH session.
# See Initialize-SshEnvironment.ps1 for environment details and isolation notes.
#
# All tests pre-seed the tarball so the function exits at the cache-hit
# branch without attempting a curl download. Integration value: real
# sudo -u ownership assertions that unit tests cannot provide.
# Directory creation and purge logic are covered by unit tests.

BeforeAll {
    . "$PSScriptRoot\Initialize-SshEnvironment.ps1"
}

AfterAll { . "$PSScriptRoot\Remove-SshEnvironment.ps1" }

Describe 'Invoke-TarballDownload' {

    AfterEach {
        & bash -c "rm -rf '/home/$($Script:RunnerUser)/cache'"
    }

    BeforeEach {
        $Script:Paths = Get-RunnerPaths `
            -RunnerUser    $Script:RunnerUser `
            -RunnerVersion $Script:RunnerVersion

        # Pre-seed the tarball so the function hits the cache-hit branch
        # and does not attempt a real curl download.
        & bash -c "mkdir -p '$($Script:Paths.CacheDir)' && \
            cp '$Script:FakeTarball' '$($Script:Paths.TarPath)' && \
            chown -R ${Script:RunnerUser}: '$($Script:Paths.CacheDir)'"
    }

    It 'does not modify the tarball when it is already cached' {
        $mtimeBefore = Invoke-SshQuery "stat -c '%Y' '$($Script:Paths.TarPath)'"

        Invoke-TarballDownload `
            -SshClient     $Script:SshClient `
            -VmName        $Script:VmName `
            -RunnerUser    $Script:RunnerUser `
            -RunnerVersion $Script:RunnerVersion `
            -CacheDir      $Script:Paths.CacheDir `
            -TarPath       $Script:Paths.TarPath

        $mtimeAfter = Invoke-SshQuery "stat -c '%Y' '$($Script:Paths.TarPath)'"
        $mtimeAfter | Should -Be $mtimeBefore
    }

    It 'leaves the cached tarball owned by the runner user' {
        Invoke-TarballDownload `
            -SshClient     $Script:SshClient `
            -VmName        $Script:VmName `
            -RunnerUser    $Script:RunnerUser `
            -RunnerVersion $Script:RunnerVersion `
            -CacheDir      $Script:Paths.CacheDir `
            -TarPath       $Script:Paths.TarPath

        $owner = Invoke-SshQuery "stat -c '%U' '$($Script:Paths.TarPath)'"
        $owner | Should -Be $Script:RunnerUser
    }
}
