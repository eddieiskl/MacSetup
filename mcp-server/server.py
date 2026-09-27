#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "mcp[cli]>=2.0.0",
# ]
# ///
"""MacSetupMCP (Python) — a read-only MCP server over MacSetupCore.

This is a thin adapter, not a reimplementation: every tool below shells out
to the existing `MacSetup` CLI binary and its stable `--json` output. No
MacSetup logic lives here — the CLI (backed by MacSetupCore) is the single
source of truth, exactly the same JSON a person would get running these
flags themselves.

Why Python and not the Swift MCP server (Sources/MacSetupMCP, removed): the
official Swift MCP SDK (modelcontextprotocol/swift-sdk) had a reproducible
bug where a moderately sized tool response (get_doctor_report) would compute
correctly in seconds but never actually reach the client — confirmed via
tracing that MacSetupCore's own logic finished fast and the delay was
entirely inside the SDK's response-delivery path. The Python SDK is the
project's reference implementation and doesn't exhibit this. See
docs/architecture-next.md for the full writeup.

Nine tools (get_doctor_report, compare_desired_state, get_role_templates,
get_profiles, get_system_info, get_installed_apps, search_catalog,
get_updates, create_remediation_plan) are read-only. One more
(apply_remediation) followed once that boundary was proven: the first only
describes intent (no execution, ever); the second actually calls
InstallEngine, through the same --apply-remediation CLI flag a person could
type themselves. apply_remediation has hard safety rails baked into the CLI
flag it shells out to, not just this adapter: it never attempts anything
needing an administrator password (those are always reported back as
skipped, never attempted — no `--allow-prompt` equivalent is exposed here,
ever), and removing an extra app needs both the plan to have included
removals and a separate confirm_removals=True at apply time. See
docs/architecture-next.md for the full trust-boundary writeup.
"""

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError

mcp = MCPServer(
    "macsetup",
    instructions=(
        "Read-only tools over a Mac's MacSetup catalogue, installed apps, and "
        "Desired State comparison. Nothing exposed here installs, updates, "
        "changes a system setting, or removes anything."
    ),
)

# A macOS release check inside --doctor can legitimately take several
# minutes in the worst case (softwareupdate --list has its own ~420s
# ceiling before MacSetup gives up) — this is documented, existing MacSetup
# behavior, not something this adapter should second-guess.
_SUBPROCESS_TIMEOUT_SECONDS = 480


def _find_macsetup_binary() -> str:
    """Locates the MacSetup binary, in the order a developer working in this
    repo is most likely to have one: an explicit override, a built .app
    bundle, a release build, a debug build, then finally whatever `MacSetup`
    resolves to on PATH (e.g. installed to /Applications)."""
    override = os.environ.get("MACSETUP_BIN")
    if override:
        return override

    repo_root = Path(__file__).resolve().parent.parent
    candidates = [
        repo_root / "build" / "MacSetup.app" / "Contents" / "MacOS" / "MacSetup",
        repo_root / ".build" / "release" / "MacSetup",
        repo_root / ".build" / "debug" / "MacSetup",
        repo_root / ".build" / "arm64-apple-macosx" / "release" / "MacSetup",
        repo_root / ".build" / "arm64-apple-macosx" / "debug" / "MacSetup",
    ]
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return "MacSetup"  # fall back to PATH


_MACSETUP_BIN = _find_macsetup_binary()


class MacSetupCLIError(ToolError):
    """The MacSetup CLI exited non-zero or produced output that wasn't the
    JSON it promises for --json flags. Subclasses ToolError so the model
    sees this message directly (e.g. "no saved profile or role template
    named 'X'") instead of a generic "Error executing tool"."""


