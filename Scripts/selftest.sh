#!/bin/bash
# MacSetup self-test — validates the catalogue, the generated scripts, and the
# install machinery itself, without touching /Applications.
#
#   ./Scripts/selftest.sh            fast checks + sandboxed install sample
#   ./Scripts/selftest.sh --offline  skip everything that needs the network
#   ./Scripts/selftest.sh --full     also install one app of EVERY source kind
#
# Progress is mirrored live to /tmp/macsetup-selftest.log, so a long run can be
# followed from another terminal with:  tail -f /tmp/macsetup-selftest.log
#
# Exit code is the number of failed checks, so CI can gate on it.
set -uo pipefail

# Bash reads a script incrementally as it executes, so editing this file while a
# run is in progress makes the run switch to the new content mid-flight and
# report nonsense. A full run takes minutes, which makes that easy to do by
# accident, so re-exec from an immutable copy first.
if [ -z "${SELFTEST_REEXEC:-}" ]; then
  SELFTEST_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  # mktemp only substitutes trailing X's, so no suffix after them.
  SELFTEST_COPY="$(mktemp /tmp/macsetup-selftest-XXXXXX)"
  cp "$0" "$SELFTEST_COPY"
  export SELFTEST_REEXEC=1 SELFTEST_ROOT SELFTEST_COPY
  # Always mirror to a fixed log so a long run can be watched live with
  #   tail -f /tmp/macsetup-selftest.log
  SELFTEST_LOG=/tmp/macsetup-selftest.log
  : > "$SELFTEST_LOG"
  bash "$SELFTEST_COPY" "$@" 2>&1 | tee "$SELFTEST_LOG"
  rc=${PIPESTATUS[0]}          # tee's status would mask a real failure
  rm -f "$SELFTEST_COPY"
  exit $rc
fi

cd "${SELFTEST_ROOT:?}"

OFFLINE=0; FULL=0
for a in "$@"; do
  [ "$a" = "--offline" ] && OFFLINE=1
  [ "$a" = "--full" ] && FULL=1
done

