BeforeAll {
    function Invoke-SshClientCommand {
        param($SshClient, $Command, $ErrorAction)
    }

    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\registration\up\binary\Invoke-TarballDownload.ps1"

    $Script:FakeSsh  = [PSCustomObject] @{}
    $Script:CacheDir = '/home/u-actions-runner/cache'
    $Script:TarPath  = '/home/u-actions-runner/cache/actions-runner-linux-x64-2.317.0.tar.gz'
}

Describe 'Invoke-TarballDownload' {

    Context 'cache directory' {
        It 'creates the cache directory as the runner user' {
            Mock Invoke-SshClientCommand { [PSCustomObject] @{ ExitStatus = 0; Error = '' } }

            Invoke-TarballDownload `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -RunnerUser    'u-actions-runner' `
                -RunnerVersion '2.317.0' `
                -CacheDir      $Script:CacheDir `
                -TarPath       $Script:TarPath

            Should -Invoke Invoke-SshClientCommand -Times 1 -ParameterFilter {
                $Command -like "sudo -u u-actions-runner mkdir -p '$Script:CacheDir'"
            }
        }

        It 'throws when the cache directory cannot be created' {
            Mock Invoke-SshClientCommand { [PSCustomObject] @{ ExitStatus = 1; Error = 'permission denied' } }

            { Invoke-TarballDownload `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -RunnerUser    'u-actions-runner' `
                -RunnerVersion '2.317.0' `
                -CacheDir      $Script:CacheDir `
                -TarPath       $Script:TarPath
            } | Should -Throw '*Failed to create cache directory*'
        }
    }

    Context 'tarball already cached' {
        It 'skips purge and download when the tarball is present' {
            Mock Invoke-SshClientCommand {
                # Both mkdir and test -f succeed.
                [PSCustomObject] @{ ExitStatus = 0; Error = '' }
            }

            Invoke-TarballDownload `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -RunnerUser    'u-actions-runner' `
                -RunnerVersion '2.317.0' `
                -CacheDir      $Script:CacheDir `
                -TarPath       $Script:TarPath

            Should -Invoke Invoke-SshClientCommand -Times 0 -ParameterFilter {
                $Command -like '*curl*'
            }
            Should -Invoke Invoke-SshClientCommand -Times 0 -ParameterFilter {
                $Command -like '*rm -f*'
            }
        }
    }

    Context 'tarball absent' {
        BeforeEach {
            Mock Invoke-SshClientCommand {
                param($SshClient, $Command)
                $exit = if ($Command -like 'test -f*') { 1 } else { 0 }
                [PSCustomObject] @{ ExitStatus = $exit; Error = '' }
            }
        }

        It 'purges stale tarballs before downloading' {
            Invoke-TarballDownload `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -RunnerUser    'u-actions-runner' `
                -RunnerVersion '2.317.0' `
                -CacheDir      $Script:CacheDir `
                -TarPath       $Script:TarPath

            Should -Invoke Invoke-SshClientCommand -Times 1 -ParameterFilter {
                $Command -like "*rm -f '$Script:CacheDir'/actions-runner-*.tar.gz"
            }
        }

        It 'downloads the tarball for the requested version' {
            Invoke-TarballDownload `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -RunnerUser    'u-actions-runner' `
                -RunnerVersion '2.317.0' `
                -CacheDir      $Script:CacheDir `
                -TarPath       $Script:TarPath

            Should -Invoke Invoke-SshClientCommand -Times 1 -ParameterFilter {
                $Command -like '*curl*' -and $Command -like '*2.317.0*'
            }
        }

        It 'throws when purge fails' {
            Mock Invoke-SshClientCommand {
                param($SshClient, $Command)
                $exit = if ($Command -like 'test -f*') { 1 }
                        elseif ($Command -like '*rm -f*') { 1 }
                        else { 0 }
                [PSCustomObject] @{ ExitStatus = $exit; Error = 'permission denied' }
            }

            { Invoke-TarballDownload `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -RunnerUser    'u-actions-runner' `
                -RunnerVersion '2.317.0' `
                -CacheDir      $Script:CacheDir `
                -TarPath       $Script:TarPath
            } | Should -Throw '*Failed to purge stale tarballs*'
        }

        It 'throws when curl fails' {
            Mock Invoke-SshClientCommand {
                param($SshClient, $Command)
                $exit = if ($Command -like 'test -f*') { 1 }
                        elseif ($Command -like '*curl*') { 1 }
                        else { 0 }
                [PSCustomObject] @{ ExitStatus = $exit; Error = 'network error' }
            }

            { Invoke-TarballDownload `
                -SshClient     $Script:FakeSsh `
                -VmName        'vm-01' `
                -RunnerUser    'u-actions-runner' `
                -RunnerVersion '2.317.0' `
                -CacheDir      $Script:CacheDir `
                -TarPath       $Script:TarPath
            } | Should -Throw '*curl download failed*'
        }
    }
}
