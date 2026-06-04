# Problem

## Index

- [Summary](#summary)
- [For laymen](#for-laymen)
- [Detail](#detail)
  - [Current behaviour and the gap](#current-behaviour-and-the-gap)
  - [What needs to change per runner](#what-needs-to-change-per-runner)
  - [Workspace cleanup](#workspace-cleanup)
  - [Failure modes](#failure-modes)
  - [Constraints](#constraints)
- [Solution approach](#solution-approach)
- [Out of scope](#out-of-scope)

---

## Summary

Self-hosted runners installed by
[feature 01](../01%20-%20initial%20implementation/problem.md) run as a
long-lived systemd service: one runner process services every job that
GitHub dispatches to it, back to back, on the same filesystem and under the
same user. A job can read or modify state that the next job will see -
`_work/_tool/`, the deploy user's home directory, environment files
written via `$GITHUB_ENV`, anything left in `/tmp`. This is the cross-job
contamination hazard GitHub's hosted runners avoid by using a fresh VM per
job.

This feature reconfigures each runner to exit after one job
(`--ephemeral`, configured via the GitHub
[JIT config](https://docs.github.com/en/rest/actions/self-hosted-runners?apiVersion=2022-11-28#create-configuration-for-a-just-in-time-runner)
API) and adds a per-job workspace wipe. A wrapper systemd service obtains a
fresh JIT config and starts the runner; when the runner exits after its
one job, systemd restarts the wrapper, which obtains a new JIT config, and
the cycle repeats. The VM stays up; the runner process and its workspace
do not survive a job boundary.

---

## For laymen

Today, when GitHub sends a build job to one of our Ubuntu CI VMs, the
"worker" stays running afterwards and waits for the next job - in the same
folder, as the same user, with whatever files the previous job left behind.
A misbehaving or malicious job (a dependency, a third-party action, a
forked PR) can plant something for the next job to trip over. After this
change, each job gets a brand-new worker that exits the moment the job
finishes, and the work folder is wiped before the next worker starts. The
VM itself stays on; only the worker recycles. Same machine, fresh start
every time.

---

## Detail

### Current behaviour and the gap

| Concern | Today | After this feature |
|---|---|---|
| Runner process lifetime | Long-lived; serves every job dispatched to it | One job, then exits |
| Workspace (`_work/`) | Persists across jobs | Wiped between jobs |
| Registration token on disk | Yes (`.runner`, `.credentials`) | No (JIT config consumed in-memory by `run.sh`) |
| Cross-job state leak | Possible (env files, `_tool/`, tmp, dotfiles) | Bounded by what the wipe misses |
| GitHub-side registration | Persistent runner entry | Per-job entry, auto-removed on runner exit |

The
[boot](../04%20-%20boot%20runners/problem.md) and
[deregister](../02%20-%20deregister%20runners/problem.md)
flows assume a long-lived registration. Both need adjustment so that an
ephemeral runner's transient registration is not treated as an error.

### What needs to change per runner

1. **Switch the systemd service from a persistent runner to an ephemeral
   wrapper.** The unit no longer runs `run.sh` against a persistent
   `.runner` file. It runs a wrapper script that, each time it starts:
   1. Requests a JIT config blob from the GitHub REST API
      (`POST /repos/{owner}/{repo}/actions/runners/generate-jitconfig`)
      using the deploy machine's PAT, forwarded to the VM via a one-shot
      SSH-tunnelled call. The PAT never lands on the VM.
   2. Hands the blob to `./run.sh --jitconfig <blob>`.
   3. Returns the runner's exit code to systemd.
2. **Restart-on-exit.** systemd `Restart=always` with a small
   `RestartSec` so the next job's runner is ready within seconds of the
   previous job finishing. A burst-limit (`StartLimitIntervalSec`,
   `StartLimitBurst`) prevents a runaway loop if the JIT API call keeps
   failing.
3. **Per-job workspace wipe.** Before each `run.sh` invocation the wrapper
   removes `_work/` and recreates it empty. `_work/_tool/` is intentionally
   not preserved - the goal is no cross-job carry-over; the action toolcache
   re-downloads on demand.
4. **PAT delivery without persistence on the VM.** The JIT-config request
   is issued from the Windows host (where the PAT already lives, prompted
   at registration time) and the resulting blob is sent over the SSH session
   to the wrapper via an environment variable or a short-lived file under
   `/run/`. The PAT itself is never written to the VM filesystem and is not
   readable by the runner user.

### Workspace cleanup

The wipe targets exactly the directories the runner writes to during a job:

| Path | Action between jobs | Reason |
|---|---|---|
| `/opt/runners/{name}/_work/` | Recreate empty | Job checkout, build artefacts, `$GITHUB_ENV`, `$GITHUB_PATH` |
| `/opt/runners/{name}/_diag/` | Rotate (keep last N) | Useful for incident review; not a contamination vector |
| `/tmp/` for the runner user | Clear runner-user-owned entries | Jobs leak temp files here |
| Runner-user home (`/home/u-actions-runner`) | Restore from a known-good snapshot | Dotfile injection is a known supply-chain technique |

The runner binary and its configuration files
(`/opt/runners/{name}/bin/`, `externals/`) are not touched - they are
installed once by
[feature 01](../01%20-%20initial%20implementation/problem.md) and shared
across all jobs on this runner.

### Failure modes

| Situation | Behaviour |
|---|---|
| JIT-config request returns 401 (PAT expired/revoked) | Wrapper exits non-zero; systemd backoff kicks in; operator alerted by the runner appearing offline on GitHub |
| JIT-config request returns 422 (runner name in use) | Wrapper deletes the orphan registration via the REST API, then retries once |
| `run.sh` crashes mid-job | systemd restart triggers; next job gets a fresh JIT config; the crashed job is reported as failed on GitHub as today |
| Workspace wipe fails (disk full, permission) | Wrapper exits non-zero before invoking `run.sh`; no job is taken from the queue with a dirty workspace |
| Deregistration (`deregister-runners.ps1`) while ephemeral wrapper is idle | Wrapper exits cleanly when systemd stops it; no runner is registered on GitHub at that moment, so the existing "no runner found" branch already handles it |

### Constraints

- Single source of truth stays the `GitHubRunners` vault. No new config
  fields; the JIT-config flow uses the existing `githubUrl`, `runnerName`,
  `runnerLabels`.
- PAT scope unchanged: `repo` (private) or `public_repo` (public). The
  `generate-jitconfig` endpoint uses the same scope as the existing
  registration-token endpoint.
- The wrapper script lives on the VM but contains no secrets. It is
  installed once by the registration flow and updated in place if its
  contents change.
- The Windows host is the only holder of the PAT, consistent with
  [feature 01](../01%20-%20initial%20implementation/problem.md) and
  [feature 02](../02%20-%20deregister%20runners/problem.md). The host
  brokers each JIT-config request over an SSH session it already holds open
  during registration; for steady-state operation the wrapper calls the
  GitHub API itself using a runner-scoped credential that is **not** the
  human PAT - see [Out of scope](#out-of-scope) for the GitHub App option.
- Backward compatibility with existing VMs: re-running
  `register-runners.ps1` must convert a persistent-runner install to the
  ephemeral-wrapper install in place, without requiring a full re-provision
  of the VM.
- Idempotency: re-running registration on an already-ephemeral VM is a
  no-op apart from refreshing the wrapper script if its hash differs.

---

## Solution approach

Surveyed off-the-shelf options:

| Option | Outcome |
|---|---|
| `actions/runner` `--ephemeral` flag with classic registration tokens | Adopt (mechanism). One job per runner process, auto-deregister on exit. |
| GitHub `generate-jitconfig` API (`run.sh --jitconfig`) | Adopt (delivery). Removes the on-disk registration token; the runner is pre-configured by an opaque blob consumed once. |
| [Actions Runner Controller (ARC)](https://github.com/actions/actions-runner-controller) | Reject. True VM/pod per job, but requires Kubernetes. Out of scope for a Hyper-V workstation host. |
| [nektos/act](https://github.com/nektos/act) | Reject. Local-only workflow runner, not a hosted-runner replacement. |

**Chosen direction: adopt `--ephemeral` + JIT config.** Smallest change
that closes the cross-job contamination gap on the current Hyper-V stack.
No new platform dependency, no Kubernetes, no new vault entries. The
classic registration-token path is replaced wholesale by JIT so that the
runner never has a long-lived secret on disk.

A future move to ephemeral-VM-per-job (clone a golden image per job, destroy
on exit) remains possible on top of this work but is a separate, larger
feature.

---

## Out of scope

- **Ephemeral VM per job.** This feature keeps the VM long-lived and
  recycles only the runner process and its workspace. Per-job VM cloning is
  a follow-up.
- **GitHub App instead of PAT.** Replacing the human PAT with a GitHub
  App installation token (shorter-lived, scoped, revocable per install) is
  the right long-term security posture but is a cross-cutting change to
  features 01, 02, and 04. Tracked separately.
- **Runner image bake / golden-image pipeline.** This feature does not
  pre-bake the runner's tool dependencies; jobs install what they need as
  today.
- **Toolcache preservation.** `_work/_tool/` is wiped with the rest of
  `_work/`. A shared, read-only toolcache mounted from outside `_work/`
  could be added later as a perf optimisation if download time becomes a
  pain point.
- **Concurrency increase on a single VM.** One ephemeral runner per
  `runnerName` is still one job at a time. Running N parallel ephemeral
  runners on the same VM is a separate capacity decision.
- **Changes to the `GitHubRunnersConfig` schema.** No new fields; existing
  ones suffice.