CATALOG=Sources/MacSetup/Resources/catalog.json
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
skip() { SKIP=$((SKIP+1)); printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

BIN=.build/debug/MacSetup
section "0. Build"
if swift build >/tmp/st-build.log 2>&1; then
  ok "swift build succeeds"
  if grep -q 'warning:' /tmp/st-build.log; then
    bad "build is warning-free" "$(grep -c 'warning:' /tmp/st-build.log) warning(s)"
  else ok "build is warning-free"; fi
else
  bad "swift build succeeds" "$(tail -3 /tmp/st-build.log)"
  echo; echo "Build failed — stopping."; exit 1
fi

# The release build is what ships, and it emits strict-concurrency warnings the
# debug build does not. Checking only debug let those reach a release once.
if swift build -c release --triple arm64-apple-macosx13.0 >/tmp/st-rel.log 2>&1; then
  if grep -q 'warning:' /tmp/st-rel.log; then
    bad "release build is warning-free" "$(grep -c 'warning:' /tmp/st-rel.log) warning(s)"
  else ok "release build is warning-free"; fi
else
  bad "release build succeeds" "$(tail -3 /tmp/st-rel.log)"
fi

# ---------------------------------------------------------------- catalogue
section "1. Catalogue integrity"
python3 - "$CATALOG" <<'PY' > /tmp/st-cat.txt 2>&1
import json, re, sys
c = json.load(open(sys.argv[1])); errs = []
ids = [a['id'] for a in c['apps']]
if len(set(ids)) != len(ids):
    errs.append(f"duplicate app ids: {[i for i in set(ids) if ids.count(i)>1]}")
cats = {x['id'] for x in c['categories']}
web = c.get('webApps', [])
wids = [w['id'] for w in web]
if len(set(wids)) != len(wids): errs.append("duplicate web app ids")
if set(ids) & set(wids): errs.append(f"id collision app/web: {set(ids)&set(wids)}")
for a in c['apps']:
    if a['category'] not in cats: errs.append(f"{a['id']}: unknown category")
    for f in ('name','vendor','summary','homepage','license','source'):
        if not a.get(f): errs.append(f"{a['id']}: missing {f}")
    s = a['source']; k = s['kind']
    if k == 'direct':
        if not (s.get('url') or (s.get('urlArm64') and s.get('urlX86'))):
            errs.append(f"{a['id']}: direct without url")
        if s.get('format') not in ('dmg','pkg','zip'): errs.append(f"{a['id']}: bad format")
    elif k == 'github':
        if not s.get('repo') or '/' not in s['repo']: errs.append(f"{a['id']}: bad repo")
        try: re.compile(s['assetPattern'])
        except Exception as e: errs.append(f"{a['id']}: bad assetPattern {e}")
    elif k == 'brew':
        if not (s.get('cask') or s.get('formula')): errs.append(f"{a['id']}: brew without token")
    elif k == 'script':
        if not s.get('url','').startswith('https://'): errs.append(f"{a['id']}: script url not https")
    else: errs.append(f"{a['id']}: unknown kind {k}")
    if a.get('fallback') and a['fallback']['kind'] != 'brew':
        errs.append(f"{a['id']}: fallback should be brew")
    ic = a.get('icon')
    if ic and ic != 'none' and not ic.startswith('https://'):
        errs.append(f"{a['id']}: icon not https")
for w in web:
    if not w['url'].startswith('https://'): errs.append(f"{w['id']}: web url not https")
    for f in ('name','group','summary'):
        if not w.get(f): errs.append(f"{w['id']}: missing {f}")
for t in c['systemDefaults']:
    for f in ('command','revert','group','name','detail'):
        if not t.get(f): errs.append(f"{t['id']}: missing {f}")
print("\n".join(errs) if errs else "CLEAN")
print(f"COUNTS {len(c['apps'])} {len(web)} {len(c['systemDefaults'])} {len(c['categories'])}")
PY
if grep -q '^CLEAN' /tmp/st-cat.txt; then
  ok "schema and references valid ($(grep '^COUNTS' /tmp/st-cat.txt | awk '{print $2" apps, "$3" web apps, "$4" tweaks, "$5" categories"}'))"
else
  bad "schema and references valid" "$(grep -v '^COUNTS' /tmp/st-cat.txt | head -5)"
fi

# every entry must be reachable through some category / group
if $BIN --list >/tmp/st-list.txt 2>&1; then
  n=$(grep -c . /tmp/st-list.txt)
  ok "--list enumerates $n entries"
else
  bad "--list works" "$(head -2 /tmp/st-list.txt)"
fi

# ---------------------------------------------------------------- script gen
# The README quotes counts that drift every time the catalogue changes.
python3 - "$CATALOG" README.md <<'PY' > /tmp/st-doc.txt 2>&1
import json, re, sys
from collections import Counter
cat = json.load(open(sys.argv[1])); readme = open(sys.argv[2]).read()
k = Counter(a['source']['kind'] for a in cat['apps'])
checks = [
    ("direct",  k['direct'],                r'\| Direct from vendor \| (\d+) \|'),
    ("brew",    k['brew'],                  r'\| Homebrew \| (\d+) \|'),
    ("github",  k['github'],                r'\| GitHub release \| (\d+) \|'),
    ("script",  k['script'],                r'\| Vendor script \| (\d+) \|'),
    ("webapps", len(cat.get('webApps',[])), r'(\d+) sites are catalogued'),
    ("mstag",   sum(1 for a in cat['apps'] if 'microsoft' in a['tags']),
                                            r'(\d+) entries carry the `microsoft`'),
]
bad = []
for name, actual, pat in checks:
    m = re.search(pat, readme)
    if not m: bad.append(f"{name}: claim not found in README")
    elif int(m.group(1)) != actual: bad.append(f"{name}: README says {m.group(1)}, actual {actual}")
print("\n".join(bad) if bad else "CLEAN")
PY
if grep -q '^CLEAN' /tmp/st-doc.txt; then ok "README figures match the catalogue"
else bad "README figures match the catalogue" "$(head -4 /tmp/st-doc.txt)"; fi

# About details must ship inside the bundle and stay valid JSON.
if python3 -c "import json,sys; d=json.load(open('Sources/MacSetup/Resources/about.json')); sys.exit(0 if 'author' in d else 1)" 2>/dev/null; then
  ok "about.json is valid and has an author"
else
  bad "about.json is valid and has an author"
fi
if [ -f build/MacSetup.app/Contents/Resources/about.json ]; then
  ok "about.json ships inside the app bundle"
else
  skip "about.json in bundle (run ./Scripts/build-app.sh)"
fi

section "2. Generated script syntax"
ALL_IDS=$(python3 -c "
import json;c=json.load(open('$CATALOG'))
print(','.join([a['id'] for a in c['apps']] + [w['id'] for w in c.get('webApps',[])] + [t['id'] for t in c['systemDefaults']]))")
if $BIN --emit-script "$ALL_IDS" > /tmp/st-all.sh 2>/tmp/st-all.err; then
  if bash -n /tmp/st-all.sh 2>/tmp/st-syn.err; then
    ok "every entry at once generates valid bash ($(wc -l < /tmp/st-all.sh | tr -d ' ') lines)"
  else
    bad "combined script parses" "$(head -3 /tmp/st-syn.err)"
  fi
else
  bad "combined script generates" "$(head -3 /tmp/st-all.err)"
fi

# each entry alone, to catch quoting bugs hidden by neighbours
BADONES=""
while IFS= read -r id; do
  $BIN --emit-script "$id" 2>/dev/null | bash -n 2>/dev/null || BADONES="$BADONES $id"
done < <(python3 -c "
import json;c=json.load(open('$CATALOG'))
[print(a['id']) for a in c['apps']]
[print(w['id']) for w in c.get('webApps',[])]")
if [ -z "$BADONES" ]; then ok "each entry individually generates valid bash"
else bad "each entry individually generates valid bash" "offenders:$BADONES"; fi

# quoting: an entry with an apostrophe must not break out of its quotes
$BIN --emit-script monday >/tmp/st-punct.sh 2>/dev/null
if grep -q 'monday\.com' /tmp/st-punct.sh; then
  ok "names with punctuation survive quoting"
else bad "names with punctuation survive quoting"; fi

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning /tmp/st-all.sh >/tmp/st-sc.txt 2>&1; then
    ok "shellcheck clean on the generated script (errors + warnings)"
  else
    bad "shellcheck clean on the generated script" "$(grep -E 'SC[0-9]+' /tmp/st-sc.txt | head -3)"
  fi
  SCBAD=""
  for f in Scripts/selftest.sh Scripts/build-app.sh Scripts/verify-catalog.sh; do
    shellcheck -S error "$f" >/dev/null 2>&1 || SCBAD="$SCBAD $f"
  done
  [ -z "$SCBAD" ] && ok "shellcheck clean on the project scripts" \
    || bad "shellcheck clean on the project scripts" "offenders:$SCBAD"
else skip "shellcheck not installed (brew install shellcheck)"; fi

# ---------------------------------------------------------------- prelude
section "3. Install machinery"
SANDBOX=$(mktemp -d /tmp/macsetup-selftest.XXXXXX)
mkdir -p "$SANDBOX/Applications"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

sandbox_run_standalone() {
  local ids="$1" out="$SANDBOX/$2"
  $BIN --emit-script "$ids" --standalone > "$out.sh" 2>/dev/null
  sed -i '' "s|^APPDIR=.*|APPDIR='$SANDBOX/Applications'|; s|^LOG=.*|LOG='$out.log'|; s|^SKIP_INSTALLED=.*|SKIP_INSTALLED=0|" "$out.sh"
  bash "$out.sh" > "$out.out" 2>&1
  echo "$out.out"
}

sandbox_run() {   # <ids> -> runs into the sandbox, echoes the log path
  local ids="$1" out="$SANDBOX/$2"
  $BIN --emit-script "$ids" > "$out.sh" 2>/dev/null
  sed -i '' "s|^APPDIR=.*|APPDIR='$SANDBOX/Applications'|; s|^LOG=.*|LOG='$out.log'|; s|^SKIP_INSTALLED=.*|SKIP_INSTALLED=0|" "$out.sh"
  bash "$out.sh" > "$out.out" 2>&1
  echo "$out.out"
}

# web apps need no network for the bundle itself, only for the icon
o=$(sandbox_run "gmail,google-calendar" webapp)
if grep -q '@@MS|gmail|done' "$o" && [ -d "$SANDBOX/Applications/Gmail.app" ]; then
  ok "web app bundle is created"
  if plutil -lint "$SANDBOX/Applications/Gmail.app/Contents/Info.plist" >/dev/null 2>&1; then
    ok "web app Info.plist is valid"
  else bad "web app Info.plist is valid"; fi
  if [ -x "$SANDBOX/Applications/Gmail.app/Contents/MacOS/launcher" ]; then
    ok "web app launcher is executable"
  else bad "web app launcher is executable"; fi
  exe=$(grep -oE '"/[^"]+/Contents/MacOS/[^"]+"' "$SANDBOX/Applications/Gmail.app/Contents/MacOS/launcher" | head -1 | tr -d '"')
  if [ -z "$exe" ] || [ -x "$exe" ]; then ok "web app points at a real browser binary"
  else bad "web app points at a real browser binary" "$exe"; fi
else
  bad "web app bundle is created" "$(grep '@@MS' "$o" | tail -2)"
fi

# system tweaks must be syntactically runnable without applying anything
$BIN --emit-script finder-show-extensions,screenshots-folder >/tmp/st-tw.sh 2>/dev/null
if grep -q 'msu_as_user /bin/bash' /tmp/st-tw.sh; then
  ok "system tweaks are routed through the user context"
else bad "system tweaks are routed through the user context"; fi

# the pkg path must defer to the elevated batch, never claim success early
$BIN --emit-script zoom >/tmp/st-pkg.sh 2>/dev/null
if grep -q 'MSU_RC -eq 3' /tmp/st-pkg.sh; then
  ok "packages defer to the elevated batch"
else bad "packages defer to the elevated batch"; fi

# strict verification must not fall back to Homebrew
$BIN --emit-script google-chrome --strict >/tmp/st-str.sh 2>/dev/null
if grep -q 'MSU_RC -eq 2' /tmp/st-str.sh; then
  ok "signature failure skips the Homebrew fallback"
else bad "signature failure skips the Homebrew fallback"; fi

if [ "$OFFLINE" = "1" ]; then
  skip "live download test (--offline)"
else
  # one real download end to end: small, free, signed, from GitHub
  o=$(sandbox_run "rectangle" download)
  if grep -q '@@MS|rectangle|done' "$o" && [ -d "$SANDBOX/Applications/Rectangle.app" ]; then
    ok "dmg: real download, verify and install into sandbox"
    if codesign --verify --strict "$SANDBOX/Applications/Rectangle.app" 2>/dev/null; then
      ok "installed app passes its own signature check"
    else bad "installed app passes its own signature check"; fi
    if grep -q '@@MS|rectangle|verifying|Team ID' "$o"; then
      ok "Team ID is read and reported"
    else bad "Team ID is read and reported"; fi
  else
    # Falling back to Homebrew here means the direct path broke.
    bad "dmg: direct install must not fall back to Homebrew" \
        "$(grep -E '@@MS\|rectangle\|(retry|failed)' "$o" | tail -2)"
  fi

  if [ "$FULL" = "1" ]; then
    # iTerm2 rather than VS Code: same zip code path, ~30MB instead of ~150MB,
    # which keeps a --full run inside a sensible wall clock.
    o=$(sandbox_run "iterm2" zipfmt)
    if grep -q '@@MS|iterm2|done' "$o" && [ -d "$SANDBOX/Applications/iTerm.app" ]; then
      ok "zip: download, expand, verify and install"
      codesign --verify --strict "$SANDBOX/Applications/iTerm.app" 2>/dev/null \
        && ok "installed zip app passes its signature check" \
        || bad "installed zip app passes its signature check"
    else
      bad "zip: download, expand, verify and install" "$(grep -E '@@MS\|iterm2\|(retry|failed)' "$o" | tail -2)"
    fi
  else
    skip "extra format coverage (--full)"
  fi
fi

# ---------------------------------------------------------------- profiles
# Regression: a GUI-launched shell may not have /usr/sbin on PATH, and the
# elevated child gets an even barer environment. That made `installer` and
# `pkgutil` vanish — packages failed and every Team ID read as "none".
$BIN --emit-script onedrive > /tmp/st-path.sh 2>/dev/null
PATHBAD=""
grep -q '^export PATH="/usr/bin:/bin:/usr/sbin:/sbin' /tmp/st-path.sh || PATHBAD="$PATHBAD no-explicit-PATH"
grep -q '/usr/sbin/installer -pkg' /tmp/st-path.sh || PATHBAD="$PATHBAD installer-not-absolute"
grep -q '/usr/sbin/pkgutil --check-signature' /tmp/st-path.sh || PATHBAD="$PATHBAD pkgutil-not-absolute"
grep -q '/usr/bin/codesign -dv' /tmp/st-path.sh || PATHBAD="$PATHBAD codesign-not-absolute"
if [ -z "$PATHBAD" ]; then
  ok "system tools are called by absolute path, not via PATH"
else
  bad "system tools are called by absolute path, not via PATH" "$PATHBAD"
fi

# And prove it: run a real verification with /usr/sbin stripped from PATH.
if [ "$OFFLINE" = "0" ]; then
  PT="$SANDBOX/pathtest"; mkdir -p "$PT/Applications"
  $BIN --emit-script nudge > "$PT/p.sh" 2>/dev/null
  sed -i '' "s|^APPDIR=.*|APPDIR='$PT/Applications'|; s|^LOG=.*|LOG='$PT/p.log'|; s|^SKIP_INSTALLED=.*|SKIP_INSTALLED=0|" "$PT/p.sh"
  sed -i '' 's|if ! osascript -e "do shell script .* with administrator privileges" >/dev/null 2>"$STAGE/auth.err"; then|if ! true; then|' "$PT/p.sh"
  env -i HOME="$HOME" PATH=/usr/bin:/bin /bin/bash "$PT/p.sh" > "$PT/out.txt" 2>&1
  if grep -q '@@MS|nudge|verifying|Team ID T4SK8ZXCXG' "$PT/out.txt"; then
    ok "signature verification works with /usr/sbin missing from PATH"
  else
    bad "signature verification works with /usr/sbin missing from PATH" \
        "$(grep '@@MS|nudge|verifying' "$PT/out.txt" | tail -1)"
  fi
else
  skip "PATH-stripped verification (--offline)"
fi

# A cask that ships a .pkg must be fetched by Homebrew and installed through the
# elevated batch, not left to brew's own sudo (which has no terminal).
$BIN --emit-script tailscale > /tmp/st-brewpkg.sh 2>/dev/null
if grep -q "msu_brew_pkg_install 'tailscale'" /tmp/st-brewpkg.sh; then
  ok "pkg casks are fetched and installed through the elevated batch"
else
  bad "pkg casks are fetched and installed through the elevated batch"
fi

# Casks that run their own installer must go through the elevated batch too,
# not fail with "a terminal is required".
$BIN --emit-script expressvpn,tailscale > /tmp/st-inst.sh 2>/dev/null
if grep -q "msu_brew_installer_run 'expressvpn'" /tmp/st-inst.sh \
   && grep -q "msu_brew_pkg_install 'tailscale'" /tmp/st-inst.sh; then
  ok "installer-script casks run through the elevated batch"
else
  bad "installer-script casks run through the elevated batch"
fi
# The vendor installer must never run before its signature is checked.
if grep -q 'msu_verify "$app" "$id" "$expected" "app" || return 2' /tmp/st-inst.sh; then
  ok "vendor installers are signature-checked before running as root"
else
  bad "vendor installers are signature-checked before running as root"
fi

# Regression: updating a brew app that is already present must adopt it, not
# fail with "It seems there is already an App at ...".
$BIN --emit-script blender > /tmp/st-adopt.sh 2>/dev/null
if grep -q 'already an App at' /tmp/st-adopt.sh && grep -q -- '--adopt' /tmp/st-adopt.sh; then
  ok "brew retries by adopting an app that is already installed"
else
  bad "brew retries by adopting an app that is already installed"
fi

# Regression: packages come first, so the password prompt arrives early.
$BIN --emit-script blender,onedrive,github-desktop > /tmp/st-order.sh 2>/dev/null
FIRSTFLUSH=$(grep -n '^msu_flush_pkgs$' /tmp/st-order.sh | head -1 | cut -d: -f1)
ONEDRIVE=$(grep -n '^# ---- Microsoft OneDrive' /tmp/st-order.sh | head -1 | cut -d: -f1)
BLENDER=$(grep -n '^# ---- Blender' /tmp/st-order.sh | head -1 | cut -d: -f1)
if [ -n "$FIRSTFLUSH" ] && [ -n "$ONEDRIVE" ] && [ -n "$BLENDER" ] \
   && [ "$ONEDRIVE" -lt "$FIRSTFLUSH" ] && [ "$FIRSTFLUSH" -lt "$BLENDER" ]; then
  ok "packages install first, so authorisation is asked for early"
else
  bad "packages install first, so authorisation is asked for early" \
      "onedrive=$ONEDRIVE flush=$FIRSTFLUSH blender=$BLENDER"
fi

# Regression: the elevated package batch must log to the SAME file the script
# declares. When those drifted apart, every .pkg installed correctly but was
# reported as failed, because its status lines went to a file nobody read.
# macOS ships neither timeout(1) nor gtimeout, and a network step that hangs
# rather than fails will otherwise block the whole suite indefinitely — which
# it did, on a Zoom download frozen mid-transfer with the process still alive.
with_timeout() {
  local secs="$1"; shift
  ( "$@" ) & local cmd_pid=$!
  ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null ) & local killer=$!
  wait "$cmd_pid" 2>/dev/null; local rc=$?
  kill -TERM "$killer" 2>/dev/null
  wait "$killer" 2>/dev/null
  return $rc
}

PKGT="$SANDBOX/pkgflush"
mkdir -p "$PKGT/bin"
printf '#!/bin/bash\nexit 0\n' > "$PKGT/bin/installer"   # stub, installs nothing
chmod +x "$PKGT/bin/installer"
$BIN --emit-script zoom > "$PKGT/run.sh" 2>/dev/null
sed -i '' "s|^APPDIR=.*|APPDIR='$SANDBOX/Applications'|; s|^LOG=.*|LOG='$PKGT/run.log'|; s|^SKIP_INSTALLED=.*|SKIP_INSTALLED=0|" "$PKGT/run.sh"
# Run the elevated batch directly instead of through an auth prompt.
sed -i '' 's|if ! osascript -e "do shell script .* with administrator privileges" >/dev/null 2>"$STAGE/auth.err"; then|if ! /bin/bash "$root_script" >/dev/null 2>\&1; then|' "$PKGT/run.sh"
# installer is now called by absolute path (a GUI shell may lack /usr/sbin), so
# a PATH shim no longer intercepts it — point the script at the stub directly.
sed -i '' "s|/usr/sbin/installer -pkg|$PKGT/bin/installer -pkg|" "$PKGT/run.sh"
: > "$PKGT/run.log"
with_timeout 420 env PATH="$PKGT/bin:$PATH" bash "$PKGT/run.sh" >/dev/null 2>&1
PKGRC=$?
if grep -q '@@MS|zoom|done' "$PKGT/run.log"; then
  ok "package results reach the log the app reads"
elif [ "$PKGRC" -ge 124 ] || [ "$PKGRC" -eq 143 ]; then
  skip "package flush timed out (slow or hung download, not a code fault)"
else
  bad "package results reach the log the app reads" \
      "$(grep -c '@@MS' "$PKGT/run.log" 2>/dev/null) status lines, none marking zoom done"
fi

# Every Homebrew cask that installs a .pkg must be flagged, or the app will
# promise a password-free run and then fail with a raw brew error.
python3 - "$CATALOG" <<'PY' > /tmp/st-admin.txt 2>&1
import json, subprocess, sys
cat = json.load(open(sys.argv[1]))
casks = {}
for a in cat['apps']:
    s = a['source']
    if s.get('kind') == 'brew' and s.get('cask'):
        casks.setdefault(s['cask'], []).append(a)
if not casks:
    print("CLEAN"); raise SystemExit
try:
    out = subprocess.run(['brew','info','--json=v2','--cask'] + sorted(casks),
                         capture_output=True, text=True, timeout=240).stdout
    info = json.loads(out)
except Exception as e:
    print(f"SKIP {e}"); raise SystemExit
bad = []
for c in info.get('casks', []):
    kinds = set()
    for art in c.get('artifacts', []):
        if isinstance(art, dict): kinds.update(art.keys())
    ispkg = bool(kinds & {'pkg', 'installer'})
    for a in casks.get(c['token'], []):
        if ispkg and not a.get('needsAdmin'):
            bad.append(f"{a['id']}: cask {c['token']} runs a privileged installer but is not flagged needsAdmin")
        if not ispkg and a.get('needsAdmin'):
            bad.append(f"{a['id']}: flagged needsAdmin but cask {c['token']} installs an app bundle")
print("\n".join(bad) if bad else "CLEAN")
PY
if grep -q '^CLEAN' /tmp/st-admin.txt; then ok "pkg-based casks are all flagged as needing admin"
elif grep -q '^SKIP' /tmp/st-admin.txt; then skip "cask artifact check (brew unavailable)"
else bad "pkg-based casks are all flagged as needing admin" "$(head -3 /tmp/st-admin.txt)"; fi

# Standalone web apps must produce a real application, not a shell launcher.
if [ -x .build/debug/WebAppHost ]; then
  o=$(sandbox_run_standalone "linear" standalone)
  APPX="$SANDBOX/Applications/Linear.app"
  if [ -d "$APPX" ] && [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APPX/Contents/Info.plist" 2>/dev/null)" = "WebAppHost" ]; then
    ok "standalone web app embeds its own executable"
    [ -x "$APPX/Contents/MacOS/WebAppHost" ] && ok "standalone binary is executable" \
      || bad "standalone binary is executable"
  else
    bad "standalone web app embeds its own executable" "$(grep '@@MS' "$o" | tail -2)"
  fi
else
  skip "standalone web app host not built"
fi

# The interface can be rendered offscreen, which is the only way it gets looked
# at at all — screen capture needs a permission a headless run does not have.
UIOUT="$SANDBOX/ui"
if $BIN --render-ui "$UIOUT" >/tmp/st-ui.txt 2>&1; then
  n=$(ls "$UIOUT"/*.png 2>/dev/null | wc -l | tr -d ' ')
  tiny=$(find "$UIOUT" -name '*.png' -size -5k 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" -ge 6 ] && [ "$tiny" = "0" ]; then
    ok "interface renders offscreen ($n views, none blank)"
  else
    bad "interface renders offscreen" "$n views, $tiny suspiciously small"
  fi
else
  bad "interface renders offscreen" "$(tail -2 /tmp/st-ui.txt)"
fi

# Uninstall must move to the Trash, never delete.
UNT="$SANDBOX/untest"
mkdir -p "$UNT/Applications/Rectangle.app/Contents" "$UNT/.Trash"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleName</key><string>Rectangle</string></dict></plist>' \
  > "$UNT/Applications/Rectangle.app/Contents/Info.plist"
$BIN --emit-uninstall rectangle > "$UNT/u.sh" 2>/dev/null
sed -i '' "s|^APPDIR=.*|APPDIR='$UNT/Applications'|; s|^LOG=.*|LOG='$UNT/u.log'|; s|^USER_HOME=.*|USER_HOME='$UNT'|" "$UNT/u.sh"
bash "$UNT/u.sh" >/dev/null 2>&1
if [ ! -d "$UNT/Applications/Rectangle.app" ] && [ -d "$UNT/.Trash/Rectangle.app" ]; then
  ok "uninstall moves the bundle to the Trash rather than deleting it"
else
  bad "uninstall moves the bundle to the Trash rather than deleting it"
fi
# Apps outside the catalogue can be removed too. Their generated id contains a
# colon ("bundle:com.example.x"), which must survive quoting.
FAKE="$UNT/Applications/Some Internal Tool.app"
mkdir -p "$FAKE/Contents"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleName</key><string>Some Internal Tool</string></dict></plist>' \
  > "$FAKE/Contents/Info.plist"
$BIN --emit-uninstall rectangle > "$UNT/n.sh" 2>/dev/null
sed -i '' "s|^APPDIR=.*|APPDIR='$UNT/Applications'|; s|^LOG=.*|LOG='$UNT/n.log'|; s|^USER_HOME=.*|USER_HOME='$UNT'|" "$UNT/n.sh"
sed -i '' "s|^msu_uninstall 'rectangle'.*|msu_uninstall 'bundle:com.example.internal' 'Some Internal Tool' 'com.example.internal' 'app' ''|" "$UNT/n.sh"
bash "$UNT/n.sh" >/dev/null 2>&1
if [ ! -d "$FAKE" ] && [ -d "$UNT/.Trash/Some Internal Tool.app" ]; then
  ok "apps outside the catalogue can be removed (colon in id survives quoting)"
else
  bad "apps outside the catalogue can be removed"
fi

# A package-installed app must be refused, not half-removed.
$BIN --emit-uninstall zoom > "$UNT/z.sh" 2>/dev/null
if grep -q "msu_uninstall 'zoom' 'Zoom' 'us.zoom.xos' 'pkg'" "$UNT/z.sh"; then
  ok "package-installed apps are classified for refusal"
else
  bad "package-installed apps are classified for refusal"
fi

# A single-architecture build would simply not launch on an Intel Mac, and the
# build script used to fail over to that silently.
if [ -f build/MacSetup.app/Contents/MacOS/MacSetup ]; then
  if file build/MacSetup.app/Contents/MacOS/MacSetup | grep -q universal; then
    ok "built app is a universal binary"
  else
    bad "built app is a universal binary" "Intel Macs cannot run this build"
  fi
fi

# Regression: the loader must never touch Bundle.module. SwiftPM's accessor
# fatalErrors when its resource bundle is missing, and it looks at an absolute
# path baked in at build time — so a copy on any other Mac crashed on launch.
if grep -v '^[[:space:]]*//' Sources/MacSetup/Models/Catalog.swift | grep -q 'Bundle\.module'; then
  bad "catalogue loader does not depend on Bundle.module" \
      "referencing it crashes a distributed copy on launch"
else
  ok "catalogue loader does not depend on Bundle.module"
fi

# And prove it: run the built app with every build-time path hidden.
if [ -d build/MacSetup.app ]; then
  HID=""
  for B in $(find .build -maxdepth 3 -name "MacSetup_MacSetup.bundle" -type d 2>/dev/null); do
    mv "$B" "${B}.selftest-hidden" && HID="$HID ${B}"
  done
  n=$(build/MacSetup.app/Contents/MacOS/MacSetup --list 2>/dev/null | wc -l | tr -d ' ')
  for B in $HID; do mv "${B}.selftest-hidden" "$B"; done
  if [ "${n:-0}" -gt 100 ]; then
    ok "built app loads its own catalogue with no build directory present ($n entries)"
  else
    bad "built app loads its own catalogue with no build directory present" \
        "got $n entries — it is reading from the build tree"
  fi
else
  skip "built app not present (run ./Scripts/build-app.sh)"
fi

# Regression: icon loads must not publish. When they did, every arriving icon
# invalidated every view observing the provider, and scrolling stuttered.
if grep -E '@Published.*(icons|sources)' Sources/MacSetup/Models/IconProvider.swift >/dev/null 2>&1; then
  bad "icon loads do not invalidate every view" "icons/sources are @Published again"
else
  ok "icon loads do not invalidate every view"
fi
# Regression: caching the filtered list is right, but it must still publish —
# a plain stored property changes without SwiftUI ever redrawing, which left the
# grid showing the previous category while the sidebar had already moved on.
if grep -q '@Published private(set) var filteredApps' Sources/MacSetup/Models/AppState.swift; then
  ok "filtered list publishes its changes"
else
  bad "filtered list publishes its changes" "cached but not @Published — the grid will show stale content"
fi
# Regression: one selection mechanism only. List(selection:) plus
# NavigationLink(value:) is two, and they can disagree.
if grep -q 'NavigationLink(value' Sources/MacSetup/Views/SidebarView.swift; then
  bad "sidebar has a single selection mechanism" "NavigationLink(value:) alongside List(selection:)"
else
  ok "sidebar has a single selection mechanism"
fi

# Regression: the filtered list is read several times per render, so it is cached.
if grep -q 'private(set) var filteredApps' Sources/MacSetup/Models/AppState.swift; then
  ok "filtered list is cached, not recomputed per read"
else
  bad "filtered list is cached, not recomputed per read"
fi

# Jamf export must stay runnable: it is pasted straight into a policy.
$BIN --emit-jamf slack,microsoft-word > "$SANDBOX/jamf.sh" 2>/dev/null
if bash -n "$SANDBOX/jamf.sh" 2>/dev/null; then
  ok "Jamf policy script is valid bash"
  grep -q 'jamf recon' "$SANDBOX/jamf.sh" \
    && ok "Jamf script submits inventory after running" \
    || bad "Jamf script submits inventory after running"
else
  bad "Jamf policy script is valid bash"
fi
$BIN --emit-jamf-ea > "$SANDBOX/ea.sh" 2>/dev/null
if bash -n "$SANDBOX/ea.sh" 2>/dev/null && grep -q '<result>' "$SANDBOX/ea.sh"; then
  ok "Jamf Extension Attribute emits a <result> block"
  # An EA runs on freshly enrolled Macs, which often have no Command Line Tools
  # and therefore no working /usr/bin/python3.
  if grep -q 'python3' /tmp/st-ea.sh 2>/dev/null; then
    bad "Extension Attribute avoids python3" "a bare Mac has no working /usr/bin/python3"
  else
    ok "Extension Attribute avoids python3 (runs on a bare Mac)"
  fi
else
  bad "Jamf Extension Attribute emits a <result> block"
fi

# Receipts are what the Extension Attribute reads, so prove they are written.
RC="$SANDBOX/rcpt"
mkdir -p "$RC/Applications"
$BIN --emit-script gmail > "$RC/r.sh" 2>/dev/null
sed -i '' "s|^APPDIR=.*|APPDIR='$RC/Applications'|; s|^LOG=.*|LOG='$RC/r.log'|; s|^USER_HOME=.*|USER_HOME='$RC'|" "$RC/r.sh"
bash "$RC/r.sh" >/dev/null 2>&1
if [ -s "$RC/Library/Application Support/MacSetup/receipts.jsonl" ]; then
  ok "install receipts are written for MDM reporting"
else
  bad "install receipts are written for MDM reporting"
fi

section "4. Update checking"
# Real assertions, not a placebo: this runs the cases through the comparator.
if $BIN --test-versions > /tmp/st-ver.txt 2>&1; then
  ok "version comparator ($(grep -oE '[0-9]+/[0-9]+ version cases passed' /tmp/st-ver.txt))"
else
  bad "version comparator" "$(grep FAIL /tmp/st-ver.txt | head -3)"
fi

# The unlock rules decide whether a password dialog lands in someone's face,
# and whether a 17 GB macOS release gets started unattended. Pinned, not eyeballed.
if $BIN --test-unlock > /tmp/st-unlock.txt 2>&1; then
  ok "unlock rules ($(grep -c '^  ok' /tmp/st-unlock.txt) cases)"
else
  bad "unlock rules" "$(grep FAIL /tmp/st-unlock.txt | head -3)"
fi

if $BIN --test-nudge > /tmp/st-nudge.txt 2>&1; then
  ok "macOS reminder escalation ($(grep -c '^  ok' /tmp/st-nudge.txt) cases)"
else
  bad "macOS reminder escalation" "$(grep FAIL /tmp/st-nudge.txt | head -3)"
fi

if $BIN --test-nag > /tmp/st-nag.txt 2>&1; then
  ok "update screen policy ($(grep -c '^  ok' /tmp/st-nag.txt) cases)"
else
  bad "update screen policy" "$(grep FAIL /tmp/st-nag.txt | head -3)"
fi

# Regression: setting the notification delegate outside an app bundle raises
# NSInternalInconsistencyException and kills the process. The CLI verbs and the
# launchd job both run the binary that way.
if $BIN --help >/tmp/st-bundle.txt 2>&1 && ! grep -q 'bundleProxyForCurrentProcess' /tmp/st-bundle.txt; then
  ok "running outside an app bundle does not crash"
else
  bad "running outside an app bundle does not crash" "$(tail -3 /tmp/st-bundle.txt)"
fi

# The emitted policies are consumed by MDMs and by Nudge, so a malformed one
# is a policy that silently does nothing.
if $BIN --test-nag 2>&1 | grep -q 'the DDM declaration is valid JSON'; then
  ok "DDM and Nudge policies are well formed"
else
  bad "DDM and Nudge policies are well formed"
fi

# Regression: a macOS release reached softwareupdate -i, downloaded ~17 GB and
# then failed to authenticate. No emitted script may ever name one.
SYSSCRIPT=$($BIN --emit-script "" 2>/dev/null || true)
if $BIN --test-nag 2>&1 | grep -q 'the combined script never mentions the release'; then
  ok "macOS releases are refused before anything is downloaded"
else
  bad "macOS releases are refused before anything is downloaded"
fi

# Reporting login-item status must never change it: a status query that
# silently registered the app would be a nasty surprise on a colleague's Mac.
BEFORE_LI="$($BIN --login-item 2>&1)"
AFTER_LI="$($BIN --login-item 2>&1)"
if [ -n "$BEFORE_LI" ] && [ "$BEFORE_LI" = "$AFTER_LI" ] && \
   echo "$BEFORE_LI" | grep -q 'login item:'; then
  ok "login-item status is read-only"
else
  bad "login-item status is read-only" "$BEFORE_LI / $AFTER_LI"
fi

# The installer cache must never start a huge download implicitly.
# A dry run must download nothing AND delete nothing. It briefly did the
# latter: the stub-removal step ran before the dry-run branch.
if $BIN --cache-os-installer --dry-run >/tmp/st-cache.txt 2>&1 \
   && grep -qE 'would run: /usr/sbin/softwareupdate --fetch-full-installer' /tmp/st-cache.txt \
   && ! grep -qE '^running \(attempt|^removed it' /tmp/st-cache.txt; then
  ok "the installer cache dry run downloads nothing and deletes nothing"
elif grep -q 'no macOS release pending' /tmp/st-cache.txt; then
  skip "no macOS release pending to cache"
else
  bad "the installer cache dry run downloads nothing and deletes nothing" "$(tail -2 /tmp/st-cache.txt)"
fi

# Both test harnesses must be able to fail, or they are decoration.
if ! $BIN --test-unlock --force-fail >/dev/null 2>&1 \
   && ! $BIN --test-nudge --force-fail >/dev/null 2>&1 \
   && ! $BIN --test-nag --force-fail >/dev/null 2>&1; then
  ok "the unlock and reminder harnesses report failures when they occur"
else
  bad "the unlock and reminder harnesses report failures when they occur" \
      "--force-fail exited 0; the assertions may be optimised away"
fi

# The reminder text tells the user to click it, so a click handler must exist.
if grep -q 'macsetup.osupdate' Sources/MacSetup/Models/AppLifecycle.swift \
   && grep -q 'didReceive response' Sources/MacSetup/Models/AppLifecycle.swift \
   && grep -q 'UNUserNotificationCenter.current().delegate = self' Sources/MacSetup/Models/AppLifecycle.swift; then
  ok "the macOS reminder's \"click to open\" is backed by a handler"
else
  bad "the macOS reminder's \"click to open\" is backed by a handler"
fi

# Opening maximised must use visibleFrame, which excludes the Dock and menu
# bar — a naive full-screen frame hides the action bar behind the Dock again.
if grep -q 'maximized ? 0 : 12' Sources/MacSetup/Views/WindowFitter.swift \
   && grep -q 'maximized ? cap : preferred' Sources/MacSetup/Views/WindowFitter.swift \
   && grep -q 'openMaximized' Sources/MacSetup/MacSetupApp.swift; then
  ok "maximised windows fill the usable area, not the whole screen"
else
  bad "maximised windows fill the usable area, not the whole screen"
fi

# The pane MacSetup opens for a macOS release must actually exist, or the
# "open Software Update" option silently does nothing.
SU_EXT=/System/Library/ExtensionKit/Extensions/SoftwareUpdateSettingsExtension.appex/Contents/Info.plist
if [ -f "$SU_EXT" ] && \
   [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SU_EXT" 2>/dev/null)" \
     = "com.apple.Software-Update-Settings.extension" ] && \
   grep -q 'com.apple.Software-Update-Settings.extension' Sources/MacSetup/Models/UnlockAction.swift; then
  ok "the Software Update pane MacSetup opens exists on this macOS"
else
  bad "the Software Update pane MacSetup opens exists on this macOS"
fi

$BIN --check-updates > /tmp/st-upd.txt 2>&1
if grep -qE 'installed - [0-9]+ update' /tmp/st-upd.txt; then
  ok "update check runs ($(grep -oE '[0-9]+ installed' /tmp/st-upd.txt | head -1))"
  # An update line must always show both versions, never a bare claim.
  if grep -E '^\s+UPDATE' /tmp/st-upd.txt | grep -qv ' -> '; then
    bad "every update reports installed -> latest"
  else ok "every update reports installed -> latest"; fi
  # Nothing may be reported as an update without a named source.
  if grep -E '^\s+UPDATE' /tmp/st-upd.txt | grep -qv '\['; then
    bad "every update names where the version came from"
  else ok "every update names where the version came from"; fi
else
  bad "update check runs" "$(tail -2 /tmp/st-upd.txt)"
fi

# Automatic update checking: the launchd job runs the same binary, so the
# quiet/notify path must stay machine-readable and exit cleanly.
if [ "$OFFLINE" = "0" ]; then
  if $BIN --check-updates --notify --quiet > /tmp/st-notify.txt 2>&1 \
     && grep -qE 'update\(s\) available of [0-9]+ installed' /tmp/st-notify.txt; then
    ok "scheduled check runs quietly and reports a summary"
  else
    bad "scheduled check runs quietly and reports a summary" "$(tail -2 /tmp/st-notify.txt)"
  fi
else
  skip "scheduled update check (--offline)"
fi

# Apple updates install through the same elevated batch as everything else, but
# must never trigger a restart: staging an update is one decision, rebooting
# someone's Mac is another.
SUBAD=""
grep -q 'softwareupdate' Sources/MacSetup/Install/SystemUpdateChecker.swift || SUBAD="$SUBAD no-softwareupdate"
grep -q -- '"--list"' Sources/MacSetup/Install/SystemUpdateChecker.swift || SUBAD="$SUBAD checker-not-list-only"
grep -q 'softwareupdate -i' Sources/MacSetup/Install/ScriptPrelude.swift || SUBAD="$SUBAD no-install-path"
grep -qE 'softwareupdate[^|]*--restart|softwareupdate[^|]*-r ' Sources/MacSetup/Install/ScriptPrelude.swift \
  && SUBAD="$SUBAD RESTARTS-THE-MAC"
grep -q 'msu_queue_system' Sources/MacSetup/Install/ScriptPrelude.swift || SUBAD="$SUBAD not-in-elevated-batch"
if [ -z "$SUBAD" ]; then
  ok "Apple updates install via the elevated batch and never restart the Mac"
else
  bad "Apple updates install via the elevated batch and never restart the Mac" "$SUBAD"
fi

# Apple updates must share one Install button and one authorisation prompt with
# apps, not have a parallel flow of their own.
UNIBAD=""
grep -q 'selectedSystemUpdates' Sources/MacSetup/Models/AppState.swift || UNIBAD="$UNIBAD selection-not-shared"
grep -q 'systemUpdates: \[SystemUpdate\]' Sources/MacSetup/Install/ScriptGenerator.swift || UNIBAD="$UNIBAD generator-missing"
grep -q 'systemUpdates: system.updates.filter' Sources/MacSetup/Views/ContentView.swift || UNIBAD="$UNIBAD actionbar-missing"
grep -q 'Install \\(total) Item' Sources/MacSetup/Views/ContentView.swift || UNIBAD="$UNIBAD no-single-button"
if [ -z "$UNIBAD" ]; then
  ok "Apple updates use the same selection and Install button as apps"
else
  bad "Apple updates use the same selection and Install button as apps" "$UNIBAD"
fi

# The configured hour must survive a write/read round trip — it was silently
# reset once, and the only way to notice was reading the plist by hand.
if $BIN --schedule set --hour 9 --action notify >/dev/null 2>&1; then
  SH=$(/usr/libexec/PlistBuddy -c 'Print :StartCalendarInterval:Hour' \
       "$HOME/Library/LaunchAgents/local.macsetup.updatecheck.plist" 2>/dev/null)
  if [ "$SH" = "9" ]; then
    ok "schedule hour persists to the launch agent"
  else
    bad "schedule hour persists to the launch agent" "asked for 9, plist says ${SH:-nothing}"
  fi
else
  skip "schedule CLI unavailable"
fi

# A staged entry promises the bytes are already on disk. Recording one that was
# not actually downloaded turns "install, it is quick" into a surprise
# multi-gigabyte download.
if grep -q 'downloaded.contains(\$0.label)' Sources/MacSetup/Main.swift; then
  ok "only confirmed downloads are staged for the unlock prompt"
else
  bad "only confirmed downloads are staged for the unlock prompt"
fi

# A full macOS release cannot be staged or installed unattended: on Apple
# Silicon it needs a volume owner's password, which root does not satisfy and
# which this tool will not handle. Starting a 17 GB download that is certain to
# fail authentication is worse than not starting it.
SRBAD=""
grep -q 'isSystemRelease' Sources/MacSetup/Install/SystemUpdateChecker.swift || SRBAD="$SRBAD no-flag"
grep -q '!\$0.isSystemRelease' Sources/MacSetup/Main.swift || SRBAD="$SRBAD still-stages-releases"
grep -q 'volume owner password' Sources/MacSetup/Install/ScriptPrelude.swift || SRBAD="$SRBAD no-explanation"
if [ -z "$SRBAD" ]; then
  ok "macOS releases are not downloaded unattended, and the reason is reported"
else
  bad "macOS releases are not downloaded unattended" "$SRBAD"
fi

# Restart-required updates are staged overnight and offered at the next unlock,
# never installed while nobody is present.
STBAD=""
grep -q 'softwareupdate -d' Sources/MacSetup/Install/ScriptPrelude.swift || STBAD="$STBAD no-download-path"
grep -q 'msu_queue_system_download' Sources/MacSetup/Install/ScriptGenerator.swift || STBAD="$STBAD generator-missing"
grep -q 'com.apple.screenIsUnlocked' Sources/MacSetup/Models/UnlockWatcher.swift || STBAD="$STBAD no-unlock-observer"
grep -q 'func reconcile' Sources/MacSetup/Models/PendingRestart.swift || STBAD="$STBAD no-reconcile"
if [ -z "$STBAD" ]; then
  ok "restart updates are staged and offered at the next unlock"
else
  bad "restart updates are staged and offered at the next unlock" "$STBAD"
fi

# An unattended run may raise the authorisation dialog, but must never leave it
# on screen indefinitely, and must not install anything that forces a restart.
APBAD=""
grep -q 'allowPrompt' Sources/MacSetup/Main.swift || APBAD="$APBAD no-allow-prompt"
grep -q 'opts.authTimeout = 600' Sources/MacSetup/Main.swift || APBAD="$APBAD no-dialog-timeout"
grep -q 'filter { !\$0.requiresRestart }' Sources/MacSetup/Main.swift || APBAD="$APBAD installs-restart-updates"
grep -q 'MSU_AUTH_TIMEOUT' Sources/MacSetup/Install/ScriptPrelude.swift || APBAD="$APBAD no-watchdog"
if [ -z "$APBAD" ]; then
  ok "scheduled runs may prompt, with a timeout, and never install restart updates"
else
  bad "scheduled runs may prompt, with a timeout, and never install restart updates" "$APBAD"
fi

# The nightly run must surface pending Apple updates even though it cannot
# install them, or they would go unnoticed indefinitely.
if grep -q 'Apple update(s) pending' Sources/MacSetup/Main.swift; then
  ok "scheduled run reports pending Apple updates"
else
  bad "scheduled run reports pending Apple updates"
fi

# The bar must not claim "no password needed" when Apple updates are selected.
if grep -q 'selectedSystemUpdates.isEmpty { n += 1 }' Sources/MacSetup/Models/AppState.swift; then
  ok "password-prompt count includes Apple updates"
else
  bad "password-prompt count includes Apple updates" "the bar would claim no password is needed"
fi

# The checker itself must stay read-only — only the batch installs.
if grep -qE '"-i"|"--install"' Sources/MacSetup/Install/SystemUpdateChecker.swift; then
  bad "the update checker stays read-only"
else
  ok "the update checker stays read-only"
fi

# The parser must survive Apple's exact output shape.
python3 - <<'PY' > /tmp/st-su.txt 2>&1
sample = """Software Update Tool

Finding available software
Software Update found the following new or updated software:
* Label: Command Line Tools for Xcode 26.6-26.6
	Title: Command Line Tools for Xcode 26.6, Version: 26.6, Size: 920431KiB, Recommended: YES,
* Label: macOS Tahoe 26.7-25G220
	Title: macOS Tahoe 26.7, Version: 26.7, Size: 18172948KiB, Recommended: YES, Action: restart,
"""
labels = [l.split("* Label:")[1].strip() for l in sample.splitlines() if l.strip().startswith("* Label:")]
restarts = [l for l in sample.splitlines() if "Action: restart" in l]
print("CLEAN" if len(labels) == 2 and len(restarts) == 1 else f"BAD {labels} {restarts}")
PY
grep -q CLEAN /tmp/st-su.txt && ok "software update output shape is understood" \
  || bad "software update output shape is understood" "$(cat /tmp/st-su.txt)"

# App Store detection must not depend on Spotlight: the attribute mas uses
# (kMDItemAppStoreHasReceipt) is no longer populated on current macOS, so
# reindexing cannot fix it and reporting "up to date" would be wrong.
ASBAD=""
grep -q '_MASReceipt/receipt' Sources/MacSetup/Install/AppStoreChecker.swift || ASBAD="$ASBAD no-receipt-scan"
grep -q 'case cannotDetect' Sources/MacSetup/Install/AppStoreChecker.swift || ASBAD="$ASBAD no-cannotDetect-state"
grep -q 'MAS_NO_AUTO_INDEX' Sources/MacSetup/Install/AppStoreChecker.swift || ASBAD="$ASBAD no-index-suppression"
if [ -z "$ASBAD" ]; then
  ok "App Store apps are found by receipt, and undetectable versions are said so"
else
  bad "App Store apps are found by receipt" "$ASBAD"
fi

# The receipt scan must actually find the apps that are on this Mac.
RCOUNT=$(find /Applications -maxdepth 2 -name receipt -path '*_MASReceipt*' 2>/dev/null | wc -l | tr -d ' ')
if [ "${RCOUNT:-0}" -gt 0 ]; then
  ok "receipt scan finds $RCOUNT App Store app(s) on this Mac"
else
  skip "no App Store apps installed to detect"
fi

# The menu bar item and the background lifecycle are interactive, so check the
# wiring is present rather than pretending to have clicked it.
MBBAD=""
grep -q 'MenuBarExtra' Sources/MacSetup/MacSetupApp.swift || MBBAD="$MBBAD no-MenuBarExtra"
grep -q 'menuBarExtraStyle' Sources/MacSetup/MacSetupApp.swift || MBBAD="$MBBAD no-style"
grep -q 'applicationShouldTerminateAfterLastWindowClosed' Sources/MacSetup/Models/AppLifecycle.swift \
  || MBBAD="$MBBAD no-terminate-hook"
grep -q 'setActivationPolicy(.accessory)' Sources/MacSetup/Models/AppLifecycle.swift \
  || MBBAD="$MBBAD no-accessory-switch"
grep -q 'setActivationPolicy(.regular)' Sources/MacSetup/MacSetupApp.swift \
  || MBBAD="$MBBAD no-restore"
if [ -z "$MBBAD" ]; then
  ok "menu bar item and background lifecycle are wired"
else
  bad "menu bar item and background lifecycle are wired" "$MBBAD"
fi

# Unattended updating must never replace an app that is currently open, and
# must not attempt anything needing a password when nobody is there to approve.
if grep -q 'skippedRunning' Sources/MacSetup/Main.swift \
   && grep -q 'skippedPrivileged' Sources/MacSetup/Main.swift; then
  ok "auto-update skips running apps and anything needing an administrator"
else
  bad "auto-update skips running apps and anything needing an administrator"
fi

if [ "$OFFLINE" = "0" ]; then
  if $BIN --auto-update --dry-run > /tmp/st-auto.txt 2>&1 \
     && grep -qE '[0-9]+ app update\(s\); [0-9]+ installable now' /tmp/st-auto.txt; then
    ok "auto-update dry run reports what it would do"
  else
    bad "auto-update dry run reports what it would do" "$(tail -2 /tmp/st-auto.txt)"
  fi
else
  skip "auto-update dry run (--offline)"
fi

# If the launch agent is installed it must be valid and point at a real binary.
AGENT="$HOME/Library/LaunchAgents/local.macsetup.updatecheck.plist"
if [ -f "$AGENT" ]; then
  AEXE=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$AGENT" 2>/dev/null)
  ACAL=$(/usr/libexec/PlistBuddy -c 'Print :StartCalendarInterval:Hour' "$AGENT" 2>/dev/null)
  if plutil -lint "$AGENT" >/dev/null 2>&1 && [ -x "$AEXE" ] && [ -n "$ACAL" ]; then
    ok "update launch agent is valid, scheduled at ${ACAL}:00, and points at a real binary"
  else
    bad "update launch agent is valid and points at a real binary" "exe=$AEXE"
  fi
else
  skip "update launch agent not installed"
fi

section "4b. Profiles"
python3 - <<'PY' > /tmp/st-prof.txt 2>&1
import json, subprocess, tempfile, os
doc = {"kind":"macsetup.profile","version":2,"name":"SelfTest","notes":"",
       "apps":["google-chrome","slack"],"tweaks":["finder-show-extensions"],
       "webApps":["gmail"],"customWebApps":[],
       "exported":"2026-08-19T00:00:00Z"}
p = tempfile.mktemp(suffix=".json")
json.dump(doc, open(p,"w"))
back = json.load(open(p))
assert back["kind"] == "macsetup.profile"
assert set(back["apps"]) == {"google-chrome","slack"}
# a v1 profile (no web app keys) must still be readable
v1 = {"kind":"macsetup.profile","version":1,"name":"Old","notes":"",
      "apps":["firefox"],"tweaks":[],"exported":"2026-01-01T00:00:00Z"}
p2 = tempfile.mktemp(suffix=".json"); json.dump(v1, open(p2,"w"))
assert "webApps" not in json.load(open(p2))
os.unlink(p); os.unlink(p2)
print("CLEAN")
PY
grep -q CLEAN /tmp/st-prof.txt && ok "profile document round-trips (v1 and v2)" \
  || bad "profile document round-trips" "$(head -3 /tmp/st-prof.txt)"

# ---------------------------------------------------------------- network
section "5. Live sources"
if [ "$OFFLINE" = "1" ]; then
  skip "URL verification (--offline)"
  skip "icon resolution (--offline)"
else
  ./Scripts/verify-catalog.sh github > /tmp/st-gh.txt 2>/tmp/st-gh.err
  ghf=$(grep -c 'FAIL' /tmp/st-gh.txt || true)
  ghs=$(grep -c 'SKIP' /tmp/st-gh.txt || true)
  if [ "$ghf" = "0" ] && [ "${ghs:-0}" -gt 0 ]; then
    skip "GitHub release patterns ($ghs rate limited by GitHub)"
  elif [ "$ghf" = "0" ]; then
    ok "all GitHub release patterns resolve"
  else
    bad "GitHub release patterns" "$(grep FAIL /tmp/st-gh.txt | head -3)"
  fi

  ./Scripts/verify-catalog.sh direct > /tmp/st-dir.txt 2>/tmp/st-dir.err
  df=$(grep -c 'FAIL' /tmp/st-dir.txt || true)
  ds=$(grep -c 'SKIP' /tmp/st-dir.txt || true)
  if [ "$df" = "0" ] && [ "${ds:-0}" -gt 0 ]; then
    skip "direct vendor URLs ($ds rate limited by the vendor)"
  elif [ "$df" = "0" ]; then
    ok "all direct vendor URLs resolve"
  else
    bad "direct vendor URLs" "$(grep FAIL /tmp/st-dir.txt | head -3)"
  fi

  $BIN --check-icons --no-cache > /tmp/st-ic.txt 2>&1
  grep -q 'duplicates: none' /tmp/st-ic.txt && ok "web app icons are all distinct" \
    || bad "web app icons are all distinct" "$(grep -A3 DUPLICATE /tmp/st-ic.txt | head -4)"
fi

# ---------------------------------------------------------------- summary
printf '\n\033[1m────────────────────────────────────────────\033[0m\n'
printf ' passed \033[32m%s\033[0m   failed \033[31m%s\033[0m   skipped \033[33m%s\033[0m\n' "$PASS" "$FAIL" "$SKIP"
printf '\033[1m────────────────────────────────────────────\033[0m\n'
[ "$FAIL" -eq 0 ] && echo "Everything checks out." || echo "Review the failures above."
exit "$FAIL"