def _run_macsetup_json(args: list[str]) -> Any:
    """Runs the MacSetup CLI with the given arguments plus --json, and
    parses stdout as JSON. Raises MacSetupCLIError with the CLI's own
    stderr message on failure — that message is already written for a
    person to read, so it's passed through rather than re-worded."""
    full_args = [_MACSETUP_BIN, *args, "--json"]
    try:
        result = subprocess.run(
            full_args,
            capture_output=True,
            text=True,
            timeout=_SUBPROCESS_TIMEOUT_SECONDS,
        )
    except FileNotFoundError as e:
        raise MacSetupCLIError(
            f"Could not find the MacSetup binary ({_MACSETUP_BIN!r}). "
            "Build it first (swift build, or Scripts/build-app.sh), or set "
            "the MACSETUP_BIN environment variable to its path."
        ) from e
    except subprocess.TimeoutExpired as e:
        raise MacSetupCLIError(
            f"MacSetup {' '.join(args)} did not finish within "
            f"{_SUBPROCESS_TIMEOUT_SECONDS}s."
        ) from e

    if result.returncode != 0:
        message = result.stderr.strip() or f"exit code {result.returncode}"
        raise MacSetupCLIError(message)

    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as e:
        raise MacSetupCLIError(
            f"MacSetup {' '.join(args)} did not produce valid JSON: {e}"
        ) from e


@mcp.tool()
def get_doctor_report() -> dict:
    """Run MacSetup Doctor's read-only health checks on this Mac: macOS
    version, architecture, free disk space, FileVault, Gatekeeper, System
    Integrity Protection, the Application Firewall, a pending macOS update,
    how many catalogue apps are outdated, and (on Apple Silicon) which
    installed apps are Intel-only and likely need Rosetta. Every check is
    read-only; a check that can't get a clean answer reports "unknown"
    rather than a guess."""
    return _run_macsetup_json(["--doctor"])


@mcp.tool()
def compare_desired_state(name: str) -> dict:
    """Compare a saved MacSetup profile or a bundled Role Template (matched
    by name) against what's actually installed on this Mac. Returns a
    Desired State report: for each required app, tweak and web app, whether
    it's compliant, missing, outdated, different, or unknown, plus a list of
    extra apps present but not requested (informational only — never
    proposed for removal by this tool). Use get_profiles or
    get_role_templates first to find a valid name. Read-only.

    Args:
        name: Name of a saved MacSetup profile or a bundled Role Template.
    """
    return _run_macsetup_json(["--compare-profile", name])


@mcp.tool()
def get_role_templates() -> dict:
    """List MacSetup's bundled Role Templates — curated starting selections
    for a job role or a way people use a Mac — by name, group and summary.
    Use this to find a valid name for compare_desired_state."""
    return {"roleTemplates": _run_macsetup_json(["--list-role-templates"])}


@mcp.tool()
def get_profiles() -> dict:
    """List the user's saved MacSetup profiles. Use this to find a valid
    name for compare_desired_state."""
    return {"profiles": _run_macsetup_json(["--list-profiles"])}


@mcp.tool()
def get_system_info() -> dict:
    """Basic facts about this Mac: hostname, macOS version, and CPU
    architecture (Apple Silicon or Intel). Read-only."""
    return _run_macsetup_json(["--system-info"])


@mcp.tool()
def get_installed_apps() -> dict:
    """List every application found on this Mac (name, version, bundle
    identifier, path), flagging which ones are in the MacSetup catalogue.
    Read-only — this only scans the filesystem, no network access."""
    return {"apps": _run_macsetup_json(["--installed-apps"])}


@mcp.tool()
def search_catalog(query: str = "", category: str | None = None) -> dict:
    """Search MacSetup's app catalogue by free text (matches name, vendor,
    summary, id and tags) and/or category id. Use this to find a catalogue
    id — for get_updates, or to check whether something is in the catalogue
    at all. Pass an empty query with just a category to list everything in
    it. Read-only.

    Args:
        query: Free-text search, e.g. "chrome" or "password manager". Empty
            matches everything (combine with category to just list one).
        category: A catalogue category id to restrict to (see the "id" field
            in each entry — this tool doesn't have a separate category list;
            an empty/unmatched category returns no results, not an error).
    """
    args = ["--search-catalog", query]
    if category:
        args += ["--category", category]
    return {"apps": _run_macsetup_json(args)}


