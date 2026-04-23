# Problem

## Index
- [Summary](#summary)
- [Detail](#detail)

---

## Summary

There is no counterpart to `register-runners.ps1` for teardown. Deregistering
a runner currently requires manual steps across GitHub and the VM. This feature
adds `deregister-runners.ps1`, a script that reads the same vault config as
registration and cleanly removes each runner from both GitHub and the VM.

---

## Detail

### What needs to happen per runner

1. Stop the systemd service if it is running.
2. Uninstall the systemd unit via `svc.sh uninstall`.
3. Fetch a short-lived removal token from the GitHub API (POST
   `.../actions/runners/remove-token`), then run `config.sh remove --token`
   to deregister from GitHub and remove local credential files.
4. Delete the runner directory to leave no leftover files that could
   interfere with a future registration under the same name.

### Unreachable VM handling

| Mode | VM unreachable | GitHub has runner | Outcome |
|---|---|---|---|
| Normal | Yes | Yes | Collect error; report at end; no cleanup |
| Normal | Yes | No | Log and skip |
| Force (`-Force`) | Yes | Yes | DELETE via GitHub API; no VM-side cleanup |
| Force (`-Force`) | Yes | No | Log and skip |

Force mode is intended for cases where the VM is permanently gone or being
rebuilt and you need GitHub cleaned up regardless.

### Leftover cleanup

Leftover files are always checked on reachable VMs, regardless of whether the
runner is currently registered on GitHub. A partial install (e.g. a previous
registration attempt that failed mid-way) can leave service units or runner
directories that would block a future clean registration under the same name.

### Constraints

- Same vault inputs as `register-runners.ps1`: GitHubRunners vault for runner
  config, VmUsers vault for deploy credentials, GitHub PAT prompted at runtime.
- SSH via SSH.NET directly - same pattern and rationale as
  [feature 01](../01%20-%20initial%20implementation/problem.md).
- PAT requires `repo` scope (private) or `public_repo` (public) - same as
  registration. The removal-token endpoint and the DELETE runner endpoint use
  the same scope requirements.
- The script must be idempotent: re-running after a partial deregistration
  must complete cleanly without errors for already-removed resources.
