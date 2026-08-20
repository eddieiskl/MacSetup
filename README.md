# MacSetup

Provision a new Mac from a curated catalogue. Pick apps by category, hit install,
and watch a generated bash script pull each one **straight from the vendor's own
servers** with live per-app status.

Built for the "I just got handed a new Mac" problem — personal or fleet.

---

## Build

```bash
./Scripts/build-app.sh
```

Produces `build/MacSetup.app` — a 3.3 MB universal binary (Apple Silicon +
Intel) with **no runtime dependencies**. Copy it to a USB stick or a share and
run it on any fresh Mac running macOS 14+. No Xcode, no Homebrew, no Node.

> Building needs Swift (Xcode Command Line Tools are enough — full Xcode is not
> required). The universal binary is produced by compiling each slice with
> `--triple` and joining them with `lipo`.

Install it: `cp -R build/MacSetup.app /Applications/`

## Sharing it with someone else

```bash
./Scripts/package-for-sharing.sh
```

Produces `build/MacSetup.zip` and `build/READ-ME-FIRST.txt`. **Send both.**

This build is signed ad-hoc, and macOS quarantines anything downloaded or
AirDropped. The combination makes macOS report *"MacSetup is damaged and can't
be opened"* — it is not damaged, but the recipient must clear the flag once:

```bash
xattr -dr com.apple.quarantine /Applications/MacSetup.app
```

To avoid that entirely, sign with a Developer ID (a paid Apple Developer
account) and notarise:

```bash
./Scripts/package-for-sharing.sh "Developer ID Application: Your Co (TEAMID)"
xcrun notarytool submit build/MacSetup.zip --keychain-profile <profile> --wait
xcrun stapler staple build/MacSetup.app
```

## Use

Launch it, filter the catalogue, tick what you want, press **Install**.

- **Sidebar** — 14 categories, plus Quick Picks that select whole tags at once
  (Essentials, Business Baseline, Free & Open Source) and your saved profiles.
- **Filters** — free-text search across name/vendor/description, tag chips,
  license, install source, "hide what's already installed", and sorting.
- **Preview Script** — read the exact bash before anything runs, copy it, or
  save it as a `.sh` for a runbook or MDM.
- **Review Selection** — per-run options and a final check of what will happen.
- **Web Apps** — install a site as its own app (see below).
- **Installed** — everything on the Mac, and what to remove.
- **Updates** — what is installed, what is newer, and where that came from.
- **System Tweaks** — 18 reversible `defaults` settings, each showing its exact
  command and how to undo it.

### AI & Assistants

A dedicated category covers the assistants people now install first: **Claude**
and **ChatGPT** (both direct from the vendor, both with Team IDs verified
against real installs), **Ollama**, **LM Studio**, **Jan**, **GPT4All**,
**AnythingLLM**, **Msty**, **Cherry Studio** and **Witsy** for local or
bring-your-own-key models, **Perplexity**, **Elephas**, **MacWhisper**,
**superwhisper** and **DiffusionBee**.

Command-line AI tools (`aider`, `llm`, `gemini-cli`) live under Terminal & CLI,
and everything AI-related — including Cursor and Claude Code — carries the `ai`
tag, so the tag chip selects the lot in one click.

### Microsoft

Beyond the Microsoft 365 suite installer, each app is available on its own —
**Word, Excel, PowerPoint, Outlook, OneNote** — so you can put Excel on a
finance Mac without dragging the rest along. Every one comes from a
`go.microsoft.com/fwlink` ID that resolves to Microsoft's current signed
package, so they are always the latest build.

For managed fleets there is **Intune Company Portal** (the enrolment starting
point), **Microsoft Defender**, and **Microsoft AutoUpdate**, plus
**PowerShell**, **Azure CLI**, **.NET SDK** and **Azure Data Studio**. Together
with Edge, Teams, OneDrive and Windows App, 18 entries carry the `microsoft`
tag, so one chip selects the lot.

> Skype has no entry: its download link now redirects to a support page, and
> Microsoft has retired the product.

### VPN & Networking

