# Problem

## Index
- [Summary](#summary)
- [Detail](#detail)
- [Security model](#security-model)

---

## Summary

Ubuntu VMs exist (provisioned by Infrastructure-Vm-Provisioner) but have no
CI/CD agent. We need a repeatable script to install and register a
self-hosted GitHub Actions runner on each VM and keep it running as a service.

---

## Detail

### What needs to happen on each VM

1. Download the GitHub Actions runner tarball from GitHub releases.
2. Extract and run `config.sh` with a short-lived registration token obtained
   from the GitHub API using a PAT.
3. Install as a `systemd` service via `svc.sh install` + `svc.sh start` so
   the runner survives reboots.

### Inputs required

| Input | Source |
|---|---|
| VM IP, deploy username | `GitHubRunners` vault (per-runner config JSON) |
| Deploy password | `VmUsers` vault - canonical source; set by Infrastructure-Vm-Users |
| GitHub repo/org URL | `GitHubRunners` vault (per-runner config JSON) |
| Runner name + labels | `GitHubRunners` vault (per-runner config JSON) |
| GitHub PAT | Prompted at runtime (`Read-Host -AsSecureString`) |

### Constraints

- Script runs on Windows, communicates with VMs via SSH using SSH.NET
  directly via `Invoke-SshClientCommand` (`Infrastructure.Common`).
  Posh-SSH is installed only as the carrier for its bundled
  `Renci.SshNet.dll`; its own cmdlets are not used (Posh-SSH 3.x has a
  bug that drops key-exchange algorithms, breaking connections against
  OpenSSH 9.x on Ubuntu 24.04). Deploy credentials are read from the
  `VmUsers` vault —
  Infrastructure-Vm-Users is the canonical owner of those credentials.
- Registration token is fetched fresh per run via GitHub REST API — tokens
  expire after 1 hour so they cannot be stored.
- Re-running must be safe: if the `u-actions-runner` service user already
  exists, skip creation; if a runner with the given name is already registered
  and the service is running, skip registration.
- If a runner is registered but its systemd service is not running (crashed
  or stopped), the script must attempt to restart it and surface a clear error
  if the restart fails - silent failures are not acceptable.
- A single runner process is bound to exactly one repo — GitHub does not
  support assigning a repo-level runner to multiple repos (org-level
  runners would, but there is no org). To cover multiple repos on the
  same VM, register one runner process per repo; each gets its own
  subdirectory under `/home/u-actions-runner/runners/{runnerName}/`.
  Re-running the script with a new config entry for the same VM adds the
  new runner without disturbing existing ones (idempotency guarantee).
- Two runner purposes are recommended per VM: a general CI runner
  (`self-hosted`, `ubuntu`, `x64`) and an infra/deploy runner (adds the
  `infra` label). This is a security boundary — infra workflows that
  touch secrets vaults or SSH credentials must not share a runner process
  with general build/test jobs.
- Uses `Infrastructure.Secrets` (PSGallery) for vault setup, same pattern as
  Infrastructure-Vm-Provisioner.
- Assumes `u-runner-deploy` and `u-actions-runner` already exist on each VM,
  created by **Infrastructure-Vm-Users**. Admin credentials are never required
  or stored by this repo.

---

## Security model

This repo authenticates as `u-runner-deploy`, a user created and managed
by **Infrastructure-Vm-Users**. The security model — user shells, sudoers
scope, SSH authentication, and known gaps — is documented in the
[Infrastructure-Vm-Users README](../../Infrastructure-Vm-Users/README.md).
