#!/usr/bin/env bash
# Operator wrapper for the register-runners flow. The flow's heavy lifting
# (tmpdir, venv activation, vault reads, inventory, router resolution,
# extra-vars, dispatch) lives in the Common-Ansible substrate bridge,
# consumed as a sibling checkout (see README "Consuming Common-Ansible").
# This wrapper owns the two concerns the consumer-agnostic bridge
# intentionally does not:
#
# - GitHub PAT acquisition (require_gh_token, from _require-gh-token.sh).
#   The token never enters a vault; it is supplied per-invocation. The
#   bridge stays playbook-agnostic and leaves the prompt at the operator
#   edge.
# - Runner-tarball staging (_stage-runner-tarball.sh). The substrate file
#   server SERVES a directory but no longer knows about runner tarballs, so
#   this repo - the runner domain's owner - resolves the version and caches
#   the matching tarball, then hands the bridge the staged directory and the
#   version through the CA_HOST_FILE_SERVER_* contract. The bridge spins the
#   host file server over that directory.
#
# Everything else it declares through the CA_* consumer contract: the
# VmProvisioner inventory vault, the GitHubRunners vault on top of it
# (CA_EXTRA_VAULTS), the token requirement (CA_REQUIRES_TOKEN=1, so the
# bridge fails fast if require_gh_token somehow left GH_TOKEN unset), and the
# host file server the runner-binary fetch needs (CA_NEEDS_HOST_FILE_SERVER=1
# plus the staged dir/version). This repo owns the register-runners playbook
# and the runner roles, so it declares CA_CONSUMER_ROOT as its own repo root;
# the bridge then resolves the playbook, those roles, and the GitHubRunners
# extra-vars fragment from here rather than from the substrate.
#
# Forwarded args follow the playbook path so operators can pass --tags,
# --limit, --check, -v, etc. unchanged.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This repo's root (ops/ -> repo root): the consumer root the bridge resolves
# the playbook, roles, and fragment from.
CA_CONSUMER_ROOT="$(cd "${script_dir}/.." && pwd)"

# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_log.sh
source "${script_dir}/imports/_log.sh"
# shellcheck source=hyper-v/ubuntu/Ansible/ops/_require-gh-token.sh
source "${script_dir}/_require-gh-token.sh"
# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_common-ansible-root.sh
source "${script_dir}/imports/_common-ansible-root.sh"

require_gh_token

# Pre-stage the runner tarball Windows-side and learn the version + the
# directory the file server will serve. This is the runner-domain knowledge
# the substrate no longer holds; it runs before the bridge so the bridge only
# needs to serve the directory it is handed. The helper narrates on stderr
# and prints two KEY=value lines on stdout.
log_info "Staging runner tarball (resolve version, cache tarball) ..."
stage_out="$("${script_dir}/_stage-runner-tarball.sh" --github-token "${GH_TOKEN}")"
runner_version="$(grep '^RUNNER_VERSION=' <<<"${stage_out}" | head -n1 | cut -d= -f2-)"
staging_dir="$(grep    '^STAGING_DIR='    <<<"${stage_out}" | head -n1 | cut -d= -f2-)"
if [[ -z "${runner_version}" || -z "${staging_dir}" ]]; then
    log_err "staging helper did not return RUNNER_VERSION/STAGING_DIR"
    exit 1
fi

export CA_INVENTORY_VAULT=VmProvisioner
export CA_EXTRA_VAULTS=GitHubRunners
export CA_REQUIRES_TOKEN=1
# Register-only opt-in: VMs fetch the actions/runner tarball from a
# Windows-side HttpListener the bridge spins up over the staged directory.
# The deregister entry leaves these unset because the down path fetches
# nothing.
export CA_NEEDS_HOST_FILE_SERVER=1
export CA_HOST_FILE_SERVER_DIR="${staging_dir}"
export CA_HOST_FILE_SERVER_VERSION="${runner_version}"
export CA_CONSUMER_ROOT

exec "${common_ansible_root}/ops/_run-playbook.sh" playbooks/register-runners.yml "$@"
