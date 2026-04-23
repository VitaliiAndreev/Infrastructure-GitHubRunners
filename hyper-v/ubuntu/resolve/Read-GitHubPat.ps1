<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    register-runners.ps1 after Infrastructure.Common is loaded.
#>

# ---------------------------------------------------------------------------
# Read-GitHubPat
#   Prompts the operator for a GitHub PAT and returns it as a plain-text
#   string for use in Authorization headers.
#
#   The PAT is held in memory only for the duration of the script and is
#   never written to disk, logged, or passed as a command-line argument.
#   Required scope: 'repo' for private repos, 'public_repo' for public.
# ---------------------------------------------------------------------------

function Read-GitHubPat {
    [CmdletBinding()]
    param()

    $secPat = Read-Host -Prompt 'GitHub PAT (repo scope for private, public_repo for public)' `
                        -AsSecureString
    # BSTR conversion is the standard Windows approach for reading a
    # SecureString value. The result is used only in Authorization headers
    # and is never written to any output stream.
    [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPat))
}