A dedicated category covers the consumer VPNs people actually ask for —
**ExpressVPN, NordVPN, Proton VPN, Mullvad, Surfshark, Windscribe, Private
Internet Access, CyberGhost, IVPN** — alongside the ones that matter for
administered machines: **Cloudflare WARP** (also the Zero Trust client),
**OpenVPN Connect**, **Tunnelblick** and **Viscosity** for custom profiles, the
`wireguard-tools` and `openvpn` command line tools, and **Tailscale**, which
moved here from Security.

### Web apps

Google Workspace has no native Mac client, and neither do most admin consoles.
MacSetup installs any site as a **real .app** — Dock icon, Spotlight entry, its
own window — instead of another browser tab.

44 sites are catalogued across Google Workspace (Gmail, Calendar, Drive, Docs,
Sheets, Slides, Meet, Chat, Keep, Admin, Gemini…), Microsoft 365 (Outlook Web,
Teams Web, the 365/Azure/Entra/Intune admin centres), work tools (Notion,
Trello, Asana, Linear, Jira, Figma, Miro, Slack…), AI, developer dashboards and
media. **Add your own** with a name and URL — ideal for an intranet or an
internal dashboard. Custom entries are saved locally and travel inside any
profile you export.

**Two modes**, chosen in the Web Apps pane:

| | Dock behaviour | Sign-in |
|---|---|---|
| **Open in browser** (default) | Hands off to the browser and exits, so the bundle does **not** stay in the Dock | Shares the browser's session — Google and Microsoft SSO just work |
| **Standalone app** | A real application: its own Dock icon, window and Cmd-Tab entry, alive as long as it is open | Its own cookie store, so you sign in once per app |

If a web app vanishes from the Dock the moment it opens, that is browser mode
working as designed: the bundle's only job is to hand the URL to the browser,
and the window then belongs to the browser. Switch to **Standalone app** for a
bundle that behaves like a native application.

The catch is Google: it blocks sign-in from embedded windows, so Gmail, Calendar
and Drive need browser mode. Most other sites — Notion, Linear, Trello, admin
dashboards, internal tools — work fine standalone.

Standalone bundles embed a small WebKit host shipped inside MacSetup.app. An
exported script run on a machine without MacSetup falls back to browser mode
automatically.

**How browser mode works.** The bundle's launcher is one line:

```bash
exec "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --app="https://mail.google.com/"
```

Chromium browsers (Chrome, Edge, Brave, Vivaldi, Chromium) support `--app=`,
which gives a genuinely chromeless standalone window. Safari, Firefox and Arc
have no equivalent flag, so they open an ordinary window — the browser picker
says which you are getting. The browser's **normal profile** is used, so you
stay signed in to Google and Microsoft.

The browser is invoked directly rather than through `open --args`, because
`open` will not pass flags to a browser that is already running.

Icons are fetched from the site (`apple-touch-icon.png`, `favicon.ico`, or an
explicit URL for the sites that publish neither) and converted to `.icns` with
`sips` and `iconutil` — including `.ico` and `.webp` sources. A site with no
usable icon still installs; it just gets the system default.

### Download progress

Each download reports a real percentage, not a spinner. The total size comes
from the **actual download's response headers** rather than a separate `HEAD`
request, because several vendors answer `HEAD` without a `Content-Length` or
answer it differently from the `GET` that follows. Progress is polled from the
file on disk several times a second, so the queue shows `3.4 MB of 4.1 MB`
climbing in real time.

When a vendor genuinely will not declare a size, the transferred byte count is
shown instead of a fake percentage.

### Icons

Every entry — catalogue app **and** web app — shows an icon, resolved
cheapest-source-first:

1. **The real icon**, if the app is already installed on this Mac — exact, instant, offline.
2. **The on-disk cache**, from a previous lookup.
3. **An explicit icon URL** from the catalogue's `icon` field, then
   **the site itself** (`apple-touch-icon.png`, `favicon.ico`, or whatever the
   homepage declares). First-party only — no third-party favicon service, so no
   browsing data goes anywhere except to the vendors you were already about to
   download from.

   Each candidate must decode as a real image before it is accepted. Plenty of
   sites answer a missing icon path with an HTML soft-404, and taking the first
   non-empty response would let that shadow the working `favicon.ico` further
   down the list.

