# Architecture — MacSetupCore, Desired State, and what comes next

This describes evolving MacSetup from a provisioning tool into a broader Mac
lifecycle platform: a reusable core module, a Desired State / compliance
engine, a Doctor health-check foundation, and a read-only MCP server on top
of all three. It's written for whoever picks this up next — including
whoever adds the MCP server's mutating tools, which this was built to make
cheap rather than to build outright.

## MacSetupCore

Before this change, MacSetup was one SPM executable target: the SwiftUI app
and the CLI's argument parsing (`Main.swift`) in the same binary, calling
straight into the same model classes. That already meant no duplication
between the app and the CLI — they're the same process. The gap was an MCP
server or background agent, which can't link an executable target's code
without pulling in the whole app (and, transitively, SwiftUI).

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

## The MCP server

`mcp-server/server.py` — a Python MCP server, not Swift. It's a thin adapter,
not a reimplementation: every tool shells out to the `MacSetup` CLI's
existing `--json` flags and returns that JSON verbatim (wrapped where the
flag returns a bare array, since a top-level object is the safer shape for a
tool result). **MacSetupCore remains the only place any of this logic
lives** — the Python file holds zero business logic, just argument-building,
subprocess invocation, and error passthrough.

| MCP tool | Backed by (CLI flag → MacSetupCore) | Status |
| --- | --- | --- |
| `get_doctor_report` | `--doctor --json` → `DoctorEngine.run(catalogApps:)` | ✅ implemented, read-only |
| `compare_desired_state` | `--compare-profile <name> --json` → `DesiredStateService.compare(name:profiles:catalog:)` | ✅ implemented, read-only |
| `get_role_templates` | `--list-role-templates --json` → `Catalog.roleTemplateList` | ✅ implemented (discovery helper) |
| `get_profiles` | `--list-profiles --json` → `ProfileStore` | ✅ implemented (discovery helper) |
| `create_remediation_plan` | `--remediation-plan <name> [--include-removals] --json` → `RemediationPlanner.plan(from:includeRemovals:)` | ✅ implemented, read-only (proposal only) |
| `apply_remediation` | `--apply-remediation <name> --actions <ids> [--confirm-removals] --json` → `RemediationSelector.select` + `InstallEngine.run`/`.runUninstall` | ✅ implemented, **mutating** — see below |
| `get_system_info` | — → `MachineSummary.current()` | not yet — trivial, small follow-up |
| `get_installed_apps` | — → `MachineInventory.scan(catalogApps:)` | not yet — trivial, small follow-up |
| `search_catalog` | — → `Catalog.apps` filtered the way `AppState`'s own filter already does (not yet lifted into Core as a standalone helper) | not yet |
| `get_updates` | — → `UpdateChecker.check(apps:)` | not yet |

`DesiredStateService` (`Sources/MacSetupCore/DesiredState/DesiredStateService.swift`)
is the one place that resolves a name to a profile/template and gathers the
comparator's inputs — the CLI's `--compare-profile` and the app's
`DesiredStateEngine` both call it, neither duplicates it. (The MCP server
doesn't call it directly; it calls the CLI, which calls it — one more hop,
same single source of truth.)

### Why Python, not Swift

The first attempt was a genuine Swift MCP server (`Sources/MacSetupMCP`,
since removed), using the official Swift SDK
(`modelcontextprotocol/swift-sdk`) directly against `MacSetupCore` — no
subprocess, no CLI in between. It worked for three of the four tools. For
the fourth, `get_doctor_report`, it reproducibly hung: a real MCP client
(Claude Code) reported "running tools…" for 9+ minutes with no response.

Diagnosis (stderr tracing added at each step, then removed): `DoctorEngine.run()`
itself finished in under 10 seconds every time — confirmed by tracing
inside the function. The handler function returned cleanly to the SDK, also
confirmed by tracing at that exact boundary. After that point, with the
process otherwise fully idle (no CPU activity, no open network connections,
no child processes), the JSON-RPC response simply never left the process —
sometimes for 90+ seconds, observed directly via a raw stdio harness talking
to the server the same way a real client does. The other three tools, whose
handlers return smaller payloads, responded instantly every time. That
points squarely at the Swift SDK's own response-serialization/delivery path
for this specific payload shape, not at anything in MacSetupCore, the
handler code, or the protocol framing — all three were traced and shown
correct.

Rather than debug a third-party SDK's internals further, the pragmatic move
was to swap the *adapter* layer only: the Python SDK is this project's
reference implementation, is more battle-tested, and — critically — doesn't
duplicate any MacSetup logic even in Python, since it just calls the same
CLI a person would. Confirmed on the actual failure case: the same
`get_doctor_report` call that hung indefinitely in Swift now returns in
about 12 seconds through Python, every time, including under a real MCP
client.

