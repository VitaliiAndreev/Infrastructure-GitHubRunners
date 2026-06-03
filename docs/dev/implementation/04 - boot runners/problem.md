# Problem

## Index

- [Summary](#summary)
- [Detail](#detail)
  - [What needs to happen per VM](#what-needs-to-happen-per-vm)
  - [Inputs required](#inputs-required)
  - [Code reuse from registration](#code-reuse-from-registration)
  - [Outcome states](#outcome-states)
  - [Constraints](#constraints)
- [Out of scope](#out-of-scope)

---

## Summary

After a workstation reboot, CI Hyper-V VMs are powered off and the self-hosted
GitHub runners they host appear offline on GitHub. There is no script to bring
them back up. This feature adds `boot-runners.ps1`: a script that reads the
same `GitHubRunners` vault config as
[registration](../01%20-%20initial%20implementation/problem.md) and
[deregistration](../02%20-%20deregister%20runners/problem.md), enumerates the
unique VMs, starts those that are off, SSHs in once they are reachable, and
restarts any stopped runner systemd services. A healthy `active` service is
the success signal - the runner agent reconnects to GitHub on its own once
the service is up, so no GitHub API call (and no PAT) is needed.

---

## Detail

### What needs to happen per VM

1. Group the runner config entries by `vmName` so each VM is processed once
   even when it hosts multiple runners.
2. Power the VM on via `Start-VmIfStopped` from `Infrastructure.HyperV`
   (see [Infrastructure-HyperV feature 04](../../../../Infrastructure-HyperV/docs/dev/implementation/04%20-%20vm-power-on/problem.md)).
   That call is idempotent: `Off`/`Saved` triggers a start, `Running` is a
   no-op, transient states throw.
3. Wait for SSH on `ipAddress` to become reachable
   (`Wait-VmSshReady` from `Infrastructure.HyperV`), with a bounded per-VM
   timeout so one stuck VM does not hang the run.
4. Open one SSH session per VM as the deploy user and, for each runner
   hosted on that VM:
   1. Resolve the runner's systemd unit name (`Get-RunnerServiceName`).
   2. If the unit exists but is not `active`, start it
      (`Start-RunnerService`).
   3. If the unit is absent, warn that the runner is not installed - this
      script does not register runners; the operator runs
      `register-runners.ps1` for that.
5. Aggregate per-VM and per-runner results into a final report at the end of
   the run so a single offline VM or runner does not abort the others.

### Inputs required

| Input | Source |
|---|---|
| VM name, IP, deploy/runner usernames, runner names, GitHub URLs | `GitHubRunners` vault (`GitHubRunnersConfig`) |
| Deploy password (for SSH) | `VmUsers` vault - canonical source; set by Infrastructure-Vm-Users |

No GitHub PAT is required: this script only starts already-registered
runners, so it never calls the GitHub API.

### Code reuse from registration

This script must not duplicate logic that already exists for
`register-runners.ps1`. Reused functions (dot-sourced from the same paths):

| Concern | Function / file |
|---|---|
| Read and parse vault config | `common/config/Read-GitHubRunnersConfig.ps1`, `ConvertFrom-GitHubRunnersConfigJson.ps1` |
| Join VM deploy passwords into runner entries | `common/config/Read-VmDeployPasswords.ps1`, `Join-RunnerDeployCredentials.ps1` |
| SSH-reachability probe | `common/infra/Test-RunnerVmConnectivity.ps1` |
| Service-name resolution and active-state check | `common/service/Get-RunnerServiceName.ps1`, `Test-RunnerServiceActive.ps1` |
| Start a stopped runner service | `up/service/Start-RunnerService.ps1` |

New code is limited to:

- A per-VM orchestrator (`Invoke-VmBootGroup.ps1`) mirroring
  `Invoke-VmRunnerGroup.ps1` and `Invoke-VmDeregisterGroup.ps1`: power on,
  wait for SSH, open one SSH session, reconcile services for the VM's
  runners.
- The top-level `boot-runners.ps1` entry script that loads modules, reads
  inputs, groups by `vmName`, and dispatches to the orchestrator.

### Outcome states

| VM state on entry | Service state | Outcome |
|---|---|---|
| Running | active | Logged, skipped |
| Running | inactive | Start service |
| Running | absent unit | Warn: runner not installed; run `register-runners.ps1` |
| Off / Saved | n/a | Start VM; wait for SSH; reconcile services on the VM |
| Start-VM fails | n/a | Error collected; reported at end |
| SSH never ready | n/a | Error collected; reported at end |
| Service start fails | n/a | Error collected; reported at end (already handled by `Start-RunnerService`) |

### Constraints

- Single source of truth for VM and runner inventory: the `GitHubRunners`
  vault, shared with registration and deregistration. No second config file.
- VM power-on goes through `Infrastructure.HyperV`'s `Start-VmIfStopped`,
  not the native `Start-VM` cmdlet, so the idempotence and error-message
  contract lives in one shared place.
- Re-runnable: VMs already `Running` and services already `active` are
  skipped with a one-line log entry, not re-started.
- Bounded per-VM timeout for the SSH-ready wait.
- SSH via SSH.NET directly through `Invoke-SshClientCommand` - same pattern
  and rationale as registration (Posh-SSH cmdlets bypassed).
- No GitHub API calls and no PAT prompt - this script only acts on already
  registered runners, and the runner agent reconnects to GitHub on its own
  once the systemd service is `active`.

---

## Out of scope

- Starting the host workstation itself, or scheduling this script to run at
  workstation boot. The script is invokable; whether it is wired into a
  scheduled task is a separate operator decision.
- Registering runners that are not yet installed on a VM (no `config.sh`,
  no service unit). That is `register-runners.ps1`'s responsibility; this
  script reports the gap and stops.
- Shutting VMs down. A `shutdown-runners.ps1` counterpart could be added
  later but is not part of this feature.
- Any change to the `GitHubRunnersConfig` schema. This script consumes the
  existing fields only.
