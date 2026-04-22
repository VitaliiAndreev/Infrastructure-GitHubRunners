# Integration tests for Invoke-RunnerInstall against a real SSH session.
# See Initialize-SshEnvironment.ps1 for environment details and isolation notes.
#
# Invoke-RunnerInstall orchestrates TarballDownload + RunnerExtract. Tests
# here verify end-to-end filesystem state rather than re-testing each
# function's internal behavior.

BeforeAll {
    . "$PSScriptRoot\Initialize-SshEnvironment.ps1"
}

AfterAll { . "$PSScriptRoot\Remove-SshEnvironment.ps1" }

Describe 'Invoke-RunnerInstall' {

    AfterEach {
        & bash -c "rm -rf '/home/$($Script:RunnerUser)/cache' '/home/$($Script:RunnerUser)/runners'"
    }

    BeforeEach {
        # Pre-seed the fake tarball in the cache so TarballDownload hits the
        # cache-hit branch and does not attempt a real curl download.
        $cachePaths = Get-RunnerPaths -RunnerUser $Script:RunnerUser -RunnerVersion $Script:RunnerVersion
        & bash -c "mkdir -p '$($cachePaths.CacheDir)' && \
            cp '$Script:FakeTarball' '$($cachePaths.TarPath)' && \
            chown -R ${Script:RunnerUser}: '$($cachePaths.CacheDir)'"
    }

    It 'creates the runner directory for a single entry' {
        $entry = [PSCustomObject] @{
            runnerName     = 'test-runner-a'
            runnerUsername = $Script:RunnerUser
        }
        $paths = Get-RunnerPaths `
            -RunnerUser    $Script:RunnerUser `
            -RunnerVersion $Script:RunnerVersion `
            -RunnerName    $entry.runnerName

        Invoke-RunnerInstall `
            -SshClient     $Script:SshClient `
            -VmName        $Script:VmName `
            -RunnerEntries @($entry) `
            -RunnerVersion $Script:RunnerVersion

        $exists = Invoke-SshQuery "test -d '$($paths.RunnerDir)' && echo yes || echo no"
        $exists | Should -Be 'yes'
    }

    It 'creates a separate directory for each runner entry' {
        $entryA = [PSCustomObject] @{ runnerName = 'test-runner-a'; runnerUsername = $Script:RunnerUser }
        $entryB = [PSCustomObject] @{ runnerName = 'test-runner-b'; runnerUsername = $Script:RunnerUser }

        Invoke-RunnerInstall `
            -SshClient     $Script:SshClient `
            -VmName        $Script:VmName `
            -RunnerEntries @($entryA; $entryB) `
            -RunnerVersion $Script:RunnerVersion

        $pathsA = Get-RunnerPaths -RunnerUser $Script:RunnerUser -RunnerVersion $Script:RunnerVersion -RunnerName 'test-runner-a'
        $pathsB = Get-RunnerPaths -RunnerUser $Script:RunnerUser -RunnerVersion $Script:RunnerVersion -RunnerName 'test-runner-b'

        $existsA = Invoke-SshQuery "test -d '$($pathsA.RunnerDir)' && echo yes || echo no"
        $existsB = Invoke-SshQuery "test -d '$($pathsB.RunnerDir)' && echo yes || echo no"
        $existsA | Should -Be 'yes'
        $existsB | Should -Be 'yes'
    }

    It 'is idempotent when run twice' {
        $entry = [PSCustomObject] @{
            runnerName     = 'test-runner-a'
            runnerUsername = $Script:RunnerUser
        }
        $paths = Get-RunnerPaths `
            -RunnerUser    $Script:RunnerUser `
            -RunnerVersion $Script:RunnerVersion `
            -RunnerName    $entry.runnerName

        Invoke-RunnerInstall `
            -SshClient     $Script:SshClient `
            -VmName        $Script:VmName `
            -RunnerEntries @($entry) `
            -RunnerVersion $Script:RunnerVersion

        $mtimeBefore = Invoke-SshQuery "stat -c '%Y' '$($paths.RunnerDir)'"

        { Invoke-RunnerInstall `
            -SshClient     $Script:SshClient `
            -VmName        $Script:VmName `
            -RunnerEntries @($entry) `
            -RunnerVersion $Script:RunnerVersion
        } | Should -Not -Throw

        $mtimeAfter = Invoke-SshQuery "stat -c '%Y' '$($paths.RunnerDir)'"
        $mtimeAfter | Should -Be $mtimeBefore
    }
}
