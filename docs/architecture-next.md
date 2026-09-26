# Architecture — MacSetupCore, Desired State, and what comes next

This describes the first step in evolving MacSetup from a provisioning tool
into a broader Mac lifecycle platform: a reusable core module, a Desired
State / compliance engine, and a Doctor health-check foundation. It's written
for whoever picks this up next — including a future MCP server, which this
was built to make cheap rather than to build outright.

## MacSetupCore

Before this change, MacSetup was one SPM executable target: the SwiftUI app
and the CLI's argument parsing (`Main.swift`) in the same binary, calling
straight into the same model classes. That already meant no duplication
between the app and the CLI — they're the same process. The gap was a
**future** MCP server or background agent, which can't link an executable
target's code without pulling in the whole app (and, transitively, SwiftUI).

`Sources/MacSetupCore` is a plain SPM library target with no SwiftUI import.
`Sources/MacSetup` (the app + CLI) depends on it. Everything that isn't
inherently UI or app-lifecycle now lives there:

```
MacSetupCore/
  Models/        Catalog, Profile, RoleTemplate, WebApp, VersionCompare
  Install/       InstallEngine, ScriptGenerator, ScriptPrelude, UpdateChecker,
                 SystemUpdateChecker, AppStoreChecker, OSInstallerCache,
                 OSUpgrade, JamfExport, PolicyExport
  Inventory/     MachineInventory — the installed-app disk scan
  Compatibility/ BinaryArchitecture, AppCompatibility
  DesiredState/  DesiredStateReport, DesiredStateComparator,
                 TweakComplianceProbe, RemediationPlan
  Doctor/        HealthCheck, Checks, DoctorEngine
  Notifier.swift, MachineSummary.swift
```

`Sources/MacSetup` keeps everything that's genuinely app-shaped: `AppState`
(the SwiftUI filter/selection hub — now a thin wrapper that calls
`MachineInventory.scan` rather than doing its own disk walk), `IconProvider`,
the nag/notification/unlock machinery, and all the Views. `Main.swift`'s CLI
dispatch imports `MacSetupCore` and calls into it exactly the way the SwiftUI
side does.

One real extraction happened during the move, not just a file relocation:
`AppState.scanInstalled()` used to do the `/Applications` disk walk itself.
That logic is now `MachineInventory.scan(catalogApps:)` in Core, and
`AppState` just calls it and publishes the result. This is what lets the CLI,
Desired State, and Doctor all see the same installed-app picture the app
does, instead of three copies of the same scan.

Nothing in Core is a UI type — no `Color`, `Image`, `Binding`, `View`. (The
one pre-existing exception, `InstallEngine.ItemState.tint: Color`, predates
this refactor and was left as-is rather than churned for its own sake; no new
Core code follows that pattern.)

## Desired State — data flow

```
 Profile / RoleTemplate.asProfile          (what you want)
            │
            ▼
 caller (CLI or DesiredStateEngine) gathers, in parallel with no I/O in the
 comparator itself:
   • MachineInventory.scan(catalogApps:)        — what's actually installed
   • UpdateChecker.check(apps: requiredApps)     — is each required app current
   • requiredTweaks.map(TweakComplianceProbe.check) — does each tweak's
                                                       `defaults` value match
            │
            ▼
 DesiredStateComparator.compare(...)   — pure, synchronous, no I/O
            │
            ▼
 DesiredStateReport
   apps / tweaks / webApps: ComplianceStatus per item
     (compliant | missing | outdated | different | unknown | extra | notApplicable)
   extraApps: informational, never auto-selected for removal
   summary: counts
            │
            ▼
 RemediationPlanner.plan(from: report, includeRemovals: Bool = false)
            │
            ▼
 RemediationPlan — [RemediationAction], each a kind (installApp, updateApp,
 applyTweak, createWebApp, removeApp, manualActionRequired, unsupported) plus
 a targetID. removeApp is the only kind that can carry
 requiresExplicitApproval, and the planner never emits one unless the caller
 opts in.
            │
            ▼
 caller resolves selected RemediationAction.targetID back to real
 CatalogApp / DefaultTweak / WebApp / UninstallTarget objects
 (RemediationResolver, app-side — the one place that knows both Desired State
 and the catalogue at once)
            │
            ▼
 the existing, unmodified InstallEngine.run(...) / .runUninstall(...)
```

`InstallEngine` never knows Desired State exists. That's deliberate: Desired
State is a planning layer on top of the same execution engine every other
part of MacSetup already uses, not a parallel install path.

Every stage that touches the outside world (disk scan, network update check,
`defaults read`) happens *before* the comparator, and the comparator itself
is a pure function of its inputs — which is what makes it trivially testable
(see `--test-desired-state`) and reusable from the CLI, the app's
`DesiredStateEngine` wrapper, and eventually MCP, without three different
implementations of "what does compliant mean."

### Why tweaks can be compared at all

