BeforeAll {
    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\registration\common\infra\Get-RunnerPaths.ps1"
}

Describe 'Get-RunnerPaths' {

    Context 'path construction' {
        It 'derives CacheDir from the runner user home directory' {
            $paths = Get-RunnerPaths -RunnerUser 'u-runner' -RunnerVersion '2.317.0'
            $paths.CacheDir | Should -Be '/home/u-runner/cache'
        }

        It 'constructs TarName from the version' {
            $paths = Get-RunnerPaths -RunnerUser 'u-runner' -RunnerVersion '2.317.0'
            $paths.TarName | Should -Be 'actions-runner-linux-x64-2.317.0.tar.gz'
        }

        It 'constructs TarPath as CacheDir joined with TarName' {
            $paths = Get-RunnerPaths -RunnerUser 'u-runner' -RunnerVersion '2.317.0'
            $paths.TarPath | Should -Be '/home/u-runner/cache/actions-runner-linux-x64-2.317.0.tar.gz'
        }

        It 'constructs RunnerDir when RunnerName is provided' {
            $paths = Get-RunnerPaths -RunnerUser 'u-runner' -RunnerVersion '2.317.0' -RunnerName 'runner-a'
            $paths.RunnerDir | Should -Be '/home/u-runner/runners/runner-a'
        }

        It 'returns null RunnerDir when RunnerName is omitted' {
            $paths = Get-RunnerPaths -RunnerUser 'u-runner' -RunnerVersion '2.317.0'
            $paths.RunnerDir | Should -BeNullOrEmpty
        }

        It 'returns RunnerDir without RunnerVersion (deregistration path)' {
            $paths = Get-RunnerPaths -RunnerUser 'u-runner' -RunnerName 'runner-a'
            $paths.RunnerDir | Should -Be '/home/u-runner/runners/runner-a'
            $paths.TarName   | Should -BeNullOrEmpty
            $paths.TarPath   | Should -BeNullOrEmpty
        }
    }
}
