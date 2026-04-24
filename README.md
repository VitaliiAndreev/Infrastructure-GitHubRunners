# Infrastructure-GitHubRunners

Registers and deregisters self-hosted GitHub Actions runners on Ubuntu VMs
provisioned by
[Infrastructure-Vm-Provisioner](https://github.com/VitalyAndreev/Infrastructure-Vm-Provisioner).

## Index

- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Config schema](#config-schema)
- [PAT requirements](#pat-requirements)
- [Multi-repo and multi-purpose runners](#multi-repo-and-multi-purpose-runners)
- [Idempotency](#idempotency)
- [Deregistration](#deregistration)
- [Repo structure](#repo-structure)

---

## Prerequisites

- Windows host with Hyper-V and PowerShell 5.1+.
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

Both scripts prompt for a GitHub PAT at startup. The PAT is held in memory
only and is never written to disk or logged.

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

## PAT requirements

The PAT is prompted at runtime and never stored. Required scopes:

| Repo visibility | Required scope |
|---|---|
| Private | `repo` |
| Public | `public_repo` |

The PAT is used to:
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
- Runner directories (`/home/{runnerUsername}/runners/{runnerName}/`) are
  only extracted if absent.
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

Required PAT scopes are the same as for registration (`repo` for private
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

## Repo structure

```
hyper-v/ubuntu/
  setup-secrets.ps1           Store runner config in the local vault
  register-runners.ps1        Orchestrator for runner registration
  deregister-runners.ps1      Orchestrator for runner deregistration
  registration/
    common/                   Shared between registration and deregistration
      config/                 Vault reads, JSON parsing, credential joining
      github/                 GitHub REST API calls (shared wrapper + read)
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
```
