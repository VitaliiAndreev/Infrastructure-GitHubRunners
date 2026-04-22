# Integration tests for Invoke-RunnerExtract against a real SSH session.
# See Initialize-SshEnvironment.ps1 for environment details and isolation notes.

BeforeAll {
    . "$PSScriptRoot\Initialize-SshEnvironment.ps1"
}

AfterAll { . "$PSScriptRoot\Remove-SshEnvironment.ps1" }

Describe 'Invoke-RunnerExtract' {

    AfterEach {
        & bash -c "rm -rf '/home/$($Script:RunnerUser)/runners'"
    }

    BeforeEach {
        $Script:Paths = Get-RunnerPaths `
            -RunnerUser    $Script:RunnerUser `
            -RunnerVersion $Script:RunnerVersion `
            -RunnerName    'test-runner'

        # Pre-seed the cache with the fake tarball so Invoke-RunnerExtract
        # has a valid source archive to extract from.
        & bash -c "mkdir -p '$($Script:Paths.CacheDir)' && \
            cp '$Script:FakeTarball' '$($Script:Paths.TarPath)' && \
            chown -R ${Script:RunnerUser}: '$($Script:Paths.CacheDir)'"
    }

    It 'creates the runner directory when it is absent' {
        Invoke-RunnerExtract `
            -SshClient     $Script:SshClient `
            -VmName        $Script:VmName `
            -RunnerUser    $Script:RunnerUser `
            -RunnerVersion $Script:RunnerVersion `
            -RunnerName    'test-runner' `
            -RunnerDir     $Script:Paths.RunnerDir `
            -TarPath       $Script:Paths.TarPath

        $exists = Invoke-SshQuery "test -d '$($Script:Paths.RunnerDir)' && echo yes || echo no"
        $exists | Should -Be 'yes'
    }

    It 'creates the runner directory owned by the runner user' {
        Invoke-RunnerExtract `
            -SshClient     $Script:SshClient `
            -VmName        $Script:VmName `
            -RunnerUser    $Script:RunnerUser `
            -RunnerVersion $Script:RunnerVersion `
            -RunnerName    'test-runner' `
            -RunnerDir     $Script:Paths.RunnerDir `
            -TarPath       $Script:Paths.TarPath

        $owner = Invoke-SshQuery "stat -c '%U' '$($Script:Paths.RunnerDir)'"
        $owner | Should -Be $Script:RunnerUser
    }

    It 'extracts tarball contents into the runner directory' {
        Invoke-RunnerExtract `
            -SshClient     $Script:SshClient `
            -VmName        $Script:VmName `
            -RunnerUser    $Script:RunnerUser `
            -RunnerVersion $Script:RunnerVersion `
            -RunnerName    'test-runner' `
            -RunnerDir     $Script:Paths.RunnerDir `
            -TarPath       $Script:Paths.TarPath

        # The fake tarball contains run.sh (created in Initialize-SshEnvironment.ps1).
        $exists = Invoke-SshQuery "test -f '$($Script:Paths.RunnerDir)/run.sh' && echo yes || echo no"
        $exists | Should -Be 'yes'
    }

    It 'is idempotent when the runner directory already exists' {
        Invoke-RunnerExtract `
            -SshClient     $Script:SshClient `
            -VmName        $Script:VmName `
            -RunnerUser    $Script:RunnerUser `
            -RunnerVersion $Script:RunnerVersion `
            -RunnerName    'test-runner' `
            -RunnerDir     $Script:Paths.RunnerDir `
            -TarPath       $Script:Paths.TarPath

        $mtimeBefore = Invoke-SshQuery "stat -c '%Y' '$($Script:Paths.RunnerDir)'"

        Invoke-RunnerExtract `
            -SshClient     $Script:SshClient `
            -VmName        $Script:VmName `
            -RunnerUser    $Script:RunnerUser `
            -RunnerVersion $Script:RunnerVersion `
            -RunnerName    'test-runner' `
            -RunnerDir     $Script:Paths.RunnerDir `
            -TarPath       $Script:Paths.TarPath

        $mtimeAfter = Invoke-SshQuery "stat -c '%Y' '$($Script:Paths.RunnerDir)'"
        $mtimeAfter | Should -Be $mtimeBefore
    }
}
