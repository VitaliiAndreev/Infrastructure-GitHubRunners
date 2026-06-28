#!/usr/bin/env bats
# Tests for ops/_stage-runner-tarball.sh - the runner-domain pre-staging
# helper. It drives two pwsh.exe round-trips (resolve version, ensure tarball)
# and emits RUNNER_VERSION + STAGING_DIR on stdout for register-runners.sh to
# export as CA_HOST_FILE_SERVER_*.
#
# Scope: argument validation, pwsh.exe dispatch, error surfacing, and stdout
# shape. The two PowerShell helpers have their own Pester coverage; the
# pwsh.exe stub on PATH discriminates by `-File <basename>`.
#
# The helper reaches the substrate's unknown-flag handler through the
# Common-Ansible sibling checkout, so the suite points COMMON_ANSIBLE_ROOT at
# it and skips when absent.
# Run with: bats Tests/ops/_stage-runner-tarball.bats

SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../../ops" && pwd)/_stage-runner-tarball.sh"
SUBSTRATE_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../../Common-Ansible" 2>/dev/null && pwd || true)"

# shellcheck source=Tests/ops/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"

setup() {
    if [[ -z "${SUBSTRATE_ROOT}" || ! -f "${SUBSTRATE_ROOT}/ops/_die-on-unknown-flag.sh" ]]; then
        skip "Common-Ansible substrate sibling not checked out next to this repo"
    fi
    _bats_init_temp stageRunnerTarball
    export COMMON_ANSIBLE_ROOT="${SUBSTRATE_ROOT}"

    # pwsh.exe stub on PATH. The -File basename selects the branch.
    STUBS="${TEST_TMP}/stubs"
    mkdir -p "${STUBS}"
    export PWSH_INVOCATIONS_LOG="${TEST_TMP}/pwsh-invocations.log"
    : > "${PWSH_INVOCATIONS_LOG}"

    cat >"${STUBS}/pwsh.exe" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${PWSH_INVOCATIONS_LOG}"
file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -File) file="$2"; shift 2 ;;
        *)     shift ;;
    esac
done
case "${file##*[\\/]}" in
    _resolve-runner-version.ps1)
        if [[ -n "${PWSH_STUB_VERSION_EXIT:-}" && "${PWSH_STUB_VERSION_EXIT}" != "0" ]]; then
            echo "${PWSH_STUB_VERSION_STDERR:-Resolve-RunnerVersion: GitHub returned 401 - check the GH_TOKEN scopes.}" >&2
            exit "${PWSH_STUB_VERSION_EXIT}"
        fi
        echo "${PWSH_STUB_VERSION:-2.999.0}"
        ;;
    _ensure-runner-tarball.ps1)
        # ${VAR-default} (no colon) so an explicitly empty PWSH_STUB_TAR stays
        # empty - the "staging produced nothing" path the helper must catch.
        echo "${PWSH_STUB_TAR-C:\\Users\\Test\\AppData\\Local\\Temp\\runner-cache\\actions-runner-linux-x64-2.999.0.tar.gz}"
        ;;
    *)
        echo "pwsh-stub: unhandled file=${file}" >&2
        exit 99
        ;;
esac
STUB
    chmod +x "${STUBS}/pwsh.exe"
    export PATH="${STUBS}:${PATH}"

    # _to_windows_path lives in Common-Automation, mocked here as a
    # passthrough (the pwsh stub keys off the file basename either way). The
    # stub goes in the COMMON_AUTOMATION_ROOT _bats_init_temp stands up.
    cat >"${COMMON_AUTOMATION_ROOT}/scripts/_to-windows-path.sh" <<'STUB'
#!/usr/bin/env bash
_to_windows_path() { printf '%s' "$1"; }
STUB
}

teardown() {
    _bats_cleanup_temp
}

@test "fails with usage when --github-token is missing" {
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"usage:"* ]]
}

@test "fails with usage when --github-token is the empty string" {
    run "${BASH_BIN}" "${SCRIPT}" --github-token ""
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"usage:"* ]]
}

@test "fails with usage on unknown flag" {
    run "${BASH_BIN}" "${SCRIPT}" --unknown-thing x
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"unknown argument"* ]]
}

@test "happy path emits RUNNER_VERSION and the tarball's parent directory" {
    export PWSH_STUB_VERSION="2.999.0"
    export PWSH_STUB_TAR='C:\Users\Test\AppData\Local\Temp\runner-cache\actions-runner-linux-x64-2.999.0.tar.gz'

    run "${BASH_BIN}" "${SCRIPT}" --github-token "ghp_x"
    [ "${status}" -eq 0 ]

    [[ "${output}" == *"RUNNER_VERSION=2.999.0"* ]]
    # STAGING_DIR is the tarball's parent, stripped on either separator and
    # kept in Windows form for the listener's -StagingDir.
    [[ "${output}" == *'STAGING_DIR=C:\Users\Test\AppData\Local\Temp\runner-cache'* ]]
}

@test "runner version resolution failure surfaces the resolver's stderr and aborts" {
    export PWSH_STUB_VERSION_EXIT=1
    export PWSH_STUB_VERSION_STDERR="Resolve-RunnerVersion: GitHub returned 401 - check the GH_TOKEN scopes."

    run "${BASH_BIN}" "${SCRIPT}" --github-token "ghp_x"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"failed to resolve runner version"* ]]
    [[ "${output}" == *"401 - check the GH_TOKEN scopes"* ]]
    # Aborts before the ensure round-trip.
    ! grep -q '_ensure-runner-tarball.ps1' "${PWSH_INVOCATIONS_LOG}"
}

@test "tarball staging failure aborts the helper" {
    export PWSH_STUB_TAR=""
    run "${BASH_BIN}" "${SCRIPT}" --github-token "ghp_x"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"failed to stage runner tarball"* ]]
}
