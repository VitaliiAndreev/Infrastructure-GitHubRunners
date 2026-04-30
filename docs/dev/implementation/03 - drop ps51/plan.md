# Plan: Drop PowerShell 5.1 Support

See [problem.md](problem.md) for the full problem statement.

## Index

- [Step 1 - Code compromise and tests](#step-1---code-compromise-and-tests)
- [Step 2 - Version pins and documentation](#step-2---version-pins-and-documentation)

---

## Step 1 - Code compromise and tests

**Why:** Removes the one PS 5.1-specific workaround from production code and
cleans up stale rationale from comments and test names. Must precede Step 2
so tests validate the updated code before documentation is changed.

### Changes

#### `hyper-v/ubuntu/registration/common/config/Read-VmDeployPasswords.ps1`

| Location | Change |
|----------|--------|
| Lines 37-41 | Replace `$vm \| Select-Object -ExpandProperty users -ErrorAction SilentlyContinue` with `$vm.PSObject.Properties['users'].Value`; rewrite comment to remove PS 5.1 rationale |
| Lines 44-46 | Replace `$user \| Select-Object -ExpandProperty password -ErrorAction SilentlyContinue` with `$user.PSObject.Properties['password'].Value`; remove the stale comment above it |

#### `Tests/registration/common/config/Read-VmDeployPasswords.Tests.ps1`

| Location | Change |
|----------|--------|
| Lines 59-61 | Remove the PS 5.1 comment block from the "skips a VM entry where the users property is absent" test |

#### `Tests/registration/common/config/ConvertFrom-GitHubRunnersConfigJson.Tests.ps1`

| Location | Change |
|----------|--------|
| Line 60 | Rename: "normalises a bare JSON object to a 1-element array (PS 5.1 unwrap)" → "normalises a bare JSON object to a 1-element array" |
| Lines 61-63 | Remove the PS 5.1 comment; keep the description of what `ConvertTo-Array` does |

### Tests

Run `Run-Tests.ps1`. All tests must pass.

---

## Step 2 - Version pins and documentation

**Why:** Aligns bootstrap guards and module install pins with the new major
versions released as part of this family-wide PS 5.1 drop, and updates
operator-facing documentation to reflect the PS 7+ requirement.

### Changes

| File | Location | Change |
|------|----------|--------|
| `hyper-v/ubuntu/setup-secrets.ps1` | Line 55 | `[Version]'1.3.3'` → `[Version]'2.0.0'` |
| `hyper-v/ubuntu/setup-secrets.ps1` | Line 66 | `MinimumVersion '2.1.0'` → `'3.0.0'` |
| `hyper-v/ubuntu/register-runners.ps1` | Line 35 | `[Version]'1.3.3'` → `[Version]'2.0.0'` |
| `hyper-v/ubuntu/register-runners.ps1` | Line 63 | `MinimumVersion '2.1.0'` → `'3.0.0'` |
| `hyper-v/ubuntu/deregister-runners.ps1` | Line 49 | `[Version]'1.3.3'` → `[Version]'2.0.0'` |
| `hyper-v/ubuntu/deregister-runners.ps1` | Line 75 | `MinimumVersion '2.1.0'` → `'3.0.0'` |
| `Tests/Integration/Initialize-SshEnvironment.ps1` | Line 126 | `MinimumVersion '1.3.3'` → `'2.0.0'` |
| `README.md` | Index | Add `- [Requirements](#requirements)` entry |
| `README.md` | After index / before Prerequisites | Add Requirements section: "PowerShell 7+ (`pwsh`). Windows PowerShell 5.1 is not supported." |
| `README.md` | Line 22 | "PowerShell 5.1+" → "PowerShell 7+" |
| `README.md` | Line 23 | `Infrastructure.Common >= 1.3.3` → `>= 2.0.0` |

### Tests

Run `Run-Tests.ps1`. All tests must pass.