Catalogue tweaks were apply-only before this: a `defaults write` command and
a `revert` command, no way to read current state. Every bundled tweak today
turns out to be exactly one or more `defaults write <domain> <key> -<type>
<value>` statements (confirmed against the live catalogue), which is
mechanical enough to parse and read back with `defaults read`. That's what
`TweakComplianceProbe` does. A tweak that doesn't fit that shape — or a
`defaults read` that fails — reports `unknown`, never a guessed
compliant/different. This is additive: no existing tweak behavior changed.

## Compatibility

`BinaryArchitectureDetector` reads the actual Mach-O (or fat/universal)
header of an app bundle's real executable — not the catalogue, not the app's
name. It never shells out to `file` or `lipo`; it parses the header bytes
directly, which is what makes it fast enough to run across every installed
app in Doctor's Rosetta check. Unreadable or unrecognized files are
`.unknown`, never a guess. `AppCompatibility` adds one derived fact today
(`rosettaLikelyRequired`, true only for an Intel-only app on an Apple Silicon
Mac) and is structured so future fields — supported macOS versions,
deprecated APIs, system/network extensions, privileged helpers, future macOS
readiness — can be added later without breaking anything that reads it now.
None of those speculative fields exist yet; this phase only implements what
can be read as fact.

## Doctor

`HealthCheck` is a small protocol (`identifier`, async `run() ->
HealthCheckResult`), and `DoctorEngine.run(catalogApps:)` runs the standard
set plus two that need the catalogue (outdated-app count, Rosetta-dependent
apps) and can't be generic protocol conformers without pulling the catalogue
into every check's initializer. Every check is read-only. A check that can't
get a clean answer from the system reports `.unknown` rather than asserting
something is insecure without a clear factual basis — see `FileVaultCheck`,
`GatekeeperCheck`, `SIPCheck`, `FirewallCheck` for the pattern. Adding a new
check later is adding a new `HealthCheck` conformer and one line in
`DoctorEngine.standardChecks` (or, for a catalogue-aware check, one more
private function alongside the existing two).

## Trust and security boundaries

These carry straight over from MacSetup's existing rules — Desired State and
Doctor don't loosen anything:

- **No shell execution surface in the planning layer.** `DesiredStateComparator`
  and `RemediationPlanner` never construct or run a command; they only ever
  describe intent (`RemediationAction`), and Doctor's checks each run one
  fixed, hardcoded command — never anything built from user or catalogue
  input.
- **Read operations need no approval; mutation always goes through a plan
  first.** Comparing and running Doctor never change anything. Turning a plan
  into an actual run still goes through `InstallEngine`, which already has
  its own authorization/authentication behavior (a single batched admin
  prompt for packages) — Desired State doesn't add or bypass any of that.
- **Removal is always separate and explicit.** `RemediationPlanner` never
  proposes `removeApp` unless the caller passes `includeRemovals: true`, and
  the UI requires that toggle *plus* an individual selection *plus* a final
  confirmation dialog before anything is moved to the Trash. Nothing is ever
  auto-uninstalled.
- **No generic command execution is exposed.** There is no `run_shell` or
  equivalent in Core's public API, in Desired State, or in Doctor. Every
  capability is a specific, named function.

## Toward an MCP server

Not built yet — deliberately: the point of this refactor was to make it
*cheap* once it's worth doing, not to build it speculatively. The public API
surface this phase produced already maps directly onto the tool set an MCP
server would expose:

| Future MCP tool | Backed by (MacSetupCore) |
| --- | --- |
| `get_system_info` | `ProcessInfo` + `Arch.current` (see `MachineSummary.current()`) |
| `get_installed_apps` | `MachineInventory.scan(catalogApps:)` |
| `get_profiles` | `ProfileStore` |
| `get_role_templates` | `Catalog.roleTemplateList` |
| `compare_desired_state` | `DesiredStateComparator.compare(...)` |
| `get_doctor_report` | `DoctorEngine.run(catalogApps:)` |
| `search_catalog` | `Catalog.apps` filtered the way `AppState`'s own filter already does (not yet lifted into Core as a standalone helper — small, obvious follow-up) |
| `get_updates` | `UpdateChecker.check(apps:)` |
| `create_remediation_plan` | `RemediationPlanner.plan(from:includeRemovals:)` |

Every one of these is already `Codable`/JSON-serializable (see
`--compare-profile --json` and `--doctor --json`) and none of them touch a
UI type. When an MCP server is actually built, the rules above carry over
unchanged: read tools can be non-interactive, `create_remediation_plan`
builds a plan an operator inspects before anything runs, privileged actions
still go through `InstallEngine`'s existing authorization, MCP clients never
see or handle a password, and there is no generic shell-execution tool to
expose in the first place.

## What's intentionally still manual

Unchanged from the rest of MacSetup: installing a macOS release still
requires a human at Software Update (Apple Silicon needs a volume owner's
password, which nothing here can supply); anything needing an administrator
password still raises exactly one batched prompt; removing an "extra" app is
always a distinct, explicitly confirmed action, never automatic; and nothing
in Desired State or Doctor writes to the Mac — only `InstallEngine`,
downstream of an explicit Apply, does that.
