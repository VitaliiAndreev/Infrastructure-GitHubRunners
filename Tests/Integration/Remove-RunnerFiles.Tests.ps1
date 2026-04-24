# Integration tests for Remove-RunnerFiles against a real SSH session.
# See Initialize-SshEnvironment.ps1 for environment details and isolation notes.

BeforeAll {
    . "$PSScriptRoot\Initialize-SshEnvironment.ps1"

    $src = [IO.Path]::Combine($PSScriptRoot, '..', '..', 'hyper-v', 'ubuntu')
    . ([IO.Path]::Combine($src, 'registration', 'down', 'binary', 'Remove-RunnerFiles.ps1'))

    # RunnerDir for all tests - no version needed for deregistration paths.
    $Script:Paths = Get-RunnerPaths `
        -RunnerUser $Script:RunnerUser `
        -RunnerName 'test-runner'
}

AfterAll { . "$PSScriptRoot\Remove-SshEnvironment.ps1" }

Describe 'Remove-RunnerFiles' {

    AfterEach {
        # Ensure the runner directory is absent between tests regardless of
        # whether the test itself removed it or left it.
        & bash -c "rm -rf '$($Script:Paths.RunnerDir)'"
    }

    It 'removes the runner directory when it exists' {
        & bash -c "mkdir -p '$($Script:Paths.RunnerDir)' && \
            chown -R ${Script:RunnerUser}: '$($Script:Paths.RunnerDir)'"

        Remove-RunnerFiles `
            -SshClient  $Script:SshClient `
            -VmName     $Script:VmName `
            -RunnerName 'test-runner' `
            -RunnerDir  $Script:Paths.RunnerDir

        $exists = Invoke-SshQuery "test -d '$($Script:Paths.RunnerDir)' && echo yes || echo no"
        $exists | Should -Be 'no'
    }

    It 'removes all files within the runner directory' {
        & bash -c "mkdir -p '$($Script:Paths.RunnerDir)' && \
            touch '$($Script:Paths.RunnerDir)/run.sh' && \
            touch '$($Script:Paths.RunnerDir)/config.sh' && \
            chown -R ${Script:RunnerUser}: '$($Script:Paths.RunnerDir)'"

        Remove-RunnerFiles `
            -SshClient  $Script:SshClient `
            -VmName     $Script:VmName `
            -RunnerName 'test-runner' `
            -RunnerDir  $Script:Paths.RunnerDir

        $exists = Invoke-SshQuery "test -d '$($Script:Paths.RunnerDir)' && echo yes || echo no"
        $exists | Should -Be 'no'
    }

    It 'does not throw when the runner directory is already absent' {
        # Directory was never created - idempotency guarantee.
        { Remove-RunnerFiles `
            -SshClient  $Script:SshClient `
            -VmName     $Script:VmName `
            -RunnerName 'test-runner' `
            -RunnerDir  $Script:Paths.RunnerDir } | Should -Not -Throw
    }
}
