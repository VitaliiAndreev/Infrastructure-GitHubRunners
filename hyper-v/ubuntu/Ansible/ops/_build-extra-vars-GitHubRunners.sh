#!/usr/bin/env bash
# Per-domain extra-vars helper: runners. Owned by Infrastructure-GitHubRunners
# (the runner domain's home) and consumed by the Common-Ansible substrate
# composer (ops/_build-extra-vars.sh). The composer derives this helper by the
# generic _build-extra-vars-<Name>.sh convention from the declared GitHubRunners
# vault and - because this repo declares CA_CONSUMER_ROOT - resolves it from
# <consumer-root>/ops rather than from the substrate. The vault's config path
# arrives on the generic --config flag the composer hands every per-domain
# helper; the optional --github-token / --host-base-url / --runner-version are
# the cross-cutting inputs the composer forwards when supplied.
#
# Emits the runners-domain keys consumed by the runner_binary /
# runner_registration / runner_service roles. Opt-in: dispatched by the
# extra-vars composer only when the caller declares the GitHubRunners vault
# (CA_EXTRA_VAULTS=GitHubRunners with CA_REQUIRES_TOKEN=1) and supplies
# GH_TOKEN, so a consumer that does not declare the runners vault never pays
# for it.
#
# Output (stdout):
#   {
#     "github_runners_config":     <document>,
#     "github_token":              "<value>",
#     "host_file_server_base_url": "<url>",   // only when caller opted into the host file server
#     "runner_version":            "<x.y.z>"  // only when caller opted into the host file server
#   }
#
# host_file_server_base_url + runner_version are bridge-resolved
# (Windows-side, pre-ansible-playbook) and threaded in here so the
# runner_binary role can build its download URL without re-resolving. They
# are paired: both arrive together (register path) or both are absent
# (deregister path, which fetches nothing). Absence beats emitting an empty
# string so the down-direction roles never see a stale URL.
#
# Token-by-value rationale: configs ride as file paths to keep secrets off
# argv, but the token is passed by value because the entry script holds it in
# a shell variable already and mktemp-ing it just to read it back has no
# security upside (argv on Linux is private to the owning user's process
# tree, same trust boundary as env vars and stdin args). The token is
# threaded into jq via --arg so any shell-special characters in it land in
# JSON literally.

set -euo pipefail

# The shared input gate and the unknown-flag handler are generic substrate
# helpers, not runner-domain code, so they live in Common-Ansible and are
# reached through the 3.1 sibling-checkout resolver rather than duplicated
# here. The resolver sets `common_ansible_root` once per run; the logger is
# this repo's own imports/ adapter.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_log.sh
source "${script_dir}/imports/_log.sh"
# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_common-ansible-root.sh
source "${script_dir}/imports/_common-ansible-root.sh"
# shellcheck source=/dev/null
source "${common_ansible_root}/ops/_validate-extra-vars-input.sh"
# shellcheck source=/dev/null
source "${common_ansible_root}/ops/_die-on-unknown-flag.sh"

runners_path=""
token=""
token_set=0
host_base_url=""
host_base_url_set=0
runner_version=""
runner_version_set=0

usage() {
    echo "usage: _build-extra-vars-GitHubRunners.sh --config <path> --github-token <value>" \
         "[--host-base-url <url> --runner-version <ver>]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            runners_path="${2:-}"
            shift 2 || true
            ;;
        --github-token)
            # ${2-} (no colon) so a literal empty value reaches the
            # non-empty check below rather than being silently dropped
            # by parameter expansion's default branch.
            token="${2-}"
            token_set=1
            shift 2 || true
            ;;
        --host-base-url)
            host_base_url="${2-}"
            host_base_url_set=1
            shift 2 || true
            ;;
        --runner-version)
            runner_version="${2-}"
            runner_version_set=1
            shift 2 || true
            ;;
        *)
            _die_on_unknown_flag "$1"
            ;;
    esac
done

if [[ -z "${runners_path}" || "${token_set}" -ne 1 ]]; then
    usage
    exit 2
fi

# The file-server pair is optional, but the two flags must arrive together: a
# URL without a version (or vice versa) would silently drop one half of the
# runner_binary download contract, so reject any partial set here rather than
# emit a half-formed extra-vars doc.
if [[ "${host_base_url_set}" -ne "${runner_version_set}" ]]; then
    log_err "--host-base-url and --runner-version must be supplied together"
    exit 2
fi

if [[ -z "${token}" ]]; then
    log_err "--github-token requires a non-empty value"
    exit 2
fi

if [[ "${host_base_url_set}" -eq 1 && -z "${host_base_url}" ]]; then
    log_err "--host-base-url requires a non-empty value"
    exit 2
fi

if [[ "${runner_version_set}" -eq 1 && -z "${runner_version}" ]]; then
    log_err "--runner-version requires a non-empty value"
    exit 2
fi

_validate_extra_vars_input --config "${runners_path}"

# Build the object in two steps so the file-server pair is genuinely absent
# (not present-as-empty-string) when the caller omits it.
if [[ "${host_base_url_set}" -eq 1 ]]; then
    jq -n \
        --slurpfile r "${runners_path}" \
        --arg       t "${token}" \
        --arg       u "${host_base_url}" \
        --arg       v "${runner_version}" \
        '{github_runners_config: $r[0],
          github_token:          $t,
          host_file_server_base_url: $u,
          runner_version:        $v}'
else
    jq -n \
        --slurpfile r "${runners_path}" \
        --arg       t "${token}" \
        '{github_runners_config: $r[0],
          github_token:          $t}'
fi