@mcp.tool()
def get_updates() -> dict:
    """Check every installed catalogue app for a newer version. For each
    one, reports whether it's up to date, has an update available
    (installed vs. latest version), or couldn't be determined (reported as
    such rather than guessed), plus how the latest version was found
    (Homebrew, GitHub releases, the App Store, etc.). Read-only — this
    only checks, it never installs anything."""
    return {"results": _run_macsetup_json(["--check-updates"])}


@mcp.tool()
def create_remediation_plan(name: str, include_removals: bool = False) -> dict:
    """Propose fixes for whatever compare_desired_state found out of
    compliance for a saved profile or bundled Role Template: one action per
    gap (install a missing app, update an outdated one, apply a mismatched
    tweak, create a missing web app). This only describes intent — nothing
    is changed on the Mac by calling this. Pass an action's "id" to
    apply_remediation to actually run it.

    Removals are omitted unless include_removals=True, and even then are
    only ever proposed, never applied automatically — apply_remediation
    additionally requires confirm_removals=True before it will act on one.

    Args:
        name: Name of a saved MacSetup profile or a bundled Role Template.
        include_removals: Also propose removing extra apps present but not
            requested by this profile/template (still proposal-only).
    """
    args = ["--remediation-plan", name]
    if include_removals:
        args.append("--include-removals")
    return _run_macsetup_json(args)


@mcp.tool()
def apply_remediation(name: str, action_ids: list[str], confirm_removals: bool = False) -> dict:
    """Apply specific actions from a remediation plan — this makes real
    changes on the Mac: it can install apps, update apps, apply system
    tweaks, create web apps, and (only with confirm_removals=True, and only
    for actions the plan already flagged as removals) move an extra app to
    the Trash.

    action_ids must come from a prior create_remediation_plan or
    compare_desired_state call for the SAME name — an id from a different
    profile/template, or one that's stale because the Mac's state changed,
    is reported back as skipped rather than applied. Only the exact ids
    listed are touched; nothing else in the plan is applied.

    Anything that would need an administrator password (a .pkg installer, a
    Homebrew package needing sudo, anything needing a real terminal) is
    always skipped, never attempted — there is no way to make this tool
    raise a password dialog. Skipped items are reported back so the person
    can finish them manually in the MacSetup app.

    Removing an app needs two separate confirmations: the plan must have
    been created with include_removals=True, AND confirm_removals=True must
    be passed here too. Without both, any removeApp action in action_ids is
    reported as skipped rather than applied.

    Args:
        name: Name of a saved MacSetup profile or a bundled Role Template
            (must match the one create_remediation_plan was called with).
        action_ids: The exact plan action ids to apply (e.g.
            ["install-slack", "tweak-finder-show-extensions"]).
        confirm_removals: Required, in addition to the plan having included
            removals, before any removeApp action is actually applied.
    """
    args = ["--apply-remediation", name, "--actions", ",".join(action_ids)]
    if confirm_removals:
        args.append("--confirm-removals")
    return _run_macsetup_json(args)


if __name__ == "__main__":
    if not (Path(_MACSETUP_BIN).is_file() if os.sep in _MACSETUP_BIN else False):
        # A relative/bare "MacSetup" means we're relying on PATH — worth a
        # heads-up on stderr (never stdout, which is the JSON-RPC stream)
        # rather than failing silently on the first tool call.
        print(
            f"[macsetup-mcp] note: no built binary found next to this script; "
            f"relying on {_MACSETUP_BIN!r} via PATH or MACSETUP_BIN.",
            file=sys.stderr,
        )
    mcp.run()
