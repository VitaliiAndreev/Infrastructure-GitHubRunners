#!/usr/bin/env bats
# Tests for ops/deregister-runners.sh - the operator entry for the deregister
# flow. Scope mirrors register-runners.bats: prompt / contract wiring only,
# plus the --force translation this entry owns. The substrate bridge's
# orchestration is owned by Common-Ansible's _run-playbook.bats, which this
# suite stubs the same way (a stub _run-playbook.sh in a transplanted ops/
# tree reached through COMMON_ANSIBLE_ROOT).
#
# Two differences from register-runners.bats worth pinning explicitly (each
# has its own test below):
#   - CA_NEEDS_HOST_FILE_SERVER must stay unset and nothing is staged (the
#     down path fetches nothing; spawning the HttpListener would be a port and
#     a failure surface for no consumer).
#   - --force is consumed by the wrapper and translated to
#     --extra-vars runners_force_remove=true. ansible-playbook has no --force
#     flag, so forwarding it verbatim would just produce a parse error.
# Run with: bats Tests/ops/deregister-runners.bats

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

# shellcheck source=Tests/ops/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"

setup() {
    _bats_init_temp deregisterRunners
    TEST_REPO="${TEST_TMP}/repo"
    mkdir -p "${TEST_REPO}/ops" "${TEST_REPO}/playbooks"

    cp "${REPO_ROOT}/ops/deregister-runners.sh" "${TEST_REPO}/ops/"
    chmod +x "${TEST_REPO}/ops/deregister-runners.sh"
    # The entry sources ops/imports/_log.sh (logger adapter) and
    # ops/imports/_common-ansible-root.sh (substrate resolver); copy imports/
    # so both source resolves. The logger adapter loads scripts/log.sh from
    # the COMMON_AUTOMATION_ROOT stub _bats_init_temp stands up.
    cp -r "${REPO_ROOT}/ops/imports" "${TEST_REPO}/ops/"
    # Shared GH_TOKEN-acquisition helper the entry sources.
    cp "${REPO_ROOT}/ops/_require-gh-token.sh" "${TEST_REPO}/ops/"

    # The entry reaches the substrate bridge via COMMON_ANSIBLE_ROOT; point it
    # at the transplanted tree so the stub bridge below is what runs.
    export COMMON_ANSIBLE_ROOT="${TEST_REPO}"

    export TRACE_FILE="${TEST_TMP}/trace"
    : > "${TRACE_FILE}"

    cat >"${TEST_REPO}/ops/_run-playbook.sh" <<'STUB'
#!/usr/bin/env bash
{
    printf 'CA_INVENTORY_VAULT=%s\n'        "${CA_INVENTORY_VAULT:-}"
    printf 'CA_EXTRA_VAULTS=%s\n'           "${CA_EXTRA_VAULTS:-}"
    printf 'CA_REQUIRES_TOKEN=%s\n'         "${CA_REQUIRES_TOKEN:-}"
    printf 'CA_NEEDS_HOST_FILE_SERVER=%s\n' "${CA_NEEDS_HOST_FILE_SERVER:-}"
    printf 'CA_CONSUMER_ROOT=%s\n'          "${CA_CONSUMER_ROOT:-}"
    printf 'GH_TOKEN=%s\n'                  "${GH_TOKEN:-}"
    printf 'ARGV=%s\n'                      "$*"
} >> "${TRACE_FILE}"
STUB
    chmod +x "${TEST_REPO}/ops/_run-playbook.sh"
}

teardown() {
    _bats_cleanup_temp
}

@test "GH_TOKEN already set: no prompt, contract correct, no force, no file server" {
    GH_TOKEN='ghp_preset' \
        run "${BASH_BIN}" "${TEST_REPO}/ops/deregister-runners.sh"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"GitHub token:"* ]]

    trace="$(cat "${TRACE_FILE}")"
    # Same runner contract as register, minus the host file server.
    [[ "${trace}" == *"CA_INVENTORY_VAULT=VmProvisioner"* ]]
    [[ "${trace}" == *"CA_EXTRA_VAULTS=GitHubRunners"* ]]
    [[ "${trace}" == *"CA_REQUIRES_TOKEN=1"* ]]
    [[ "${trace}" == *"CA_CONSUMER_ROOT=${TEST_REPO}"* ]]
    # File-server gate must be empty on the down path - the down roles fetch
    # nothing and the listener would be pure overhead.
    [[ "${trace}" == *"CA_NEEDS_HOST_FILE_SERVER="$'\n'* ]]
    [[ "${trace}" == *"GH_TOKEN=ghp_preset"* ]]
    # No --force on this invocation -> no runners_force_remove extra-var.
    [[ "${trace}" != *"runners_force_remove"* ]]
    [[ "${trace}" == *"ARGV=playbooks/deregister-runners.yml"* ]]
}

@test "GH_TOKEN unset and stdin not a TTY: fast-fails with exit 2, bridge never invoked" {
    run env -u GH_TOKEN "${BASH_BIN}" -c \
        "printf '' | '${TEST_REPO}/ops/deregister-runners.sh'"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"GH_TOKEN must be set for unattended use"* ]]

    [ ! -s "${TRACE_FILE}" ]
}

@test "--force is consumed and translated to runners_force_remove=true" {
    GH_TOKEN='ghp_preset' \
        run "${BASH_BIN}" "${TEST_REPO}/ops/deregister-runners.sh" --force
    [ "${status}" -eq 0 ]

    trace="$(cat "${TRACE_FILE}")"
    [[ "${trace}" == *"ARGV=playbooks/deregister-runners.yml --extra-vars runners_force_remove=true"* ]]
    [[ "${trace}" != *"--force"* ]]
}

@test "Other args (--tags, --check, -v) are forwarded verbatim" {
    GH_TOKEN='ghp_preset' \
        run "${BASH_BIN}" "${TEST_REPO}/ops/deregister-runners.sh" \
            --tags runner_binary --check -v
    [ "${status}" -eq 0 ]

    trace="$(cat "${TRACE_FILE}")"
    [[ "${trace}" == *"ARGV=playbooks/deregister-runners.yml --tags runner_binary --check -v"* ]]
}

@test "--force plus extra args: translation and forwarding compose" {
    GH_TOKEN='ghp_preset' \
        run "${BASH_BIN}" "${TEST_REPO}/ops/deregister-runners.sh" \
            --force --tags runner_binary --check
    [ "${status}" -eq 0 ]

    trace="$(cat "${TRACE_FILE}")"
    [[ "${trace}" == *"ARGV=playbooks/deregister-runners.yml --tags runner_binary --check --extra-vars runners_force_remove=true"* ]]
}