**Why the `icon` field exists.** Resolving by host alone means every entry
sharing a homepage gets identical artwork — all ten `microsoft.com` apps, all
thirteen projects hosted on `github.com`, Chrome and Google Drive. So:

- GitHub-hosted projects fall back to the **owner's avatar**
  (`https://github.com/<owner>.png`), derived automatically from the repo or
  homepage — no catalogue entry needed.
- Products with real published icons get an explicit URL: Word, Excel,
  PowerPoint, Outlook, OneNote, Teams and OneDrive come from Microsoft's Fabric
  brand CDN; Chrome, Drive, Docs, Sheets and Slides from Google's.
- Where a vendor publishes **no distinct icon at all** (Defender, Company
  Portal, the Azure/Entra/Intune admin portals, the Objective-See tools), the
  catalogue sets `"icon": "none"` to force a monogram. A distinct coloured tile
  beats a fifth identical corporate logo.
4. **A generated monogram tile** — deterministic colour per app id, so a card is
   never blank and never changes colour between launches.

Measured coverage, resolved fresh with no cache:

| | real icon | monogram | duplicate artwork |
|---|---:|---:|---:|
| Web apps | 41 / 44 | 3 (deliberate) | **none** |
| Catalogue apps | 131 / 147 | 16 (11 deliberate) | **none** |

`--check-icons` fingerprints every resolved image and reports any two entries
that render the same artwork, so this cannot regress silently.

Check it yourself at any time — vendor icons move too:

```bash
MacSetup.app/Contents/MacOS/MacSetup --check-icons --no-cache          # web apps
MacSetup.app/Contents/MacOS/MacSetup --check-icons --apps --no-cache   # catalogue
```

Turn step 3 off with *"Load app icons from vendor websites"* in Review
Selection for locked-down or offline networks; steps 1, 2 and 4 still work.

### Command line

The same binary is scriptable, which is handy for onboarding automation:

```bash
MacSetup.app/Contents/MacOS/MacSetup --list
MacSetup.app/Contents/MacOS/MacSetup --emit-script google-chrome,slack,rectangle > setup.sh
bash setup.sh
```

---

## How installs actually work

Each catalogue entry names a **real vendor URL**. Nothing is scraped at runtime
except GitHub releases, where the latest release is resolved through the API and
an asset is matched by filename pattern — so you always get the current version.

| Source | Count | What happens |
|---|---:|---|
| Direct from vendor | 40 | `curl` the vendor's own URL, then mount/expand/install |
| GitHub release | 12 | Resolve the latest release asset, then as above |
| Homebrew | 107 | `brew install [--cask]`, for apps with no stable direct link |
| Vendor script | 3 | The maker's own documented install script |

42 entries also carry a **Homebrew fallback**: if the vendor
link breaks, that app alone falls back instead of failing the run.

### Pause and resume

A run can be paused from the queue. Pausing takes effect **between items**,
never in the middle of a download, a copy or an installer — the item in flight
always finishes first, so a pause can never leave an app half-installed.

### Privileges

Nearly everything runs as you, with no password:

- `.dmg` and `.zip` apps are copied into `/Applications`, which is
  group-writable by admin users.
- Homebrew and `defaults` must *not* run as root, and don't.

