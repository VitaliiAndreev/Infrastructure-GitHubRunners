<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    register-runners.ps1 after Infrastructure.Common and Infrastructure.Secrets
    are loaded.
#>

# ---------------------------------------------------------------------------
# Read-VmDeployPasswords
#   Reads the VmUsersConfig secret from the VmUsers vault - the canonical
#   source of deploy credentials - and returns a hashtable indexed by
#   "vmName|username" for O(1) lookup during the join step.
#
#   Only users that have a 'password' field are indexed; users without one
#   are silently skipped (they may use key-based auth instead).
# ---------------------------------------------------------------------------

function Read-VmDeployPasswords {
    [CmdletBinding()]
    param()

    Write-Host "Reading VmUsersConfig from VmUsers vault ..." -ForegroundColor Cyan

    $json   = Get-InfrastructureSecret `
                  -VaultName  'VmUsers' `
                  -SecretName 'VmUsersConfig'
    # Assign before wrapping with @(): in PS 7, ConvertFrom-Json emits the
    # array as a single pipeline item, so @($pipeline) wraps it in a 1-element
    # array. @($variable) unrolls an existing array and gives the correct count.
    $parsed = $json | ConvertFrom-Json
    $vms    = @($parsed)

    # Index by "vmName|username" so Join-RunnerDeployCredentials can resolve
    # credentials in O(1) rather than scanning the list per runner entry.
    $index = @{}
    foreach ($vm in $vms) {
        # Select-Object -ExpandProperty with SilentlyContinue avoids
        # StrictMode errors: ConvertFrom-Json in PS 5.1 omits properties
        # whose JSON value is an empty array, so 'users' may not exist.
        $usersValue = $vm | Select-Object -ExpandProperty users `
                                -ErrorAction SilentlyContinue
        foreach ($user in @($usersValue)) {
            if ($null -eq $user) { continue }
            # Same guard for 'password': users without it use key-based auth.
            $pwValue = $user | Select-Object -ExpandProperty password `
                                   -ErrorAction SilentlyContinue
            if ($null -ne $pwValue) {
                # Passwords are plain strings throughout this pipeline.
                # They originate as JSON field values - ConvertFrom-Json
                # always produces [string], never [SecureString]. Converting
                # to SecureString here would require converting back at every
                # consumer (SSH.NET PasswordAuthenticationMethod, chpasswd,
                # cloud-init YAML) because all three require plain text.
                # Protection relies on vault encryption at rest and the
                # short in-memory lifetime of the script session.
                $key         = "$($vm.vmName)|$($user.username)"
                $index[$key] = $pwValue
            }
        }
    }

    Write-Host "OK - $($index.Count) deploy credential(s) indexed from VmUsersConfig." `
        -ForegroundColor Green
    $index
}
