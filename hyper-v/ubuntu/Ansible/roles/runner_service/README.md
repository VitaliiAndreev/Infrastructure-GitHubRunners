# Role: runner_service

Reconciles the systemd service for a self-hosted GitHub Actions runner.
Third role applied by
[`playbooks/register-runners.yml`](../../playbooks/register-runners.yml)
(once that playbook lands in step 6); runs after
[`runner_registration`](../runner_registration/README.md) (which lays
`config.sh` + `.runner` on disk - both are required for `svc.sh install`
to succeed) and is the last step before the runner reports online to
GitHub.

## Index

- [Var contract](#var-contract)
- [Register direction](#register-direction)
- [Environment delivery](#environment-delivery)
- [Remove direction](#remove-direction)
- [Idempotence guarantees](#idempotence-guarantees)
- [Tests](#tests)
- [Rationale](#rationale)

## Var contract

The role reads one extra-var:

- `github_runners_config` - the verbatim `GitHubRunnersConfig-<Suffix>`
  JSON array. The host slice is derived by the
  [`runner_entry_resolve`](../runner_entry_resolve/README.md) meta
  dependency into the shared `vm_runner_entries` fact. Per-entry
  shape consumed by this role:

  ```yaml
  vmName: ubuntu-01-ci             # selector (matched on host)
  runnerName: ubuntu-01-ci-a       # also the dir name and unit suffix
  runnerUsername: u-actions-runner # passed to svc.sh install as the
                                   # service user
  ```

  Other entry fields (`deployUsername`, `githubUrl`, `runnerLabels`,
  `ipAddress`) are consumed by other roles, not by this role.

The role expects `/opt/runners/<runnerName>/` to already contain a
functional actions/runner extraction (laid by `runner_binary`) plus a
registered `.runner` marker (laid by `runner_registration`). It does
not validate either - the corresponding modules would surface a clear
error if `svc.sh` were absent or `config.sh --unattended` had not
already run.

## Register direction

For every entry in `vm_runner_entries`, the role drives six phases:

1. **Unit probe.** `systemctl list-unit-files --no-legend
   'actions.runner.*<runnerName>.service'` piped through
   `awk '{print $1}' | head -n1`. Captures the matching unit name on
   stdout (or empty if no unit is installed yet). The glob filters by
   the `runnerName` suffix only - parsing `<owner>-<repo>` out of
   `githubUrl` to pin the prefix would just duplicate work the next
   probe and the systemd module both no-op when the unit is correctly
   named.
2. **`svc.sh install` (when the probe stdout is empty).** Runs as root
   via `become: true` because `svc.sh` writes the unit file under
   `/etc/systemd/system`. The runner service user owns the runner
   directory tree (`runner_binary`'s ownership posture) so `svc.sh`
   itself is owner-readable; only the unit-file write needs root.
   Argument: the entry's `runnerUsername`, which `svc.sh` bakes into
   the unit's `User=` line.
3. **Environment drop-in**
   ([`tasks/_apply-environment-dropin.yml`](tasks/_apply-environment-dropin.yml)).
   Renders `files/10-environment-file.conf` to
   `/etc/systemd/system/<unit>.d/10-environment-file.conf` and reloads
   the daemon when it changed. See
   [Environment delivery](#environment-delivery).
4. **Enable + start.** `ansible.builtin.systemd` with `state: started`,
   `enabled: true`. A second probe runs between the install branch and
   this task so the unit name is in scope on both code paths
   (already-installed and just-installed).
5. **Environment refresh**
   ([`tasks/_refresh-environment.yml`](tasks/_refresh-environment.yml)).
   Restarts the units whose `/etc/environment` changed since they last
   started. See [Environment delivery](#environment-delivery).
6. **`systemctl is-active` re-check.** One `command` per entry capturing
   stdout (with `failed_when: false`), followed by an `assert` per
   entry checking `stdout == 'active'`. The split exists so the failure
   message can name the unit and point at
   `journalctl -u <unit> --no-pager -n 200` instead of surfacing a raw
   non-zero `rc` from the command itself.

The is-active re-check mirrors the existing `Test-RunnerServiceActive`
in the PowerShell flow: `ansible.builtin.systemd` reports `started`
even when the unit went active then immediately crashed (the module
observes the start transition only), so the explicit re-check is the
contract that catches a service that fails its first work cycle.

## Environment delivery

A VM declares its environment variables in its own config, and the
provisioner writes them into `/etc/environment` (Common-Ansible's
`vm_env_vars` role, or the equivalent PowerShell transport - both write
the same managed block). Nothing about that reaches a workflow job on
its own:

- `/etc/environment` is parsed by PAM's `pam_env`, for login sessions
  only. A systemd system service never reads it.
- actions/runner's `svc.sh install` generates a unit with no
  `EnvironmentFile=`, and the `runsvc.sh` it launches sources only
  `.path`.

So the variable is visible over SSH and absent from every job on the
same host - a discrepancy that reads as a provisioning failure when it
is really a delivery one. This role closes it with a single static
drop-in ([`files/10-environment-file.conf`](files/10-environment-file.conf)):

```ini
[Service]
EnvironmentFile=-/etc/environment
```

The leading `-` makes a missing file non-fatal, so the drop-in is safe
on a host that has never run the provisioner's env flow. Pointing the
unit at the file rather than templating values into it is what keeps
this repo from carrying a second copy of what the VM config already
declares.

**Why a restart is part of the contract.** `EnvironmentFile` is read
when a unit *starts*. A later edit of `/etc/environment` therefore does
not reach a running runner, and systemd exposes no signal for "the file
this unit read at start time has since changed" - the first CI job after
an env edit would silently use the old value. The role records the
checksum of `/etc/environment` in
`/opt/runners/<runnerName>/.environment-checksum` after each start and
restarts a unit when either:

- its drop-in was written by this run (the unit is running with no
  `EnvironmentFile` at all), or
- the recorded checksum differs from the file's current one.

Both conditions are evaluated per entry, not per host: a host-wide
"restart if anything changed" would bounce - and so kill the running job
of - every other runner on the box whenever a single new runner is
added. The record lives in the runner's own directory because it is
per-unit state and because
[`runner_binary`](../runner_binary/README.md)'s remove direction deletes
that tree, so a torn-down runner leaves nothing behind for the next one
to inherit.

The knowledge of *which units to bounce* deliberately stays here rather
than in the provisioner flow that writes the file: it is runner
knowledge, and pushing it outward would make a VM-wide mechanism depend
on what happens to be installed on the host.

**Security.** `/etc/environment` is world-readable and, through this
drop-in, flows into every workflow job on the host. Jobs already run as
the runner user on the same box and could read the file regardless, so
this adds no exposure - but it does mean nothing secret belongs in a
VM's declared environment. Secrets stay in GitHub Actions secrets, which
are masked in logs; `/etc/environment` values are not. If a host ever
carries a VM-level variable that must not reach jobs, that is the point
to switch to a per-runner `.env` instead of widening the unit's
environment wholesale.

## Remove direction

Selected by [`playbooks/deregister-runners.yml`](../../playbooks/deregister-runners.yml)
via `import_role { name: runner_service, tasks_from: remove }`. Runs
first in the remove order (before `runner_registration` and
`runner_binary`) because a running runner process can hold
`.credentials` open and race `config.sh remove`, so the unit must be
quiesced before the next role touches anything.

Inputs are the same `vm_runner_entries` slice the register direction
reads. Per entry, the role drives four phases:

1. **Unit probe.** Same `tasks/_probe-unit.yml` the register direction
   uses. An empty `stdout` for an entry means no unit is installed on
   this host (already torn down, or never installed) and both branches
   below skip that entry. The shared probe file is the single source of
   truth so the two directions cannot drift apart on glob / parser
   shape.
2. **Stop + disable.** `ansible.builtin.systemd` with `state: stopped`,
   `enabled: false`, `become: true`. Stock module idempotence makes
   already-stopped / already-disabled a silent no-op; only the
   active -> inactive transition reports `changed: true`.
3. **Drop-in removal.** `/etc/systemd/system/<unit>.d` deleted whole,
   not just the file this role renders: an empty `<unit>.d` is still a
   drop-in directory for a unit that no longer exists, and a future
   runner registered under the same name would inherit whatever it
   holds. `svc.sh uninstall` removes the unit file only and knows
   nothing about `<unit>.d`, so nothing else in the teardown would
   notice it surviving. Runs before the uninstall so the
   `daemon-reload` svc.sh performs is the last systemd-visible action.
4. **`svc.sh uninstall`.** `./svc.sh uninstall` with
   `chdir: /opt/runners/<runnerName>` and `become: true`. svc.sh resolves
   the runner root via `$(pwd)`, so the chdir is the contract (same as
   the install branch in the register direction). Removes the unit file
   under `/etc/systemd/system` and runs `daemon-reload`.

Idempotence: a second pass after a successful remove finds the probe
stdout empty for every entry and skips both branches with `changed: 0`.
A partial state (unit absent but `/opt/runners/<name>/` still present)
is also a silent no-op - the next role
([`runner_binary`](../runner_binary/README.md)'s remove direction) is
responsible for the on-disk extract.

Local marker files (`.runner`, `.credentials`,
`.environment-checksum`) are not touched on this path; they live inside
`/opt/runners/<name>/` and disappear when `runner_binary`'s remove
direction deletes the directory.

## Idempotence guarantees

- **Register direction.** Re-running with the same `vm_runner_entries`
  and a healthy fleet (every unit installed, enabled, started, and
  active) reports `changed: 0` across the role - the probe and re-probe
  includes are `changed_when: false`, the install branch's `when` skips
  because the probe stdout is non-empty, the systemd task reports `ok`
  for already-enabled+started units, and the is-active capture is also
  `changed_when: false`.
- **Register direction.** Environment delivery adds no churn to that:
  the drop-in copy is content-identical run to run, so the
  `daemon_reload` guarded on it skips, the recorded checksum matches
  the file so no unit is restarted, and rewriting the record with the
  same content reports `ok`. The first run after the drop-in is
  introduced does report changed (render, reload, restart, record) -
  once.
- **Register direction.** The register direction never stops, disables,
  or removes a unit. Tearing a registered runner down is the remove
  direction's job (below).
- **Register direction.** A new entry added to `vm_runner_entries`
  between runs reconciles only the new entry; existing healthy entries
  skip the install branch and the systemd task reports `ok`.
- **Remove direction.** Re-running after a successful remove reports
  `changed: 0` - the probe stdout is empty for every entry, the
  stop+disable branch and the uninstall branch both skip on the
  `length > 0` guard.
- **Remove direction.** A removed entry left in `vm_runner_entries`
  (e.g. an operator removed half the fleet) is a no-op for every
  already-removed entry; only entries whose unit is still installed
  produce work.

## Tests

Two molecule scenarios, one per direction. Both run inside a
systemd-enabled Ubuntu 24.04 container (privileged + cgroup mounts,
`/usr/sbin/init` as PID 1) so the `systemd` module, `systemctl
list-unit-files`, and `systemctl is-active` behave as they would on a
real VM. A stub `svc.sh` in each runner directory implements `install`
(writes a `Type=oneshot RemainAfterExit=yes` unit and
`systemctl enable`s it) and `uninstall` (disables the unit and removes
its file under `/etc/systemd/system`) - the active-without-a-long-lived
-process unit is all the role's reconcile and teardown contracts
observe.

The default scenario's stub unit runs
`ExecStart=/bin/sh -c 'env > /tmp/runner-env-<name>.txt'`. That dump is
the only way to observe what an `EnvironmentFile=` actually delivered:
`systemctl show -p Environment` reports inline `Environment=` settings
only and says nothing about a file the unit reads at exec time. A
`Type=oneshot` re-runs its `ExecStart` on restart, so the dump always
describes the most recent start.

[`Tests/molecule/runner_service/default/`](../../Tests/molecule/runner_service/default/)
exercises the register direction:

- **Install branch.** Entry with `/opt/runners/<name>/` pre-seeded but
  no installed unit - `svc.sh install` runs, the unit becomes active,
  the is-active re-check passes.
- **Already-installed + active.** Entry with the unit already
  enabled+started - the install branch skips, the systemd task reports
  `changed: 0`, the re-check passes.
- **Already-installed + stopped.** Entry with the unit enabled but
  stopped - the install branch skips, the systemd task starts the
  service, the re-check passes.
- **Re-converge.** A second pass against the post-converge state
  reports `changed: 0` across every task in the role.
- **Selector negative.** An entry on a different `vmName` does not
  leak onto the host under test (covered transitively by the
  [`runner_entry_resolve`](../runner_entry_resolve/README.md)
  scenario; the runner_service scenario also asserts no
  `actions.runner.*leak*.service` exists after converge).
- **Environment delivery.** `prepare` seeds one variable in
  `/etc/environment`; `verify` asserts every unit's drop-in carries the
  `EnvironmentFile` line, that every unit's env dump carries the
  variable, and that the recorded checksum matches the file. The
  runner-active entry is the load-bearing one: prepare started it
  before the drop-in existed, so its dump carries the variable only
  because the role noticed the new drop-in and restarted it.
- **Stale environment.** `verify` then edits `/etc/environment` and
  re-applies the role, asserting every dump picks up the new value.
  Mutating, so it lives in `verify.yml` rather than `converge.yml`:
  `molecule idempotence` runs converge twice, and a converge that edits
  the file would report changed on the second pass by construction.

[`Tests/molecule/runner_service/remove/`](../../Tests/molecule/runner_service/remove/)
exercises the remove direction. The prepare step drives the stub svc.sh
directly against a pre-seeded `/opt/runners/<name>/` to land
enabled+started units, and stages the `<unit>.d` drop-in the register
direction would have left (the stub models actions/runner's svc.sh,
which knows nothing about drop-in directories, so without this the
teardown assertion would be asserting the absence of something never
created). Converge then invokes the role with `tasks_from: remove`:

- **Active entry.** Unit present + active - stop + disable + drop-in
  removal + uninstall all run, the unit file and its `<unit>.d`
  directory are both absent under `/etc/systemd/system`, and
  `systemctl list-unit-files` returns no match for the runner name.
- **Inactive entry.** Unit present + inactive - stop is a no-op,
  uninstall runs, final state is no matching unit file.
- **Absent entry.** Probe stdout empty - both branches skip cleanly.
- **Multi-entry.** Two entries on the same host, both with units
  present - two stop tasks, two uninstall tasks, both end with no
  matching unit file.
- **Re-converge.** A second pass after a successful remove reports
  `changed: 0` across every task.

## Rationale

Three roles instead of one keeps each external surface in its own
file: this role owns the systemd surface end-to-end, `runner_binary`
owns the file-server / unarchive surface, `runner_registration` owns
the GitHub API surface. A molecule scenario for any one of them can
stub the others' surfaces without dragging the full register flow
into fixture territory.

The two-probe shape (probe, install-when-empty, re-probe, then
enable+start) is more verbose than threading the install-branch's
output into a Jinja conditional but is also more obvious: a reader
sees that the systemd task has the unit name regardless of whether
the install branch fired, and the re-probe cost is trivial against
the install cost. Mirrors the same "stat then act" idiom
`runner_binary` uses for its cache + extract guards.

The probe body itself lives in
[`tasks/_probe-unit.yml`](tasks/_probe-unit.yml) and is `include_tasks`
'd from both directions and from both call sites in the register
direction. One file is the single source of truth for the glob, the
parser, and the `runner_service_unit_probes` register name; both
directions stay locked together on systemctl output shape without
code duplication.

Splitting the is-active capture and the assert (rather than using
`failed_when: stdout != 'active'` on a single task) is what lets the
failure message render
`journalctl -u <unit> --no-pager -n 200` with the unit name
substituted. A bare `failed_when` would surface the command's
`rc != 0` with no operator hint; the explicit assert keeps the
debugging path one line away from the failure.