Of the catalogue, **16 apps need an administrator password and 146 do not**.
The bottom bar states which before you start (*"no password needed"*, *"1
password prompt for 3 packages"*), and a filter hides anything that needs one.

Only `.pkg` installers genuinely need root. Those are downloaded during the
normal pass, queued, and installed at the very end inside a **single**
`osascript … with administrator privileges` call — so you approve **one**
dialog per run, not one per package. (Installing Homebrew, if it's missing,
needs one additional prompt to create its prefix.)

**Apps that need a password all take the same route.** Homebrew only needs root
for its final install step — downloading needs nothing. So MacSetup fetches with
`brew fetch` and then installs through its own single elevated batch:

* Casks that ship a **`.pkg`** — Tailscale, NordVPN, Mullvad, Cloudflare WARP,
  OpenVPN Connect, VirtualBox, Wireshark and the rest — are installed with
  `installer`.
* Casks that ship their **own installer program** (Adobe Creative Cloud, Backblaze, BlockBlock, ExpressVPN, GPT4All, Private Internet Access, Windscribe) are extracted, their
  signature is checked, and only then is the installer run as root. This is what
  Homebrew does with `sudo`; the difference is that it happens behind the one
  authorisation dialog instead of needing a terminal.

Nothing runs as root before its code signature has been verified, and the Team
ID is reported in the queue either way.

If Homebrew still hits a `sudo` prompt for some cask not covered above, the run
does not hang: that item is handed to a real Terminal window where you can enter
your password, and the rest of the queue carries on.

### Verification

With verification on (the default), every download is checked before it lands:

- `codesign` for apps, `pkgutil --check-signature` for packages
- the observed **Team ID** is compared against the catalogue's expected value
- `spctl` runs the same Gatekeeper assessment macOS itself would

By default a mismatch is **reported but not fatal** — the run continues and the
signature shows in the queue row. Turn on *"Abort an app if its signature does
not check out"* in Review Selection to make any mismatch fail that item, with no
Homebrew fallback.

---

## Profiles

Save a selection as a named profile, then re-apply it on the next machine.
Profiles export to plain JSON, so a "Business Baseline" can live in a repo or be
handed to a colleague:

```json
{ "kind": "macsetup.profile", "version": 1, "name": "Business Baseline",
  "apps": ["google-chrome", "slack", "1password"], "tweaks": ["finder-show-extensions"] }
```

Importing warns about any ids the current catalogue no longer knows. Profiles
also carry their run options — signature verification, standalone web apps, and
the rest — so a profile applied on another Mac behaves the same way rather than
silently reverting to defaults. Older profiles without them still load.

---

## Updates

MacSetup doubles as an update checker. It reads the version of every catalogue
app installed on the Mac and compares it against what the vendor publishes,
using whichever source is authoritative for that app:

| Source | How the latest version is found |
|---|---|
| Homebrew | one `brew info --json=v2` call covering every brew-backed app |
| GitHub | the `/releases/latest` **redirect**, not the API — no rate limit |
| Direct | follows redirects and reads the version out of the filename or a path segment |
| Sparkle | reads `SUFeedURL` from the installed app and parses its appcast |

Updating an app simply reinstalls it from the same source, with the
skip-if-installed rule turned off.

**It will not guess.** Version strings on macOS are a zoo — `0.98`,
`16.112.26081720`, `7.0.6 (84834)`. Anything that cannot be compared with
confidence is reported as *could not determine*, never as an update. Apps that
ship their own updater (Chrome via Keystone, everything Microsoft via AutoUpdate,
Docker, 1Password) say so explicitly rather than showing an unhelpful "unknown".

From the command line, which suits a cron job or an MDM report:

```bash
MacSetup.app/Contents/MacOS/MacSetup --check-updates
```

```
  UPDATE   Obsidian     1.12.7 -> v1.13.7          [GitHub release]
  UPDATE   Zoom         7.0.6 (84834) -> 7.1.5.84650   [vendor download]
  current  Rectangle    0.98                       [GitHub release]
  unknown  Google Chrome 151.0.7922.140  (updates itself via Google Keystone)
```

---

## Automatic update checking

MacSetup checks for updates a few seconds after it opens and posts a macOS
notification if anything is out of date:

> **1 update available**
> Microsoft OneDrive. Open MacSetup to install.

Both behaviours are toggles in the Updates pane. Beyond that, **Run on a
schedule** installs a launchd agent that works *even when MacSetup is closed* —
which is the point, since an admin tool that only notices updates while it
happens to be open is not much use. Pick the frequency, the hour, and what it
should do:

| Action | What the scheduled run does |
|---|---|
| **Notify me** | Checks and posts a notification if anything is out of date |
| **Install automatically** | Installs what it can, unattended |

Midnight daily is the default: the machine is idle and little is open.

```bash
MacSetup --auto-update            # what the agent runs
MacSetup --auto-update --dry-run  # see what it would do, change nothing
```

**What unattended updating deliberately will not do.** A user launch agent runs
as you, not as root, and nobody is at the keyboard at midnight to approve a
password prompt. So the scheduled run:

* **skips any app that is currently open** — replacing a bundle underneath a
  running app can corrupt it;
* **skips anything needing an administrator** (`.pkg` installers and the
  privileged Homebrew casks) and reports them instead.

That still covers **125 of the 162** apps, which install with no password at all.
The remainder are listed in a notification so you can approve them in one batch
next time you open MacSetup.

For genuinely unattended patching of the privileged apps as well, the honest
answer is an MDM: the Jamf policy script runs as root under the `jamf` binary,
so every installer works with no prompt. See the Jamf section above.

Notifications come from `UserNotifications` when running as the app, so they are
attributed to MacSetup and can be clicked. A launchd job runs the binary outside
an app context where that framework refuses to register, so there is an
AppleScript fallback for that case.

### The full-screen update screen

Off by default. When enabled, a screen covering every display appears at login
and at every unlock until macOS is updated.

**It is MacSetup's own window, not System Settings.** macOS gives no app control
over another app's windows — level, size and ordering belong to the owning
process — so nothing can force Software Update full-screen and keep it on top.
What is possible is MacSetup's own window doing that, with a button that opens
Software Update. Every managed-update tool on macOS works this way, for the same
reason.

- appears after a configurable number of days (default 7)
- sits at `.screenSaver` level: above ordinary windows and the menu bar, and
  deliberately **not** above the login window or screen saver
- covers every display, and re-fits when one is plugged in or removed
- **a deferral is always offered.** It shortens from an hour to ten minutes past
  the deadline, but never disappears. A screen with no way out can trap someone
  mid-presentation on a laptop, which is an incident, not a policy. If you want
  a harder block, that is a deliberate change to `NagPolicy.shouldShow`.

To see it without turning it on:

```bash
/Applications/MacSetup.app/Contents/MacOS/MacSetup --nag --past-deadline
```

Needs **Start MacSetup at login** for the "after a restart" case, otherwise the
app is not running to show anything. That can be set from the command
line for a fleet:

```bash
/Applications/MacSetup.app/Contents/MacOS/MacSetup --login-item on
/Applications/MacSetup.app/Contents/MacOS/MacSetup --login-item      # status only
```

### Downloading macOS ahead of time

The 18 GB does not have to be part of the interruption. `--fetch-full-installer`
downloads *Install macOS <name>.app* into `/Applications`, which is an ordinary
app download needing no special authorisation — unlike `softwareupdate -d`,
which demands a volume owner's password even to stage a release.

```bash
/Applications/MacSetup.app/Contents/MacOS/MacSetup --cache-os-installer --dry-run
/Applications/MacSetup.app/Contents/MacOS/MacSetup --cache-os-installer
```

`softwareupdate` does not always fail cleanly. It can simply stop: zero CPU, no
output, process still alive. Retrying on exit alone waits on that forever, so a
watchdog kills a run that has produced no output for 12 minutes and retries it.

Only one `softwareupdate` runs at a time. Two sessions competing for
`softwareupdated` is a known way to wedge both — which is how the first cache
attempt died here, when an install was attempted while a fetch was running.

An 18 GB download over wifi will sometimes fail partway — that is ordinary, not
exceptional — so it retries up to four times with a growing backoff. It retries
only reasons a retry can fix: a dropped connection yes, out of disk or a version
Apple does not offer no, since retrying those wastes bandwidth and hides the
real reason.

It refuses if the disk lacks the download plus 15 GB of headroom — an installer
that half-downloads overnight and leaves no room to log in is worse than none.
Once cached, the update screen says *Already downloaded* and its button starts
the installer instead of opening Software Update. The password is still needed
to *run* it, which is the part only the user can do anyway.

A cached installer only counts if its version matches the release being offered;
an installer for an older macOS would look ready while installing the wrong
thing.

### Reminding you about macOS itself

App updates get installed for you. A macOS release cannot be — so it is the one
update that sits ignored for months, and the one where being out of date matters
most. MacSetup therefore reminds you about it separately, and gets more direct
as the weeks pass:

| Age | Notification |
| --- | --- |
| new | *macOS Tahoe 26.7 is available* |
| 7 days | *Time to update macOS* |
| 14 days | *macOS is two weeks out of date* |
| 30 days | *macOS is a month out of date* |

Clicking the notification opens Software Update directly. At most one of these a
day, and the age is counted from when Apple first offered the release, not from
when you installed MacSetup.

To see one immediately:

```bash
/Applications/MacSetup.app/Contents/MacOS/MacSetup --remind-os --force
```

### Window size

MacSetup opens filling the screen's usable area. `visibleFrame` excludes the
menu bar and the Dock, so "maximised" never means hiding the action bar behind
the Dock. Turn it off with **Window ▸ Open Maximised**, or maximise the current
window with ⌃⌘M.

### When you come back to the Mac

An update that needs a restart is downloaded overnight but never installed while
nobody is watching. It waits for the next unlock, which is a moment you chose to
be present. What happens then is a setting on the Updates pane:

| Option | Behaviour |
| --- | --- |
| **Just notify me** | A notification, nothing more. The default. |
| **Install what it can** | MacSetup installs the updates it staged, showing macOS's authorisation dialog once. |
| **Install, and open Software Update for macOS** | As above, and if a macOS release is waiting, System Settings is opened at Software Update. |

That third option exists because of a hard limit, not a preference. **MacSetup
cannot install a macOS release, and neither can any script.** On Apple Silicon
`softwareupdate` demands a *volume owner's* credentials, and refuses even when
already running as root:

```
Downloaded: macOS Tahoe 26.7
Password: … Failed to authenticate
```

Supplying that would mean handling your password in plaintext through
`--stdinpass`, which MacSetup does not do. So for a macOS release the honest
maximum is to put you in front of Software Update and let **macOS** ask for the
password itself, through its own secure prompt. Those updates are marked
`needs you` in the list, and are never downloaded unattended — otherwise the
schedule would start a multi-gigabyte download every night that could never
finish.

Unlock prompts are throttled to once every six hours for the same set of
updates, so locking and unlocking through the day does not turn into a nag. If
something new arrives, it prompts again straight away.

To inspect or remove the agent by hand:

```bash
launchctl list | grep macsetup
launchctl bootout gui/$(id -u)/local.macsetup.updatecheck
rm ~/Library/LaunchAgents/local.macsetup.updatecheck.plist
```

---

## Validating that it works

`./Scripts/selftest.sh` is the single command that checks everything:

```bash
./Scripts/selftest.sh            # full run, including one real sandboxed install
./Scripts/selftest.sh --offline  # skip anything needing the network
./Scripts/selftest.sh --full     # also cover the .zip install path
```

It exits with the number of failures, so CI can gate on it. It covers:

- **Build** — compiles, and is warning-free.
- **Catalogue** — schema, unique ids, valid categories, every source well-formed,
  regexes that compile, icons and URLs that are https.
- **Script generation** — every entry at once *and* each entry individually must
  produce valid bash (the individual pass catches quoting bugs that neighbouring
  entries would otherwise mask). Runs `shellcheck` when installed.
- **Install machinery** — into a throwaway directory, never `/Applications`:
  a real download, mount, signature check and install; web app bundles with
  valid plists and a launcher pointing at a real browser binary; packages
  correctly deferred to the elevated batch; strict verification correctly
  refusing to fall back.
- **Updates** — every reported update must show `installed -> latest` and name
  its source.
- **Profiles** — v1 and v2 documents both round-trip.
- **Live sources** — all vendor URLs, all GitHub patterns, and icon uniqueness.

**Looking at the interface.** Screen capture needs a permission a headless run
does not have, so the UI is rendered offscreen instead:

```bash
MacSetup.app/Contents/MacOS/MacSetup --render-ui /tmp/ui
```

It writes PNGs of the app cards, web app cards, tweak rows, every install-queue
state, the action bar and the update rows. Two caveats: `ImageRenderer` never
lays out lazy containers, so components are rendered in plain stacks rather than
the real `ScrollView`; and AppKit-backed controls (`TextField`, `Menu`,
`ProgressView`) come out as coloured placeholders. Everything else — icons,
badges, colours, spacing, state styling — is exactly what ships.

**Removing apps.** The **Installed** pane lists every application in
`/Applications` and `~/Applications`, with its version, bundle id and where it
came from — catalogue, Homebrew, or a package. Tick what you want gone and press
Move to Trash. Apps the catalogue does not know about are hidden behind a
checkbox and can be removed too, which is useful for clearing a machine down.

It moves bundles to the
Trash rather than deleting them, removes Homebrew-installed apps through
Homebrew, and leaves preferences, licences and documents alone. Apps installed
from a `.pkg` are reported rather than removed: a package writes files across
the system, and guessing at them is how you break a Mac.

```bash
MacSetup.app/Contents/MacOS/MacSetup --emit-uninstall slack,rectangle
```

Beyond the suite, the honest advice for a fleet: run a real install on a
**throwaway user account or a VM snapshot** before rolling a profile out. The
self-test proves the machinery, but only a real run proves your specific
selection on your specific macOS build.

---

## Maintaining the catalogue

`Sources/MacSetup/Resources/catalog.json` is the whole dataset — 162 apps, 14
categories, 44 web apps, 18 tweaks. It's also copied into the built bundle at
`MacSetup.app/Contents/Resources/catalog.json`, so you can edit a URL in a
deployed copy without rebuilding.

Vendor URLs rot. Check them all against live sources:

```bash
./Scripts/verify-catalog.sh            # everything
./Scripts/verify-catalog.sh direct     # just vendor URLs
./Scripts/verify-catalog.sh github     # just release-asset patterns
./Scripts/verify-catalog.sh teamids    # compare Team IDs against installed apps
```

Adding an app means one JSON object:

```json
{
  "id": "some-app", "name": "Some App", "category": "utilities",
  "vendor": "Someone", "summary": "One line.", "homepage": "https://…",
  "bundleId": "com.someone.SomeApp", "teamId": "ABCDE12345",
  "tags": ["free"], "license": "freeware",
  "source": { "kind": "direct", "format": "dmg", "url": "https://…/App.dmg" },
  "fallback": { "kind": "brew", "cask": "some-app" }
}
```

Use `urlArm64`/`urlX86` instead of `url` when the vendor ships per-architecture
downloads. For GitHub sources, `assetPattern` is a regex matched against the
asset **filename**, not the full URL.

---

## Known limits

- **Web apps are launchers, not real PWAs.** They have no separate storage or
  push notifications — they share the browser's profile. That is deliberate: it
  is what keeps SSO working. Deleting the .app removes it completely.
- **Team IDs are only partly verified.** 11 were confirmed against apps installed
  on the build machine (including Claude and ChatGPT); the rest are unverified, which is why a mismatch warns
  rather than fails by default. `verify-catalog.sh teamids` confirms more as you
  install more.
- **GitHub's API allows 60 unauthenticated calls/hour.** A run with many GitHub
  apps can hit that; those entries fall back to Homebrew.
- **Microsoft Copilot has no catalogue entry** — Homebrew's `copilot` cask is an
  unrelated budgeting app, and there is no unattended installer for the real one.
- **VMware Fusion was dropped** — Broadcom now requires a login, and the
  Homebrew cask no longer exists, so it can't be installed unattended.
- **macOS releases cannot be installed by MacSetup.** Apple Silicon requires a
  volume owner's password, which `softwareupdate` will not accept from root or
  from a script. MacSetup opens Software Update instead. Safari and Command Line
  Tools are unaffected — those it installs itself.
- **The app is ad-hoc signed.** For fleet distribution, re-sign with your
  Developer ID and notarise (see the commented command in `build-app.sh`).