One real bug surfaced during this swap, worth recording because it looks
identical to a hang if you don't know it: the server resolves the `MacSetup`
binary itself (`_find_macsetup_binary()` in `server.py`), preferring a built
`.app` bundle. Early testing pointed it at an `.app` built *before* the two
new `--list-role-templates`/`--list-profiles` CLI flags existed — that
binary didn't recognize the flag, fell through to launching the full
SwiftUI app, and the launched GUI process (naturally) never exits. Rebuilding
the `.app` fixed it instantly. **Whoever runs this server needs an
up-to-date `MacSetup` binary** — an `MACSETUP_BIN` override or a fresh build
after pulling changes, same as any dev-loop dependency.

### `create_remediation_plan` and `apply_remediation`

These landed once the read-only boundary above had been proven out with a
real MCP client. `create_remediation_plan` is `RemediationPlanner.plan`
unchanged — pure, no execution, same as before. `apply_remediation` is the
first tool in the project that can make a real, unattended change to the
Mac, so it got a full design pass (not just an implementation) before being
built. The trust boundary:

- **Explicit selection, not a plan blob.** The MCP tool takes `action_ids`,
  not a whole plan — only the ids named are ever touched. The plan itself is
  always freshly re-derived server-side from the Mac's current state at
  apply time (action ids are deterministic strings like `"install-slack"`,
  not random, so this needs no server-side session/token); an id that's
  stale because the Mac's state changed is reported back as skipped.
- **Privilege is filtered out, never attempted.** `CatalogApp.needsElevatedBatch`
  (`needsRoot || isBrewPackage || needsTerminal`) is checked *before*
  anything reaches `InstallEngine`. This matters because the only escalation
  mechanism in this codebase is `osascript ... with administrator
  privileges` (`ScriptPrelude.swift`), which needs a real logged-in GUI
  session — and the MCP server usually *is* running inside one (Claude
  Desktop). Relying on "it'll fail safely with no window server" would have
  been wrong on this exact setup; a privileged app handed to `InstallEngine`
  unfiltered would pop a real, unattended admin-password dialog. So
  filtering happens up front, unconditionally, with no `--allow-prompt`
  equivalent ever exposed via MCP.
- **Removals need two confirmations.** The plan must have been computed with
  removals visible (`include_removals`/`--include-removals`), *and*
  `confirm_removals`/`--confirm-removals` must be passed again at apply
  time. Uninstalls themselves never need root (a `.pkg`-installed app is
  refused outright — "remove it with the vendor's own uninstaller" — and
  everything else is a plain move to `~/.Trash`), so the extra confirmation
  is purely about not deleting things a caller didn't clearly ask for, not
  about privilege.
- **The selection/filtering logic is pure and separately tested.**
  `RemediationSelector` (`Sources/MacSetupCore/DesiredState/RemediationSelector.swift`)
  does all of the above with no `Process`, no I/O — `--test-remediation-apply`
  exercises it directly (stale ids, unconfirmed removals, a synthetic
  `.pkg`-sourced app) without ever running a real install. Actually applying
  something for real is verified manually against this Mac instead, the same
  way real installs are skipped under `--offline` elsewhere in the suite.
- **Still no generic shell-execution tool, and none is planned.** Every
  action maps to one of `InstallEngine`'s existing, already-reviewed entry
  points (`run`/`runUninstall`) — nothing here can execute arbitrary
  commands.

**A real bug this surfaced, unrelated to the MCP work itself but found while
testing it:** `msu_make_webapp` (`ScriptPrelude.swift`) used to `rm -rf` the
target path unconditionally before creating a web app bundle. A catalogue web
app's display name can coincidentally match a real, unrelated installed
application — `/Applications/GitHub.app` on this machine, for the "GitHub"
web app — and the unconditional `rm -rf` destroyed it, permanently (no Trash
move, and this Mac had no Time Machine backup). This was pre-existing,
already-shipped behavior; the same destructive path exists in the GUI's own
"Apply" button whenever a name collides, it just hadn't been hit yet. Fixed
by refusing to touch anything at that path whose `CFBundleIdentifier` isn't
already `local.macsetup.webapp.<id>` — verified against three cases
(collision refused, fresh create still works, updating MacSetup's own
previous bundle still works). Worth remembering: **any code that deletes
something by a user-controlled or catalogue-controlled name, rather than by
an id it created itself, needs to check what's actually there first.**

## What's intentionally still manual

Unchanged from the rest of MacSetup: installing a macOS release still
requires a human at Software Update (Apple Silicon needs a volume owner's
password, which nothing here can supply); anything needing an administrator
password still raises exactly one batched prompt; removing an "extra" app is
always a distinct, explicitly confirmed action, never automatic; and nothing
in Desired State or Doctor writes to the Mac — only `InstallEngine`,
downstream of an explicit Apply, does that.
