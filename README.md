# Infrastructure-GitHubRunners

Registers and deregisters self-hosted GitHub Actions runners on Ubuntu VMs
provisioned by
[Infrastructure-Vm-Provisioner](https://github.com/VitalyAndreev/Infrastructure-Vm-Provisioner).

## Index

- [Requirements](#requirements)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Config schema](#config-schema)
- [Token requirements](#token-requirements)
- [Multi-repo and multi-purpose runners](#multi-repo-and-multi-purpose-runners)
- [Idempotency](#idempotency)
- [Deregistration](#deregistration)
- [Ansible runner flow (Common-Ansible substrate)](#ansible-runner-flow-common-ansible-substrate)
- [CI and linting](#ci-and-linting)
- [Repo structure](#repo-structure)

---

## Requirements

PowerShell 7+ (`pwsh`).

---

## Prerequisites

- Windows host with Hyper-V and PowerShell 7+.
- `Common.PowerShell` >= `3.1.0` installed from PSGallery.
- VMs provisioned by **Infrastructure-Vm-Provisioner** and reachable.
- A deploy user and a runner service user created on each VM by
  **Infrastructure-Vm-Users** before running this script (named in the
  config as `deployUsername` and `runnerUsername` respectively; for example
  `u-runner-deploy` and `u-actions-runner`).
  - Deploy user: SSH-accessible; sudoers scoped to runner operations only.
  - Runner service user: no-login; owns and runs the runner process.
- `setup-secrets.ps1` run at least once on this machine to store runner config
  in the local vault.
- Deploy passwords for `u-runner-deploy` stored in the **VmUsers** vault by
  Infrastructure-Vm-Users — this repo reads them at runtime and never stores
  them itself.

---

## Quick start

```powershell
# 1. Store runner config in the local vault (once per machine).
.\hyper-v\ubuntu\setup-secrets.ps1 -ConfigFile C:\private\runners-config.json

# 2. Register runners on all reachable VMs.
.\hyper-v\ubuntu\register-runners.ps1

# 3. Deregister runners from all reachable VMs.
.\hyper-v\ubuntu\deregister-runners.ps1
```

Both scripts prompt for a GitHub token at startup. The token is held in
memory only and is never written to disk or logged.

---

## Config schema

Store as a JSON array in the file passed to `setup-secrets.ps1`.
One entry = one runner process. Multiple entries with the same `vmName`
are valid and expected (see [Multi-repo and multi-purpose runners](#multi-repo-and-multi-purpose-runners)).

```jsonc
[
  {
    "vmName":         "ubuntu-01-ci",       // must match VmProvisionerConfig
    "ipAddress":      "192.168.1.101",
    "deployUsername": "u-runner-deploy",    // SSH user for deploy operations
    "runnerUsername": "u-actions-runner",   // service user that owns runner files
    "githubUrl":      "https://github.com/user/repo-a",
    "runnerName":     "ubuntu-01-ci",       // unique name shown in GitHub UI
    "runnerLabels":   ["self-hosted", "ubuntu", "x64"]
  }
]
```

`deployPassword` is intentionally absent. It is read from the **VmUsers**
vault at runtime — Infrastructure-Vm-Users is the single source of truth for
deploy credentials. Never add passwords to this file.

---

## Token requirements

The token is prompted at runtime and never stored. Required scopes:

| Repo visibility | Required scope |
|---|---|
| Private | `repo` |
| Public | `public_repo` |

The token is used to:
- resolve the latest runner version via the GitHub Releases API,
- check existing runner registration via the GitHub Runners API,
- fetch short-lived registration and removal tokens,
- delete runners directly via the GitHub API (deregistration force mode).

---

## Multi-repo and multi-purpose runners

GitHub repo-level runners are bound 1:1 to a single repo (no org-level
runners). To cover multiple repos on one VM, add one entry per repo.

The recommended pattern is two runner purposes per VM:

| Purpose | Labels | Targeted by |
|---|---|---|
| General CI | `self-hosted`, `ubuntu`, `x64` | Build, test, lint workflows |
| Infra/deploy | `self-hosted`, `ubuntu`, `x64`, `infra` | Provisioning, SSH-based deploy |

Keeping infra workflows on a dedicated runner is a security boundary: a
compromised job on the general runner cannot access secrets vaults or SSH
credentials that infra workflows use. Workflows opt in via
`runs-on: [self-hosted, infra]`.

Example config for one VM covering two repos with dedicated infra runners:

```jsonc
[
  { "vmName": "ubuntu-01-ci", ..., "githubUrl": "https://github.com/user/repo-a",
    "runnerName": "ubuntu-01-ci",       "runnerLabels": ["self-hosted","ubuntu","x64"] },
  { "vmName": "ubuntu-01-ci", ..., "githubUrl": "https://github.com/user/repo-a",
    "runnerName": "ubuntu-01-ci-infra", "runnerLabels": ["self-hosted","ubuntu","x64","infra"] },
  { "vmName": "ubuntu-01-ci", ..., "githubUrl": "https://github.com/user/repo-b",
    "runnerName": "ubuntu-01-ci-repo-b","runnerLabels": ["self-hosted","ubuntu","x64"] }
]
```

---

## Idempotency

Re-running `register-runners.ps1` is safe:

- The runner tarball is downloaded once per version and cached at
  `/home/{runnerUsername}/cache/`. Subsequent runs skip the download.
- Runner directories (`/opt/runners/{runnerName}/`) are only extracted if
  absent.
- Runners already registered on GitHub with an active systemd service are
  detected and skipped.
- Runners registered but with a stopped service are restarted without
  re-registering.
- Runners not registered at all go through full registration, service
  install, and start.

---

## Deregistration

`deregister-runners.ps1` reads the same vault config as registration and
cleanly removes each runner from both GitHub and the VM.

```powershell
# Normal mode - VM must be reachable.
.\hyper-v\ubuntu\deregister-runners.ps1

# Force mode - removes GitHub registrations even when the VM is unreachable.
.\hyper-v\ubuntu\deregister-runners.ps1 -Force
```

Required token scopes are the same as for registration (`repo` for private
repos, `public_repo` for public).

### Unreachable VM behaviour

| Mode | VM unreachable | Runner on GitHub | Outcome |
|---|---|---|---|
| Normal | Yes | Yes | Reported as error at end of run |
| Normal | Yes | No | Logged and skipped |
| Force | Yes | Yes | Deleted via GitHub API; no VM-side cleanup |
| Force | Yes | No | Logged and skipped |

### Per-runner cleanup sequence (reachable VMs)

1. Stop and uninstall the systemd service if present.
2. Deregister from GitHub via `config.sh remove` if the runner is registered.
3. Delete the runner directory to ensure the next registration starts clean.

Re-running `deregister-runners.ps1` is safe: resources already removed on
GitHub (404) are treated as success, stopped services and absent unit files
are silently skipped, and absent runner directories are ignored.

---

## Ansible runner flow (Common-Ansible substrate)

Alongside the PowerShell orchestrators above, this repo owns an **Ansible**
implementation of the same runner lifecycle. It is the runner-domain consumer
of the **Common-Ansible** substrate: the reusable dispatch bridge, controller
venv, inventory/router resolution, and host file server live in Common-Ansible,
while the runner roles, playbooks, and operator wrappers live here.

### Layout

| Kind | Here | Purpose |
|---|---|---|
| Roles | `roles/runner_entry_resolve`, `roles/runner_binary`, `roles/runner_registration`, `roles/runner_service` | Resolve a host's runner entries; cache/extract the tarball; reconcile GitHub registration; install the systemd unit |
| Playbooks | `playbooks/register-runners.yml`, `playbooks/deregister-runners.yml`, `playbooks/runner-status.yml` (+ `playbooks/tasks/`) | Compose the roles per direction |
| Wrappers | `ops/register-runners.sh`, `ops/deregister-runners.sh`, `ops/runner-status.sh` (+ `.bat`) | Operator entry points |
| Domain helpers | `ops/_build-extra-vars-runners.sh`, `ops/_require-gh-token.sh`, `ops/_stage-runner-tarball.sh`, `ops/_resolve-runner-version.ps1`, `ops/_ensure-runner-tarball.ps1`, `ops/setup-runners-secrets.{ps1,bat}` | Runner-domain extra-vars, token acquisition, tarball staging, secrets surface |

### Consuming Common-Ansible

Common-Ansible is consumed as a **sibling checkout** (cloned next to this repo
under the same parent directory; override with `COMMON_ANSIBLE_ROOT`). The
roles are not standalone - they read the bridge's extra-vars/inventory
contract - so roles and bridge are one substrate, taken together through one
checkout. `ops/imports/_common-ansible-root.sh` resolves that root once;
`ops/bootstrap-controller.sh` reuses the substrate's controller venv rather
than building its own.

Each wrapper declares this repo as the consumer through the bridge's `CA_*`
contract: `CA_CONSUMER_ROOT` points the bridge at this repo so it runs *this*
repo's playbook, prepends this repo's `roles/` to `ANSIBLE_ROLES_PATH` (the
substrate `roles/` stays on the path for any reusable role), and resolves the
`_build-extra-vars-runners.sh` fragment from `ops/` here. The wrappers also
declare the `VmProvisioner` inventory vault, the `GitHubRunners` vault on top
of it, and the GitHub token requirement.

```bash
# Bootstrap the controller once (reuses the Common-Ansible venv).
ops/bootstrap-controller.sh        # or double-click ops\bootstrap-controller.bat

# Register / status / deregister (each prompts for a GitHub token).
ops/register-runners.sh
ops/runner-status.sh
ops/deregister-runners.sh           # add --force to clear unreachable VMs via the API
```

### Reaching the substrate host file server

Target VMs fetch the actions/runner tarball from a Windows-side file server
the bridge spins up over the Hyper-V internal switch, rather than over the
NAT-bound github.com path. The file server itself is substrate (it serves any
directory); the *runner-tarball* knowledge is this repo's. So
`ops/register-runners.sh` pre-stages: `_stage-runner-tarball.sh` resolves the
runner version and caches the tarball Windows-side, then the wrapper hands the
bridge the staged directory and version through the contract
(`CA_NEEDS_HOST_FILE_SERVER=1`, `CA_HOST_FILE_SERVER_DIR`,
`CA_HOST_FILE_SERVER_VERSION`). The bridge serves that directory and threads
the base URL + version into the `runner_binary` role's download. The deregister
and status flows fetch nothing, so they leave the file server off.

---

## CI and linting

The PowerShell logic is tested with Pester via `scripts\Run-Tests.ps1`. The
YAML and Bash surfaces (workflows, the `*.sh` runners) are linted by a
separate suite that delegates to **Common-Automation** so every repo lints
against one shared engine - no per-repo copies of the lint config to drift.

| Workflow | Runs | Calls |
|---|---|---|
| `.github/workflows/ci-yaml.yml` | actionlint, action-validator, yamllint, ansible-lint | Common-Automation reusable `ci-yaml.yml` |
| `.github/workflows/ci-bash.yml` | shellcheck, check-sh-executable, bats | Common-Automation reusable `ci-bash.yml` |

Each linter auto-skips when its surface is absent, so a repo with no Ansible
or no Bash still gets a green run.

To reproduce the exact CI locally (Git Bash + Docker), use the main runner. It
runs the full lint suite AND the bats tests - the local equivalent of this
repo's `ci-yaml.yml` + `ci-bash.yml`:

```bash
# MAIN entry: full lint suite + bats tests (local ci-yaml.yml + ci-bash.yml).
scripts/run-ci-yaml-and-bash.sh              # or double-click scripts\run-ci-yaml-and-bash.bat
```

To run just one half:

```bash
# Lint half only (shellcheck, actionlint, action-validator, yamllint,
# ansible-lint). Distinct from the Pester runner Run-Tests.ps1; runs no
# PowerShell tests.
scripts/run-lint-yaml-and-bash.sh            # or double-click scripts\run-lint-yaml-and-bash.bat

# Bats test half only.
scripts/run-tests-bash.sh                    # or double-click scripts\run-tests-bash.bat

# Re-stage the +x bit on tracked *.sh files (Windows checkouts drop it,
# which trips the check-sh-executable gate).
scripts/fix-permissions.sh     # or scripts\fix-permissions.bat
```

All three runners are thin shims over Common-Automation's engine, pointed at
this repo via the `COMMON_AUTOMATION_TARGET_REPO` env var, so a sibling
checkout at `..\Common-Automation` is required. `.gitattributes` pins `*.sh`
to LF and `*.bat` to CRLF - Linux CI runners reject CRLF shebangs.

---

## Repo structure

```
.github/workflows/
  ci-yaml.yml                 Delegates to Common-Automation reusable ci-yaml.yml
  ci-bash.yml                 Delegates to Common-Automation reusable ci-bash.yml
scripts/
  run-ci-yaml-and-bash.sh / .bat            MAIN local runner: full lint suite + bats tests (Common-Automation engine)
  run-lint-yaml-and-bash.sh / .bat          Lint half only (shellcheck, actionlint, action-validator, yamllint, ansible-lint)
  run-tests-bash.sh / .bat                  Bats test half only
  fix-permissions.sh / .bat   Re-stage +x on tracked *.sh via the shared engine
.gitattributes                Pins *.sh to LF and *.bat to CRLF
ops/                          Ansible operator surface (Common-Ansible consumer)
  register-runners.sh / .bat        Register flow entry (pre-stages tarball, declares the CA_* contract)
  deregister-runners.sh / .bat      Deregister flow entry (--force clears unreachable VMs via the API)
  runner-status.sh                  Read-only UP/DOWN status report
  setup-runners-secrets.ps1 / .bat  Operator surface delegating to hyper-v/ubuntu/setup-secrets.ps1
  bootstrap-controller.sh / .bat    Reuse the Common-Ansible controller venv
  _build-extra-vars-runners.sh      Runner-domain extra-vars fragment (consumed by the substrate composer)
  _stage-runner-tarball.sh          Resolve runner version + cache the tarball Windows-side
  _require-gh-token.sh              GitHub PAT acquisition (per-invocation, never vaulted)
  _resolve-runner-version.ps1       Resolve the latest actions/runner version
  _ensure-runner-tarball.ps1        Idempotent Windows-side tarball cache
  imports/                          Cross-repo resolvers (Common-Ansible + Common-Automation)
playbooks/
  register-runners.yml              Compose runner roles (binary -> registration -> service)
  deregister-runners.yml            Reverse order via tasks_from: remove + force fan-out
  runner-status.yml                 Per-runner service + GitHub-side status
  tasks/                            Shared task includes (acl prereq, unreachable handling, status probe)
roles/
  runner_entry_resolve/             Resolve this host's runner entries from extra-vars
  runner_binary/                    Cache and extract the runner tarball
  runner_registration/             Reconcile GitHub-side registration
  runner_service/                   Install and manage the systemd unit
hyper-v/ubuntu/
  setup-secrets.ps1           Store runner config in the local vault
  register-runners.ps1        Orchestrator for runner registration
  deregister-runners.ps1      Orchestrator for runner deregistration
  registration/
    common/                   Shared between registration and deregistration
      config/                 Vault reads, JSON parsing, credential joining
      github/                 GitHub REST API calls (shared read)
      infra/                  Connectivity checks, path computation
      service/                Systemd service state queries
    up/                       Runner registration (install and register)
      binary/                 Runner binary lifecycle (download, extract, install)
      github/                 GitHub Releases API (runner version resolution)
      registration/           config.sh lifecycle (register)
      service/                Systemd service management (start)
      Invoke-VmRunnerGroup.ps1  Per-VM orchestration (install + reconcile)
    down/                     Runner deregistration (stop, deregister, remove)
      binary/                 Runner directory removal
      github/                 GitHub REST API calls (runner deletion)
      registration/           config.sh lifecycle (deregister)
      service/                Systemd service management (stop, uninstall)
      Invoke-VmDeregisterGroup.ps1  Per-VM orchestration (stop, deregister, remove)
Tests/
  registration/               Unit tests mirroring the production structure
    common/
    up/
    down/
  Integration/                Integration tests (require a live SSH target via Docker)
  ops/                        Bats + Pester for the Ansible operator wrappers
  molecule/                   Molecule scenarios per runner role (Docker driver)
  ansible/                    Controller-only playbook smoke test + fixture inventory
  mock-github-api.py          Shared mock GitHub API for the runner-side tests
```
