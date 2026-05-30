# Problem: Drop PowerShell 5.1 Support

## Index

- [Context](#context)
- [What changes](#what-changes)
  - [Code compromise to remove](#code-compromise-to-remove)
  - [Comments to update](#comments-to-update)
  - [Version pins to bump](#version-pins-to-bump)
  - [Documentation](#documentation)
- [What stays](#what-stays)
- [Out of scope](#out-of-scope)

---

## Context

PowerShell-Common (2.0.0), Infrastructure-Secrets (3.0.0),
Infrastructure-Vm-Provisioner, and Infrastructure-Vm-Users have all dropped
PS 5.1 support. Infrastructure-GitHubRunners is the last repo in the family
that still declares PS 5.1 compatibility.

The shared CI workflow (`ci-powershell.yml@master`) now runs only on PS 7,
so the PS 5.1 test job is already gone at the CI layer. The remaining work
is to remove the one in-code compromise and clean up stale comments and
documentation.

---

## What changes

### Code compromise to remove

`Read-VmDeployPasswords.ps1` uses `Select-Object -ExpandProperty <name>
-ErrorAction SilentlyContinue` to safely read optional properties on
PSCustomObjects produced by `ConvertFrom-Json`. The comment explains the
reason:

> ConvertFrom-Json in PS 5.1 omits properties whose JSON value is an empty
> array, so 'users' may not exist.

In PS 7, `ConvertFrom-Json` always preserves properties regardless of their
value (including empty arrays), so this workaround is no longer needed as a
PS 5.1 guard. The idiomatic PS 7 replacement for safe optional-property
access is `PSObject.Properties['key'].Value`, which returns `$null` when
the property is absent and the property value otherwise — no cmdlet
invocation, no error suppression needed.

Two calls to replace in `Read-VmDeployPasswords.ps1`:

| Current | Replacement |
|---------|-------------|
| `$vm \| Select-Object -ExpandProperty users -ErrorAction SilentlyContinue` | `$vm.PSObject.Properties['users'].Value` |
| `$user \| Select-Object -ExpandProperty password -ErrorAction SilentlyContinue` | `$user.PSObject.Properties['password'].Value` |

### Comments to update

Stale PS 5.1 rationale in production code and tests:

| File | Change |
|------|--------|
| `Read-VmDeployPasswords.ps1` | Remove "ConvertFrom-Json in PS 5.1 omits properties..." from both property-access comments |
| `Tests/.../Read-VmDeployPasswords.Tests.ps1` | Test name "skips a VM entry where the users property is absent" comment referring to PS 5.1 behaviour |
| `Tests/.../ConvertFrom-GitHubRunnersConfigJson.Tests.ps1` | Test name "normalises a bare JSON object to a 1-element array (PS 5.1 unwrap)" and its inline comment |

### Version pins to bump

Three entry-point scripts and one integration test helper pin minimum
versions for the two upstream modules:

| File | Module | Old pin | New pin |
|------|--------|---------|---------|
| `setup-secrets.ps1` | PowerShell.Common | `1.3.3` | `2.0.0` |
| `setup-secrets.ps1` | Infrastructure.Secrets | `2.1.0` | `3.0.0` |
| `register-runners.ps1` | PowerShell.Common | `1.3.3` | `2.0.0` |
| `register-runners.ps1` | Infrastructure.Secrets | `2.1.0` | `3.0.0` |
| `deregister-runners.ps1` | PowerShell.Common | `1.3.3` | `2.0.0` |
| `deregister-runners.ps1` | Infrastructure.Secrets | `2.1.0` | `3.0.0` |
| `Tests/Integration/Initialize-SshEnvironment.ps1` | PowerShell.Common | `1.3.3` | `2.0.0` |

### Documentation

| File | Change |
|------|--------|
| `README.md` | Add Requirements section with index entry: "PowerShell 7+ (`pwsh`). Windows PowerShell 5.1 is not supported." |
| `README.md` | Prerequisites: "PowerShell 5.1+" → "PowerShell 7+" |
| `README.md` | Prerequisites: `PowerShell.Common >= 1.3.3` → `>= 2.0.0` |
| `README.md` | CI section: remove mention of PS 5.1 test job |

---

## What stays

- **`ConvertTo-Array` usage** in `ConvertFrom-GitHubRunnersConfigJson.ps1`.
  `ConvertFrom-Json` in PS 7 emits a JSON array as a single pipeline item
  (not one item per element), so `@($pipeline)` wraps it in a 1-element
  array. `ConvertTo-Array` normalises both `$scalar` and `@(array)` inputs
  to a consistent array — still needed, not a PS 5.1 artefact.
- **`@($variable)` unwrapping** after `ConvertFrom-Json`. The comment in
  `Read-VmDeployPasswords.ps1` explaining PS 7's pipeline-item behaviour
  is accurate and stays unchanged.

---

## Out of scope

- Behaviour changes to runner registration or deregistration logic.
- Changes to integration tests beyond the version pin bump.
