#!/usr/bin/env bash
# Resolves the actions/runner version and ensures the matching tarball is
# cached Windows-side, then reports both to the caller. This is the
# runner-domain half of the host-file-server flow: deciding WHICH tarball
# (and which version) to stage. The substrate file server
# (Common-Ansible ops/virtual-machines/_stage-host-fileserver.sh) only
# SERVES a directory - it no longer knows about runner tarballs - so this
# repo, which owns the runner domain, supplies the staged directory and the
# version through the CA_HOST_FILE_SERVER_* contract (see register-runners.sh).
#
# Two pwsh.exe round-trips, mirroring the resolve-then-cache steps the
# substrate helper used to own before the runner-tarball knowledge moved here:
#
#   1. Resolve the latest actions/runner version (_resolve-runner-version.ps1).
#   2. Ensure the matching tarball is cached (_ensure-runner-tarball.ps1); its
#      parent directory is what the file server serves.
#
# Output contract (stdout, in the order emitted):
#
#   RUNNER_VERSION=<x.y.z>
#   STAGING_DIR=<windows-form directory holding the tarball>
#
# Both keys are consumed by register-runners.sh, which exports them as
# CA_HOST_FILE_SERVER_VERSION / CA_HOST_FILE_SERVER_DIR for the bridge.
# Progress narration goes to stderr so it never corrupts the KEY=value
# contract on stdout.

set -euo pipefail

# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_log.sh
source "${BASH_SOURCE[0]%/*}/imports/_log.sh"
# _to_windows_path (shared from Common-Automation) turns the sibling .ps1
# paths into the Windows form pwsh.exe needs. The imports/ adapter owns the
# cross-repo resolution.
# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_to-windows-path.sh
source "${BASH_SOURCE[0]%/*}/imports/_to-windows-path.sh"
# Generic unknown-flag handler lives in the substrate; reach it through the
# 3.1 sibling-checkout resolver rather than duplicating it here.
# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_common-ansible-root.sh
source "${BASH_SOURCE[0]%/*}/imports/_common-ansible-root.sh"
# shellcheck source=/dev/null
source "${common_ansible_root}/ops/_die-on-unknown-flag.sh"

token=""
token_set=0

usage() {
    echo "usage: _stage-runner-tarball.sh --github-token <value>" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --github-token)
            # ${2-} (no colon) so a literal empty value reaches the
            # non-empty check below rather than being silently dropped
            # by parameter expansion's default branch.
            token="${2-}"
            token_set=1
            shift 2 || true
            ;;
        *)
            _die_on_unknown_flag "$1"
            ;;
    esac
done

if [[ "${token_set}" -ne 1 || -z "${token}" ]]; then
    usage
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# 1. Resolve runner version. The trailing `tail -n1` strips any chatter
#    pwsh.exe prints before the function's return value. Capture pwsh.exe's
#    stderr - where _resolve-runner-version.ps1 writes e.g. "401 - check the
#    GH_TOKEN scopes" - to a temp file rather than discarding it, so a
#    failure surfaces the cause instead of dying silently under pipefail.
# ---------------------------------------------------------------------------
log_info "Resolving latest actions/runner version via GitHub API ..."
resolve_ps1="$(_to_windows_path "${script_dir}/_resolve-runner-version.ps1")"
resolve_err="$(mktemp)"
runner_version=""
if runner_version="$(pwsh.exe -NoProfile -NoLogo \
        -File "${resolve_ps1}" \
        -Token "${token}" 2>"${resolve_err}" \
        | tr -d '\r' | tail -n1)" && [[ -n "${runner_version}" ]]; then
    rm -f "${resolve_err}"
else
    log_err "failed to resolve runner version (GitHub API error below):"
    while IFS= read -r line; do
        [[ -n "${line}" ]] && log_err "  ${line}"
    done < "${resolve_err}"
    rm -f "${resolve_err}"
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Ensure the tarball is cached. The PowerShell helper returns the absolute
#    Windows path; its parent directory is what the substrate file server
#    serves, so future toolchain payloads can stage alongside it untouched.
# ---------------------------------------------------------------------------
log_info "Ensuring runner tarball ${runner_version} is cached (downloads ~100MB on a cache miss) ..."
ensure_ps1="$(_to_windows_path "${script_dir}/_ensure-runner-tarball.ps1")"
tar_path="$(pwsh.exe -NoProfile -NoLogo \
    -File "${ensure_ps1}" \
    -Version "${runner_version}" 2>/dev/null \
    | tr -d '\r' | tail -n1)"
if [[ -z "${tar_path}" ]]; then
    log_err "failed to stage runner tarball"
    exit 1
fi
# tar_path is a Windows path (Join-Path output, e.g.
# C:\Users\...\runner-cache\actions-...tar.gz). bash `dirname` keys on '/' and
# would return '.' for a backslash path, so strip the last component directly
# - the result stays in Windows form, which is what the listener's
# -StagingDir argument needs.
staging_dir="${tar_path%[\\/]*}"
log_info "Runner tarball ready: ${tar_path}"

# ---------------------------------------------------------------------------
# 3. Emit the two contract lines for register-runners.sh to parse.
# ---------------------------------------------------------------------------
printf 'RUNNER_VERSION=%s\n' "${runner_version}"
printf 'STAGING_DIR=%s\n'    "${staging_dir}"
