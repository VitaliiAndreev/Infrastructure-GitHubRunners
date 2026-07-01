#!/usr/bin/env bats
# Tests for ops/register-runners.sh - the operator entry that owns
# token-prompting, pre-stages the runner tarball, and declares the CA_*
# consumer contract (GitHubRunners vault + token + host file server + the
# staged directory/version + this repo's CA_CONSUMER_ROOT). Scope here is the
# prompt / staging / contract wiring only: the substrate bridge's
# orchestration is owned by Common-Ansible's _run-playbook.bats, which this
# suite stubs alongside the runner-tarball pre-staging helper.
#
# The entry anchors its sibling lookup to its own BASH_SOURCE dir and reaches
# the substrate bridge through the COMMON_ANSIBLE_ROOT resolver, so this suite
# transplants register-runners.sh into a throwaway ops/ tree, points
# COMMON_ANSIBLE_ROOT at that same tree, and drops stub _run-playbook.sh /
# _stage-runner-tarball.sh next to it; the bridge stub records the invocation
# environment so the prompt / contract branches can be asserted.
# Run with: bats Tests/ops/register-runners.bats

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

# shellcheck source=Tests/ops/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"

setup() {
    _bats_init_temp registerRunners
    TEST_REPO="${TEST_TMP}/repo"
    mkdir -p "${TEST_REPO}/ops" "${TEST_REPO}/playbooks"

    cp "${REPO_ROOT}/ops/register-runners.sh" "${TEST_REPO}/ops/"
    chmod +x "${TEST_REPO}/ops/register-runners.sh"
    # The entry sources ops/imports/_log.sh (cross-repo logger adapter) for
    # its log helpers and ops/imports/_common-ansible-root.sh to find the
    # substrate bridge; copy the imports/ folder so both source resolves. The
    # logger adapter loads scripts/log.sh from the COMMON_AUTOMATION_ROOT stub
    # _bats_init_temp stands up.
    cp -r "${REPO_ROOT}/ops/imports" "${TEST_REPO}/ops/"
    # Shared GH_TOKEN-acquisition helper the entry sources; copy it next to
    # the transplanted script so its source resolves.
    cp "${REPO_ROOT}/ops/_require-gh-token.sh" "${TEST_REPO}/ops/"

    # The entry reaches the substrate bridge via COMMON_ANSIBLE_ROOT; point it
    # at the transplanted tree so the stub bridge below is what runs.
    export COMMON_ANSIBLE_ROOT="${TEST_REPO}"

    # Stub _stage-runner-tarball.sh: emits the version + staged directory the
    # entry exports as CA_HOST_FILE_SERVER_*. No pwsh round-trip in the test.
    cat >"${TEST_REPO}/ops/_stage-runner-tarball.sh" <<'STUB'
#!/usr/bin/env bash
printf 'RUNNER_VERSION=%s\n' "${STAGE_STUB_VERSION:-2.999.0}"
printf 'STAGING_DIR=%s\n'    "${STAGE_STUB_DIR:-C:\\Users\\Test\\runner-cache}"
STUB
    chmod +x "${TEST_REPO}/ops/_stage-runner-tarball.sh"

    # Stub _run-playbook.sh records the env and argv it was invoked with so
    # the entry's prompt / export contract can be asserted without running the
    # real bridge.
    export TRACE_FILE="${TEST_TMP}/trace"
    : > "${TRACE_FILE}"

    cat >"${TEST_REPO}/ops/_run-playbook.sh" <<'STUB'
#!/usr/bin/env bash
{
    printf 'CA_INVENTORY_VAULT=%s\n'          "${CA_INVENTORY_VAULT:-}"
    printf 'CA_EXTRA_VAULTS=%s\n'             "${CA_EXTRA_VAULTS:-}"
    printf 'CA_REQUIRES_TOKEN=%s\n'           "${CA_REQUIRES_TOKEN:-}"
    printf 'CA_NEEDS_HOST_FILE_SERVER=%s\n'   "${CA_NEEDS_HOST_FILE_SERVER:-}"
    printf 'CA_HOST_FILE_SERVER_DIR=%s\n'     "${CA_HOST_FILE_SERVER_DIR:-}"
    printf 'CA_HOST_FILE_SERVER_VERSION=%s\n' "${CA_HOST_FILE_SERVER_VERSION:-}"
    printf 'CA_CONSUMER_ROOT=%s\n'            "${CA_CONSUMER_ROOT:-}"
    printf 'GH_TOKEN=%s\n'                    "${GH_TOKEN:-}"
    printf 'ARGV=%s\n'                        "$*"
} >> "${TRACE_FILE}"
STUB
    chmod +x "${TEST_REPO}/ops/_run-playbook.sh"
}

teardown() {
    _bats_cleanup_temp
}

@test "GH_TOKEN already set: no prompt, bridge sees the full runner contract" {
    GH_TOKEN='ghp_preset' \
        run "${BASH_BIN}" "${TEST_REPO}/ops/register-runners.sh"
    [ "${status}" -eq 0 ]
    # No prompt text leaked to stdout because the prompt branch was skipped.
    [[ "${output}" != *"GitHub token:"* ]]

    trace="$(cat "${TRACE_FILE}")"
    # The register entry declares the full runner contract: the VmProvisioner
    # inventory, the GitHubRunners vault on top, the token requirement, the
    # register-only host file server, and the consumer-staged directory +
    # version learned from the pre-staging helper.
    [[ "${trace}" == *"CA_INVENTORY_VAULT=VmProvisioner"* ]]
    [[ "${trace}" == *"CA_EXTRA_VAULTS=GitHubRunners"* ]]
    [[ "${trace}" == *"CA_REQUIRES_TOKEN=1"* ]]
    [[ "${trace}" == *"CA_NEEDS_HOST_FILE_SERVER=1"* ]]
    [[ "${trace}" == *'CA_HOST_FILE_SERVER_DIR=C:\Users\Test\runner-cache'* ]]
    [[ "${trace}" == *"CA_HOST_FILE_SERVER_VERSION=2.999.0"* ]]
    # This repo declares itself the consumer root so the bridge resolves its
    # playbook / roles / fragment from here.
    [[ "${trace}" == *"CA_CONSUMER_ROOT=${TEST_REPO}"* ]]
    [[ "${trace}" == *"GH_TOKEN=ghp_preset"* ]]
}

@test "GH_TOKEN unset and stdin not a TTY: fast-fails with exit 2, bridge never invoked" {
    # The unattended-hang regression guard. With no GH_TOKEN and a
    # non-interactive stdin (the shape the E2E agent's `wsl -- ...` child runs
    # under), the entry must fail immediately rather than block on a `read`
    # prompt no automated caller can answer. The token prompt precedes the
    # staging and bridge calls, so neither runs.
    run env -u GH_TOKEN "${BASH_BIN}" -c \
        "printf '' | '${TEST_REPO}/ops/register-runners.sh'"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"GH_TOKEN must be set for unattended use"* ]]

    # Stub never ran -> trace stays empty.
    [ ! -s "${TRACE_FILE}" ]
}

@test "extra args after the entry are forwarded verbatim to the bridge" {
    GH_TOKEN='ghp_preset' \
        run "${BASH_BIN}" "${TEST_REPO}/ops/register-runners.sh" \
            --tags runner_binary --check
    [ "${status}" -eq 0 ]

    trace="$(cat "${TRACE_FILE}")"
    # The first positional the entry hands to the bridge is the playbook path;
    # everything else follows in the same order the operator supplied.
    [[ "${trace}" == *"ARGV=playbooks/register-runners.yml --tags runner_binary --check"* ]]
}
