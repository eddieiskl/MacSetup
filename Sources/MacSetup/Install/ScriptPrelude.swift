import Foundation

/// The static bash library that every generated script embeds.
///
/// Design notes:
///  * Everything runs as the logged-in user. `/Applications` is group-writable by
///    admin users, so .dmg/.zip apps, Homebrew and `defaults` never need root.
///  * Only `installer -pkg` genuinely requires root. Those are downloaded during
///    the normal pass, queued, and installed at the end inside a SINGLE
///    `osascript ... with administrator privileges` call — so the user sees one
///    authorisation dialog for the whole run rather than one per package.
///  * Progress is reported on stdout as `@@MS|<id>|<state>|<detail>` lines which
///    the app parses. Any other output is kept as raw log text.
enum ScriptPrelude {
    static let body: String = #"""
# ---------------------------------------------------------------- status protocol
msu_status() { printf '@@MS|%s|%s|%s\n' "$1" "$2" "${3:-}"; }
msu_begin()  { msu_status "$1" running "Starting"; }
msu_ok()     { MSU_OK=$((MSU_OK+1)); msu_status "$1" "done" "${2:-Installed}"; }
msu_fail()   { MSU_FAIL=$((MSU_FAIL+1)); msu_status "$1" failed "${2:-$MSU_ERR}"; }
msu_skip()   { MSU_SKIP=$((MSU_SKIP+1)); msu_status "$1" skipped "${2:-Already installed}"; }
msu_note()   { printf '   %s\n' "$*"; }

MSU_OK=0; MSU_FAIL=0; MSU_SKIP=0
MSU_RUN_ID="${MSU_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"

# ---------------------------------------------------------------- pause / resume
# The app pauses a run by creating PAUSE_FLAG. This is checked between queue
# items only — never in the middle of a download, a copy or an installer — so a
# pause can never leave an app half-installed. The cost is that pausing takes
# effect once the current item finishes.
msu_wait_if_paused() {
  [ -n "${PAUSE_FLAG:-}" ] || return 0
  [ -f "$PAUSE_FLAG" ] || return 0
  msu_status "__queue__" paused "1"
  while [ -f "$PAUSE_FLAG" ]; do
    sleep 0.4
    # A cancel removes the whole staging directory, so stop waiting.
    [ -d "${STAGE:-/nonexistent}" ] || return 1
  done
  msu_status "__queue__" resumed "1"
  return 0
}; MSU_ERR=""

# ---------------------------------------------------------------- user context
# Run a command as the console user even if this script was elevated.
msu_as_user() {
  if [ "$(id -u)" -eq 0 ] && [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
    sudo -u "$REAL_USER" -H "$@"
  else
    "$@"
  fi
}

msu_cleanup() {
  # Detach first: deleting the staging directory while a disk image is still
  # mounted under it makes rm walk into a read-only volume and leaves it behind.
  if [ -n "${STAGE:-}" ]; then
    for m in "$STAGE"/mnt.*; do
      [ -d "$m" ] && hdiutil detach "$m" -force >/dev/null 2>&1
    done
    [ -d "$STAGE" ] && rm -rf "$STAGE"
  fi
  return 0
}
trap msu_cleanup EXIT

# ---------------------------------------------------------------- detection
# True when the app is already present, checked by bundle id first then by name.
msu_installed() {
  local bundle="$1" appname="$2"
  if [ -n "$appname" ]; then
    [ -d "/Applications/$appname.app" ] && return 0
    [ -d "$USER_HOME/Applications/$appname.app" ] && return 0
  fi
  if [ -n "$bundle" ]; then
    local hit
    hit=$(mdfind "kMDItemCFBundleIdentifier == '$bundle'" 2>/dev/null | head -1)
    [ -n "$hit" ] && [ -d "$hit" ] && return 0
  fi
  return 1
}

msu_have_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- download
msu_content_length() {
  curl -fsSLI --connect-timeout 20 --max-time 60 "$1" 2>/dev/null \
    | awk 'BEGIN{IGNORECASE=1} /^content-length:/ {v=$2} END {gsub(/\r/,"",v); print v+0}'
}

# msu_download <url> <outfile> <id>  — streams a live percentage while curl runs.
#
# The total size is taken from the real download's own response headers, not a
# separate HEAD request: several vendors answer HEAD without a Content-Length,
# or answer it differently from the GET that follows. When the size genuinely
# cannot be known, the transferred byte count is reported instead so the UI
# still shows movement rather than a stalled bar.
msu_human() {
  awk -v b="${1:-0}" 'BEGIN{
    if (b >= 1073741824) printf "%.1f GB", b/1073741824;
    else if (b >= 1048576) printf "%.1f MB", b/1048576;
    else if (b >= 1024) printf "%.0f KB", b/1024;
    else printf "%d B", b;
  }'
}

msu_header_length() {   # read Content-Length out of a curl header dump
  [ -f "$1" ] || { echo 0; return; }
  awk 'BEGIN{IGNORECASE=1; v=0}
       /^content-length:/ {gsub(/\r/,"",$2); v=$2}
       END{print v+0}' "$1"
}

msu_download() {
  local url="$1" out="$2" id="$3" total=0 cur pct pid rc hdr
  hdr="$STAGE/$id.hdr"
  rm -f "$hdr"
  msu_status "$id" downloading "0"

  curl -fL --retry 3 --retry-delay 2 --connect-timeout 25 -sS \
       -A "$MSU_UA" -D "$hdr" -o "$out" "$url" 2>"$STAGE/curl.err" &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    cur=$(stat -f%z "$out" 2>/dev/null || echo 0)
    # Headers appear as soon as the response starts, redirects resolved.
    if [ "${total:-0}" -le 0 ]; then total=$(msu_header_length "$hdr"); fi
    if [ "${total:-0}" -gt 0 ]; then
      pct=$(( cur * 100 / total ))
      [ "$pct" -gt 100 ] && pct=100
      msu_status "$id" downloading "$pct|$(msu_human "$cur") of $(msu_human "$total")"
    else
      msu_status "$id" downloading "-1|$(msu_human "$cur")"
    fi
    sleep 0.3
  done
  wait "$pid"; rc=$?

  if [ $rc -ne 0 ]; then
    MSU_ERR="Download failed: $(head -c 200 "$STAGE/curl.err" 2>/dev/null | tr -d '\n')"
    return 1
  fi
  if [ ! -s "$out" ]; then MSU_ERR="Download produced an empty file"; return 1; fi
  cur=$(stat -f%z "$out" 2>/dev/null || echo 0)
  msu_status "$id" downloading "100|$(msu_human "$cur")"
  return 0
}

# ---------------------------------------------------------------- verification
# Reports the signing identity, and fails the item when STRICT_VERIFY=1 and the
# signature is bad or the Team ID does not match what the catalogue expects.
msu_verify() {
  local path="$1" id="$2" expected="$3" kind="$4" observed="" assess="" info=""
  [ "$VERIFY" = "0" ] && return 0

  if [ "$kind" = "pkg" ]; then
    info=$(/usr/sbin/pkgutil --check-signature "$path" 2>&1)
    observed=$(printf '%s' "$info" | awk -F'[()]' '/Developer ID Installer|Software Update/ {print $2; exit}')
    assess=$(/usr/sbin/spctl -a -vv -t install "$path" 2>&1 | head -2 | tr '\n' ' ')
  else
    info=$(/usr/bin/codesign -dv --verbose=4 "$path" 2>&1)
    observed=$(printf '%s' "$info" | awk -F= '/^TeamIdentifier=/{print $2; exit}')
    if ! /usr/bin/codesign --verify --strict "$path" >/dev/null 2>&1; then
      msu_status "$id" verifying "Signature invalid"
      if [ "$STRICT_VERIFY" = "1" ]; then MSU_ERR="Code signature failed validation"; return 2; fi
    fi
    assess=$(/usr/sbin/spctl -a -vv -t exec "$path" 2>&1 | head -2 | tr '\n' ' ')
  fi

  [ -z "$observed" ] && observed="none"

  if [ -n "$expected" ] && [ "$expected" != "$observed" ]; then
    msu_status "$id" verifying "Team ID mismatch: expected $expected, found $observed"
    if [ "$STRICT_VERIFY" = "1" ]; then
      MSU_ERR="Team ID mismatch (expected $expected, got $observed)"
      return 2
    fi
  else
    msu_status "$id" verifying "Team ID $observed"
  fi

  case "$assess" in
    *rejected*)
      msu_status "$id" verifying "Gatekeeper rejected this download"
      if [ "$STRICT_VERIFY" = "1" ]; then MSU_ERR="Gatekeeper rejected: $assess"; return 2; fi ;;
  esac
  return 0
}

# ---------------------------------------------------------------- placement
msu_place_app() {
  local src="$1" id="$2" expected="$3" base dest
  base=$(basename "$src")
  # Admin users can write /Applications directly (it is group-writable), so no
  # password is needed. A standard user cannot, so rather than failing, install
  # into their own ~/Applications, which also needs no password.
  if [ ! -w "$APPDIR" ]; then
    if mkdir -p "$USER_HOME/Applications" 2>/dev/null; then
      APPDIR="$USER_HOME/Applications"
      msu_status "$id" installing "No write access to /Applications - using ~/Applications"
    fi
  fi
  dest="$APPDIR/$base"

  msu_status "$id" verifying ""
  msu_verify "$src" "$id" "$expected" "app" || return 2

  msu_status "$id" installing "Copying $base"
  if [ -e "$dest" ]; then
    rm -rf "$dest" 2>/dev/null || { MSU_ERR="Could not replace existing $base"; return 1; }
  fi
  if ! ditto --noqtn "$src" "$dest" 2>"$STAGE/ditto.err"; then
    MSU_ERR="Copy to $APPDIR failed: $(head -c 200 "$STAGE/ditto.err" | tr -d '\n')"
    return 1
  fi
  xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
  [ "$(id -u)" -eq 0 ] && chown -R "$REAL_USER":staff "$dest" 2>/dev/null
  return 0
}

msu_install_zip() {
  local zip="$1" id="$2" expected="$3" dir app
  dir=$(mktemp -d "$STAGE/zip.XXXXXX")
  msu_status "$id" installing "Expanding archive"
  if ! ditto -x -k "$zip" "$dir" 2>/dev/null && ! unzip -qq -o "$zip" -d "$dir" 2>/dev/null; then
    MSU_ERR="Could not expand the downloaded archive"; return 1
  fi
  app=$(find "$dir" -maxdepth 3 -name '*.app' -print -quit)
  if [ -z "$app" ]; then
    local inner
    inner=$(find "$dir" -maxdepth 2 -name '*.pkg' -print -quit)
    if [ -n "$inner" ]; then msu_queue_pkg "$id" "$inner" "$expected"; return 0; fi
    MSU_ERR="No .app or .pkg found inside the archive"; return 1
  fi
  msu_place_app "$app" "$id" "$expected"
}

msu_install_dmg() {
  local dmg="$1" id="$2" expected="$3" mnt app pkg rc=0
  mnt=$(mktemp -d "$STAGE/mnt.XXXXXX")
  msu_status "$id" installing "Mounting disk image"
  # `yes` feeds any licence prompt, but it is killed by SIGPIPE the moment
  # hdiutil exits. Under `set -o pipefail` that would mark a perfectly good
  # mount as failed, so read hdiutil's own status out of PIPESTATUS.
  yes | hdiutil attach -nobrowse -noverify -readonly -mountpoint "$mnt" "$dmg" \
        >/dev/null 2>"$STAGE/hdiutil.err"
  local attach_rc=${PIPESTATUS[1]}
  if [ "$attach_rc" -ne 0 ]; then
    MSU_ERR="Could not mount the disk image: $(head -c 160 "$STAGE/hdiutil.err" 2>/dev/null | tr -d '\n')"
    return 1
  fi
  app=$(find "$mnt" -maxdepth 2 -name '*.app' -print -quit)
  pkg=$(find "$mnt" -maxdepth 2 -name '*.pkg' -print -quit)
  if [ -n "$app" ]; then
    msu_place_app "$app" "$id" "$expected" || rc=$?
  elif [ -n "$pkg" ]; then
    local staged
    staged="$STAGE/$(basename "$pkg")"
    if cp "$pkg" "$staged"; then
      msu_queue_pkg "$id" "$staged" "$expected"; rc=$?
    else
      MSU_ERR="Could not stage the package from the disk image"; rc=1
    fi
  else
    MSU_ERR="Disk image contained neither an app nor a package"; rc=1
  fi
  hdiutil detach "$mnt" -force >/dev/null 2>&1
  return $rc
}

# ---------------------------------------------------------------- pkg queue
# Packages need root, so they are collected and installed together at the end
# behind ONE authorisation prompt.
msu_queue_pkg() {
  local id="$1" path="$2" expected="$3"
  msu_status "$id" verifying ""
  msu_verify "$path" "$id" "$expected" "pkg" || return 2
  printf 'pkg\t%s\t%s\n' "$id" "$path" >> "$PKG_QUEUE"
  msu_status "$id" awaitingauth "Waiting for administrator authorisation"
  return 3   # queued: the terminal status is emitted by msu_flush_pkgs
}

# An Apple update installs through exactly the same elevated batch as a package,
# so a run that mixes apps and macOS updates still asks for authorisation once.
# --restart is deliberately never passed: staging the update is one decision,
# rebooting someone's Mac is another.
# Download an Apple update without installing it. Staging the bytes overnight is
# safe and unattended; the install (and its restart) can then happen at a moment
# a human chose, and takes seconds rather than an hour.
msu_queue_system_download() {
  local id="$1" label="$2"
  printf 'sysdl\t%s\t%s\n' "$id" "$label" >> "$PKG_QUEUE"
  msu_status "$id" awaitingauth "Waiting for administrator authorisation"
  return 3
}

msu_queue_system() {
  local id="$1" label="$2"
  printf 'system\t%s\t%s\n' "$id" "$label" >> "$PKG_QUEUE"
  msu_status "$id" awaitingauth "Waiting for administrator authorisation"
  return 3
}

msu_flush_pkgs() {
  [ ! -s "$PKG_QUEUE" ] && return 0
  local n root_script
  n=$(wc -l < "$PKG_QUEUE" | tr -d ' ')
  msu_status "__queue__" auth "$n"
  root_script="$STAGE/install-pkgs.sh"
  {
    echo '#!/bin/bash'
    echo 'export PATH="/usr/bin:/bin:/usr/sbin:/sbin"'
    echo "LOG='$LOG'"
    echo 'while IFS=$'"'"'\t'"'"' read -r kind id path; do'
    echo '  if [ "$kind" = "sysdl" ]; then'
    echo '    printf "@@MS|%s|downloading|-1|staging the update\\n" "$id" >> "$LOG"'
    echo '    if /usr/sbin/softwareupdate -d "$path" >>"$LOG" 2>&1; then'
    echo '      printf "@@MS|%s|done|Downloaded, ready to install\\n" "$id" >> "$LOG"'
    echo '    else'
    echo '      printf "@@MS|%s|failed|Could not download the update\\n" "$id" >> "$LOG"'
    echo '    fi'
    echo '    continue'
    echo '  fi'
    echo '  if [ "$kind" = "system" ]; then'
    echo '    printf "@@MS|%s|installing|Installing Apple update (this can take a long time)\\n" "$id" >> "$LOG"'
    echo '    if /usr/sbin/softwareupdate -i "$path" >>"$LOG" 2>&1; then'
    echo '      printf "@@MS|%s|done|Installed\\n" "$id" >> "$LOG"'
    echo '    else'
    echo '      printf "@@MS|%s|failed|softwareupdate returned an error\\n" "$id" >> "$LOG"'
    echo '    fi'
    echo '    continue'
    echo '  fi'
    echo '  if [ "$kind" = "exec" ]; then'
    echo '    printf "@@MS|%s|installing|Running the vendor installer\n" "$id" >> "$LOG"'
    echo '    if "$path" $MSU_EXEC_ARGS >>"$LOG" 2>&1; then'
    echo '      printf "@@MS|%s|done|Installed\n" "$id" >> "$LOG"'
    echo '    else'
    echo '      printf "@@MS|%s|failed|The vendor installer returned an error\n" "$id" >> "$LOG"'
    echo '    fi'
    echo '    continue'
    echo '  fi'
    echo '  printf "@@MS|%s|installing|Installing package\n" "$id" >> "$LOG"'
    echo '  if /usr/sbin/installer -pkg "$path" -target / >>"$LOG" 2>&1; then'
    echo '    printf "@@MS|%s|done|Installed\n" "$id" >> "$LOG"'
    echo '  else'
    echo '    printf "@@MS|%s|failed|Package installer returned an error\n" "$id" >> "$LOG"'
    echo '  fi'
    echo "done < '$PKG_QUEUE'"
  } > "$root_script"
  chmod +x "$root_script"

  osascript -e "do shell script \"/bin/bash '$root_script'\" with administrator privileges" \
      >/dev/null 2>"$STAGE/auth.err" &
  local auth_pid=$! watchdog_pid=""
  if [ "${MSU_AUTH_TIMEOUT:-0}" -gt 0 ]; then
    ( sleep "$MSU_AUTH_TIMEOUT"; kill -9 "$auth_pid" 2>/dev/null ) &
    watchdog_pid=$!
  fi
  wait "$auth_pid"
  local auth_rc=$?
  [ -n "$watchdog_pid" ] && kill -9 "$watchdog_pid" 2>/dev/null
  if [ "$auth_rc" -ne 0 ]; then
    while IFS=$'\t' read -r kind id path; do
      msu_status "$id" failed "Administrator authorisation was declined"
    done < "$PKG_QUEUE"
    return 1
  fi
  # The elevated child writes straight to the log, so tally results here.
  while IFS=$'\t' read -r kind id path; do
    if grep -q "@@MS|$id|done|" "$LOG" 2>/dev/null; then
      MSU_OK=$((MSU_OK+1))
    else
      MSU_FAIL=$((MSU_FAIL+1))
    fi
  done < "$PKG_QUEUE"
  # Safe to call again later: a Homebrew fallback can queue more packages.
  : > "$PKG_QUEUE"
  return 0
}

# ---------------------------------------------------------------- github resolver
# Finds the first asset in the latest release whose name matches a regex.
msu_github_asset() {
  local repo="$1" pattern="$2" tag url json

  # The JSON API allows 60 unauthenticated calls an hour, shared per IP — an
  # office behind one NAT exhausts that quickly. These two endpoints are not
  # metered: /releases/latest redirects to the tag, and expanded_assets lists
  # the files for it.
  tag=$(curl -fsSLI -A "$MSU_UA" --connect-timeout 20 -o /dev/null -w '%{url_effective}' \
        "https://github.com/$repo/releases/latest" 2>/dev/null | sed 's|.*/tag/||')
  if [ -n "$tag" ] && [ "$tag" != "https://github.com/$repo/releases/latest" ]; then
    url=$(curl -fsSL -A "$MSU_UA" --connect-timeout 20 \
          "https://github.com/$repo/releases/expanded_assets/$tag" 2>/dev/null \
          | grep -oE 'href="[^"]*/releases/download/[^"]*"' \
          | sed 's|href="|https://github.com|; s|"$||' \
          | while IFS= read -r u; do
              printf '%s' "${u##*/}" | grep -qE "$pattern" && printf '%s\n' "$u"
            done | head -1)
    if [ -n "$url" ]; then printf '%s' "$url"; return 0; fi
  fi

  # Fall back to the API only if the unmetered path did not work.
  json=$(curl -sSL --connect-timeout 20 -H 'Accept: application/vnd.github+json' \
         -A "$MSU_UA" "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null)
  case "$json" in
    *"API rate limit exceeded"*|*"rate limit"*)
      MSU_ERR="GitHub rate limit reached and the release page could not be read"
      return 1 ;;
  esac
  if [ -z "$json" ]; then MSU_ERR="GitHub unreachable for $repo"; return 1; fi
  url=$(printf '%s' "$json" \
        | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | sed 's/.*"\(https[^"]*\)"/\1/' \
        | while IFS= read -r u; do
            printf '%s' "${u##*/}" | grep -qE "$pattern" && printf '%s\n' "$u"
          done | head -1)
  if [ -z "$url" ]; then
    MSU_ERR="No asset in the latest $repo release matched /$pattern/"
    return 1
  fi
  printf '%s' "$url"
}

# ---------------------------------------------------------------- homebrew
msu_ensure_brew() {
  if [ -n "$BREW_BIN" ] && [ -x "$BREW_BIN" ]; then return 0; fi
  for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$p" ]; then BREW_BIN="$p"; eval "$("$p" shellenv)"; return 0; fi
  done
  if msu_have_cmd brew; then BREW_BIN=$(command -v brew); return 0; fi

  # Homebrew's installer needs root to create its prefix, but refuses to run as
  # root itself. So: create and hand over the prefix behind one authorisation
  # prompt, then run the installer normally as the user.
  msu_status "homebrew" auth "Homebrew is missing and needs to be installed first"
  local prefix="/opt/homebrew"
  [ "$MSU_ARCH" = "x86_64" ] && prefix="/usr/local"
  local prep="$STAGE/brew-prep.sh"
  {
    echo '#!/bin/bash'
    echo "mkdir -p '$prefix'/{bin,etc,include,lib,sbin,share,var,opt,Cellar,Caskroom,Frameworks}"
    echo "chown -R '$REAL_USER':admin '$prefix'"
    echo "chmod -R g+rwx '$prefix'"
  } > "$prep"
  chmod +x "$prep"
  if ! osascript -e "do shell script \"/bin/bash '$prep'\" with administrator privileges" >/dev/null 2>&1; then
    MSU_ERR="Homebrew needs administrator access to create $prefix, and authorisation was declined"
    return 1
  fi

  msu_status "homebrew" installing "Installing Homebrew (this can take a few minutes)"
  if ! msu_as_user /usr/bin/env NONINTERACTIVE=1 CI=1 /bin/bash -c \
       "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" >>"$LOG" 2>&1; then
    MSU_ERR="Homebrew installation failed. Run this once in Terminal, then retry: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    return 1
  fi
  for p in "$prefix/bin/brew" /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$p" ]; then BREW_BIN="$p"; eval "$("$p" shellenv)"; break; fi
  done
  [ -n "$BREW_BIN" ] || { MSU_ERR="Homebrew installed but brew was not found"; return 1; }
  return 0
}

# A cask whose artifact is a .pkg only needs sudo for the final install step.
# Homebrew will happily DOWNLOAD it without privileges, so fetch it that way and
# hand the package to the same elevated batch everything else uses — one prompt,
# no terminal required.
msu_brew_pkg_install() {
  local id="$1" token="$2" expected="$3"
  msu_ensure_brew || return 1

  msu_status "$id" downloading "-1|fetching via Homebrew"
  if ! msu_as_user "$BREW_BIN" fetch --cask "$token" >>"$LOG" 2>&1; then
    MSU_ERR="Could not fetch $token"
    return 1
  fi

  local cached
  cached=$(msu_as_user "$BREW_BIN" --cache --cask "$token" 2>/dev/null | tail -1)
  if [ -z "$cached" ] || [ ! -e "$cached" ]; then
    MSU_ERR="Homebrew did not report a cached download for $token"
    return 1
  fi

  case "$cached" in
    *.pkg)
      msu_queue_pkg "$id" "$cached" "$expected"
      return $?
      ;;
    *.dmg)
      local mnt pkg staged
      mnt=$(mktemp -d "$STAGE/mnt.XXXXXX")
      yes | hdiutil attach -nobrowse -noverify -readonly -mountpoint "$mnt" "$cached" \
            >/dev/null 2>"$STAGE/hdiutil.err"
      if [ "${PIPESTATUS[1]}" -ne 0 ]; then
        MSU_ERR="Could not mount the Homebrew download for $token"; return 1
      fi
      pkg=$(find "$mnt" -maxdepth 3 -name '*.pkg' -print -quit)
      if [ -z "$pkg" ]; then
        hdiutil detach "$mnt" -force >/dev/null 2>&1
        MSU_ERR="No package inside the $token disk image"; return 1
      fi
      staged="$STAGE/$id.pkg"
      cp -R "$pkg" "$staged" 2>/dev/null
      hdiutil detach "$mnt" -force >/dev/null 2>&1
      msu_queue_pkg "$id" "$staged" "$expected"
      return $?
      ;;
    *.zip)
      local dir pkg
      dir=$(mktemp -d "$STAGE/zip.XXXXXX")
      ditto -x -k "$cached" "$dir" >/dev/null 2>&1 || unzip -qq -o "$cached" -d "$dir" >/dev/null 2>&1
      pkg=$(find "$dir" -maxdepth 3 -name '*.pkg' -print -quit)
      if [ -z "$pkg" ]; then
        MSU_ERR="No package inside the $token archive"; return 1
      fi
      msu_queue_pkg "$id" "$pkg" "$expected"
      return $?
      ;;
    *)
      MSU_ERR="Homebrew's download for $token is not a package"
      return 1
      ;;
  esac
}

# Some casks ship an installer program instead of a package. Homebrew runs it
# with sudo, which needs a terminal. Fetching is unprivileged though, so download
# it with Homebrew (which keeps the version current), check the signature, and
# run it through the same elevated batch — one prompt, no terminal.
msu_brew_installer_run() {
  local id="$1" token="$2" expected="$3"; shift 3
  msu_ensure_brew || return 1

  msu_status "$id" downloading "-1|fetching via Homebrew"
  if ! msu_as_user "$BREW_BIN" fetch --cask "$token" >>"$LOG" 2>&1; then
    MSU_ERR="Could not fetch $token"; return 1
  fi
  local cached
  cached=$(msu_as_user "$BREW_BIN" --cache --cask "$token" 2>/dev/null | tail -1)
  [ -n "$cached" ] && [ -e "$cached" ] || { MSU_ERR="No cached download for $token"; return 1; }

  local dir; dir=$(mktemp -d "$STAGE/inst.XXXXXX")
  case "$cached" in
    *.zip) ditto -x -k "$cached" "$dir" >/dev/null 2>&1 || unzip -qq -o "$cached" -d "$dir" >/dev/null 2>&1 ;;
    *.dmg)
      local mnt; mnt=$(mktemp -d "$STAGE/mnt.XXXXXX")
      yes | hdiutil attach -nobrowse -noverify -readonly -mountpoint "$mnt" "$cached" >/dev/null 2>&1
      [ "${PIPESTATUS[1]}" -eq 0 ] || { MSU_ERR="Could not mount $token"; return 1; }
      ditto "$mnt" "$dir" >/dev/null 2>&1
      hdiutil detach "$mnt" -force >/dev/null 2>&1 ;;
    *) cp "$cached" "$dir/" 2>/dev/null ;;
  esac

  # A package inside is the better path — use it if present.
  local inner; inner=$(find "$dir" -maxdepth 3 -name '*.pkg' -print -quit)
  if [ -n "$inner" ]; then msu_queue_pkg "$id" "$inner" "$expected"; return $?; fi

  # Otherwise find the installer application.
  local app
  app=$(find "$dir" -maxdepth 3 -name '*nstall*.app' -print -quit)
  [ -n "$app" ] || app=$(find "$dir" -maxdepth 3 -name '*.app' -print -quit)
  if [ -z "$app" ]; then
    MSU_ERR="No installer found inside the $token download"; return 1
  fi

  local exe_name
  exe_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist" 2>/dev/null)
  [ -n "$exe_name" ] || exe_name=$(basename "$app" .app)
  local exe="$app/Contents/MacOS/$exe_name"
  if [ ! -x "$exe" ]; then
    MSU_ERR="Installer inside $token has no runnable binary"; return 1
  fi

  # Signature checked before anything runs as root.
  msu_status "$id" verifying ""
  msu_verify "$app" "$id" "$expected" "app" || return 2

  printf 'exec\t%s\t%s\n' "$id" "$exe" >> "$PKG_QUEUE"
  msu_status "$id" awaitingauth "Waiting for administrator authorisation"
  return 3
}

msu_brew_install() {
  local id="$1" what="$2" type="$3"
  msu_ensure_brew || return 1
  msu_status "$id" installing "brew install $what"
  local args=(install)
  [ "$type" = "cask" ] && args+=(--cask)
  args+=("$what")
  if msu_as_user "$BREW_BIN" "${args[@]}" >>"$LOG" 2>&1; then return 0; fi

  # "already an App at /Applications/X.app" means the app is present but not
  # managed by Homebrew — which is the normal case when updating something that
  # was installed by hand. Adopt it rather than giving up.
  if tail -30 "$LOG" 2>/dev/null | grep -q "already an App at"; then
    msu_status "$id" installing "Replacing the existing $what"
    local retry=(install)
    [ "$type" = "cask" ] && retry+=(--cask --adopt --force)
    retry+=("$what")
    if msu_as_user "$BREW_BIN" "${retry[@]}" >>"$LOG" 2>&1; then return 0; fi
    # Older Homebrew has no --adopt.
    local retry2=(install)
    [ "$type" = "cask" ] && retry2+=(--cask --force)
    retry2+=("$what")
    if msu_as_user "$BREW_BIN" "${retry2[@]}" >>"$LOG" 2>&1; then return 0; fi
  fi

  # "It seems there is already an App at ..." — the app is on disk but Homebrew
  # does not consider itself the owner, which is exactly the case when updating
  # something that was first installed from a vendor download. --adopt takes
  # ownership of the existing bundle; --force overwrites it. Without this every
  # brew-backed update failed.
  if [ "$type" = "cask" ] && tail -25 "$LOG" 2>/dev/null | grep -q "already an App at"; then
    msu_status "$id" installing "Adopting the existing $what"
    if msu_as_user "$BREW_BIN" install --cask --adopt "$what" >>"$LOG" 2>&1; then return 0; fi
    msu_status "$id" installing "Replacing the existing $what"
    if msu_as_user "$BREW_BIN" install --cask --force "$what" >>"$LOG" 2>&1; then return 0; fi
  fi

  # Already at the latest version: brew exits non-zero, but nothing is wrong.
  if [ "$type" = "cask" ]; then
    msu_as_user "$BREW_BIN" list --cask "$what" >/dev/null 2>&1 && return 0
  else
    msu_as_user "$BREW_BIN" list --formula "$what" >/dev/null 2>&1 && return 0
  fi
  # Some casks run their own installer program and Homebrew calls sudo for it.
  # sudo has no terminal to prompt on when the run is launched from the app, so
  # hand the job to a real Terminal window rather than just failing. The user
  # types their password into Terminal itself — nothing here ever sees it.
  if tail -40 "$LOG" 2>/dev/null | grep -qiE "sudo: a password is required|no tty present|Password:"; then
    if [ "${OPEN_TERMINAL:-1}" = "1" ]; then
      local helper="$MSU_HANDOFF/finish-$what.command"
      mkdir -p "$MSU_HANDOFF"
      cat > "$helper" <<HANDOFF
#!/bin/bash
echo "MacSetup: finishing the installation of $what"
echo
echo "$what ships its own installer, which macOS requires you to authorise"
echo "in a terminal. Enter your password when prompted."
echo
"$BREW_BIN" install --cask "$what"
status=\$?
echo
if [ \$status -eq 0 ]; then
  echo "$what installed. You can close this window."
else
  echo "$what did not install (exit \$status). You can close this window."
fi
HANDOFF
      chmod +x "$helper"
      if open -a Terminal "$helper" 2>>"$LOG"; then
        msu_skip "$id" "Opened in Terminal — enter your password there to finish"
        return 3
      fi
    fi
    MSU_ERR="$what runs its own installer, so it needs a terminal for its password prompt. Run: brew install --cask $what"
    return 1
  fi

  MSU_ERR="brew install $what failed - see the log for detail"
  return 1
}

# ---------------------------------------------------------------- web apps
# Builds a real .app that opens one site in its own window. Chromium browsers
# get --app= (a genuine chromeless window); anything else falls back to a
# normal open, which still gives a Dock icon and a Spotlight entry.
msu_webapp_icon() {
  local iconurl="$1" host="$2" out="$3" tmp="$STAGE/icon.src" png="$STAGE/icon.png"
  local candidates=()
  [ -n "$iconurl" ] && candidates+=("$iconurl")
  candidates+=("https://$host/apple-touch-icon.png"
               "https://$host/apple-touch-icon-precomposed.png"
               "https://$host/favicon.ico")
  for u in "${candidates[@]}"; do
    rm -f "$tmp" "$png"
    curl -fsSL -A "$MSU_UA" --max-time 15 -o "$tmp" "$u" 2>/dev/null || continue
    [ -s "$tmp" ] || continue
    # sips handles png, ico and webp; anything else is skipped.
    sips -s format png "$tmp" --out "$png" >/dev/null 2>&1 || continue
    local w
    w=$(sips -g pixelWidth "$png" 2>/dev/null | awk '/pixelWidth/{print $2}')
    [ "${w:-0}" -lt 32 ] && continue
    local iconset="$STAGE/icon.iconset"
    rm -rf "$iconset"; mkdir -p "$iconset"
    for sz in 16 32 128 256 512; do
      sips -z $sz $sz "$png" --out "$iconset/icon_${sz}x${sz}.png" >/dev/null 2>&1
      sips -z $((sz*2)) $((sz*2)) "$png" --out "$iconset/icon_${sz}x${sz}@2x.png" >/dev/null 2>&1
    done
    if iconutil -c icns "$iconset" -o "$out" 2>/dev/null; then return 0; fi
  done
  return 1
}

# msu_make_webapp <id> <name> <url> <browser-exe> <app-mode 0|1> <icon-url> <browser-name> [host-binary]
#
# With a host binary the bundle is a real standalone application: its own Dock
# icon, window and Cmd-Tab entry. Without one it is a launcher that hands the URL
# to the browser — which keeps the browser's sign-in session, but means the
# bundle exits immediately and so does not stay in the Dock.
msu_make_webapp() {
  local id="$1" name="$2" url="$3" exe="$4" appmode="$5" iconurl="$6" bname="$7" host="${8:-}"
  local dir="$APPDIR/$name.app"
  local urlhost="${url#*://}"; urlhost="${urlhost%%/*}"

  if [ -n "$host" ] && [ -x "$host" ]; then
    msu_status "$id" installing "Creating standalone $name.app"
  else
    host=""
    msu_status "$id" installing "Creating $name.app for $bname"
  fi
  rm -rf "$dir"
  if ! mkdir -p "$dir/Contents/MacOS" "$dir/Contents/Resources"; then
    MSU_ERR="Could not create $dir"; return 1
  fi

  cat > "$dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleExecutable</key><string>EXECNAME</string>
  <key>CFBundleIdentifier</key><string>local.macsetup.webapp.$id</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>MSWebAppURL</key><string>$url</string>
</dict>
</plist>
PLIST
  # The executable name differs between the two modes.
  if [ -n "$host" ]; then
    sed -i '' "s|<string>EXECNAME</string>|<string>WebAppHost</string>|" "$dir/Contents/Info.plist"
  else
    sed -i '' "s|<string>EXECNAME</string>|<string>launcher</string>|" "$dir/Contents/Info.plist"
  fi

  if [ -n "$host" ]; then
    cp "$host" "$dir/Contents/MacOS/WebAppHost"
    chmod +x "$dir/Contents/MacOS/WebAppHost"
  elif [ "$appmode" = "1" ]; then
    cat > "$dir/Contents/MacOS/launcher" <<LAUNCH
#!/bin/bash
# Opens $url in its own window. Executed directly rather than through \`open\`
# so the flag still applies when the browser is already running.
exec "$exe" --app="$url" "\$@"
LAUNCH
  else
    cat > "$dir/Contents/MacOS/launcher" <<LAUNCH
#!/bin/bash
# $bname has no app-mode flag, so this opens a normal window.
exec open -a "$exe" "$url"
LAUNCH
  fi
  [ -f "$dir/Contents/MacOS/launcher" ] && chmod +x "$dir/Contents/MacOS/launcher"

  if msu_webapp_icon "$iconurl" "$urlhost" "$dir/Contents/Resources/AppIcon.icns"; then
    msu_note "icon fetched for $name"
  else
    msu_note "no icon available for $name - using the system default"
  fi

  # An ad-hoc signature stops Gatekeeper treating the new bundle as damaged.
  codesign --force --sign - "$dir" >/dev/null 2>&1 || true
  touch "$dir"
  [ "$(id -u)" -eq 0 ] && chown -R "$REAL_USER":staff "$dir" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------- uninstall
# Deliberately conservative: it moves the bundle to the Trash rather than
# deleting it, and never touches preferences, licences or user data. Anything
# installed as a .pkg is reported rather than removed, because a package's
# receipt can span dozens of system paths and guessing at them is how you break
# a Mac.
msu_uninstall() {
  local id="$1" name="$2" bundle="$3" kind="$4" token="$5"
  msu_begin "$id"

  if [ "$kind" = "brew" ] && [ -n "$token" ]; then
    msu_ensure_brew || { msu_fail "$id"; return 1; }
    msu_status "$id" installing "brew uninstall $token"
    if msu_as_user "$BREW_BIN" uninstall --cask "$token" >>"$LOG" 2>&1 \
       || msu_as_user "$BREW_BIN" uninstall --formula "$token" >>"$LOG" 2>&1; then
      msu_ok "$id" "Removed via Homebrew"
      return 0
    fi
    # Fall through to the bundle check: a cask can be gone while the app remains.
  fi

  local target=""
  for dir in "$APPDIR" /Applications "$USER_HOME/Applications"; do
    [ -d "$dir/$name.app" ] && { target="$dir/$name.app"; break; }
  done
  if [ -z "$target" ] && [ -n "$bundle" ]; then
    target=$(mdfind "kMDItemCFBundleIdentifier == '$bundle'" 2>/dev/null | head -1)
  fi

  if [ -z "$target" ] || [ ! -d "$target" ]; then
    msu_skip "$id" "Not installed"
    return 0
  fi

  # A .pkg puts files well beyond the bundle, so removing just the app would
  # leave the rest behind and give a false sense of a clean uninstall.
  if [ "$kind" = "pkg" ]; then
    msu_fail "$id" "Installed from a package - remove it with the vendor's own uninstaller"
    return 1
  fi

  msu_status "$id" installing "Moving $name.app to the Trash"
  local trash="$USER_HOME/.Trash"
  mkdir -p "$trash" 2>/dev/null
  local dest="$trash/$name.app"
  [ -e "$dest" ] && dest="$trash/$name $(date +%H%M%S).app"
  if mv "$target" "$dest" 2>>"$LOG"; then
    msu_ok "$id" "Moved to the Trash"
    return 0
  fi
  MSU_ERR="Could not move $target to the Trash"
  msu_fail "$id"
  return 1
}

# ---------------------------------------------------------------- receipts
# A machine-readable record of what this run did. An MDM cannot ingest arbitrary
# events, but it can read state at inventory time — so an Extension Attribute
# reads this file and reports it into Jamf. Root-owned when available so a user
# cannot forge it; falls back to the user's own Library when not elevated.
MSU_RECEIPTS=""
msu_receipt_init() {
  local dir="/Library/Application Support/MacSetup"
  if [ "$(id -u)" -eq 0 ] || mkdir -p "$dir" 2>/dev/null; then
    :
  else
    dir="$USER_HOME/Library/Application Support/MacSetup"
  fi
  mkdir -p "$dir" 2>/dev/null || return 0
  MSU_RECEIPTS="$dir/receipts.jsonl"
  touch "$MSU_RECEIPTS" 2>/dev/null || MSU_RECEIPTS=""
}

# msu_receipt <id> <name> <result> <detail>
msu_receipt() {
  [ -n "$MSU_RECEIPTS" ] || return 0
  local id="$1" name="$2" result="$3" detail="${4:-}" version="" bundle=""
  bundle=$(printf '%s' "$5")
  if [ -n "$bundle" ]; then
    local path
    path=$(mdfind "kMDItemCFBundleIdentifier == '$bundle'" 2>/dev/null | head -1)
    [ -n "$path" ] && version=$(defaults read "$path/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
  fi
  printf '{"id":"%s","name":"%s","result":"%s","version":"%s","detail":"%s","host":"%s","user":"%s","at":"%s","run":"%s"}\n' \
    "$id" "$name" "$result" "${version:-unknown}" \
    "$(printf '%s' "$detail" | tr -d '"' | tr -d '\n' | cut -c1-200)" \
    "$(scutil --get ComputerName 2>/dev/null || hostname)" "$REAL_USER" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MSU_RUN_ID" >> "$MSU_RECEIPTS" 2>/dev/null || true
}

# ---------------------------------------------------------------- job runners
# Each returns 0 on success. The generated body decides whether to fall back.

msu_try_direct() {
  local id="$1" url="$2" fmt="$3" expected="$4" file
  file="$STAGE/$id.$fmt"
  msu_download "$url" "$file" "$id" || return 1
  case "$fmt" in
    dmg) msu_install_dmg "$file" "$id" "$expected" ;;
    zip) msu_install_zip "$file" "$id" "$expected" ;;
    pkg) msu_queue_pkg "$id" "$file" "$expected" ;;
    *)   MSU_ERR="Unsupported format $fmt"; return 1 ;;
  esac
}

msu_try_github() {
  local id="$1" repo="$2" pattern="$3" fmt="$4" expected="$5" url
  msu_status "$id" resolving "Looking up the latest $repo release"
  url=$(msu_github_asset "$repo" "$pattern") || return 1
  msu_note "resolved $id -> $url"
  msu_try_direct "$id" "$url" "$fmt" "$expected"
}

msu_try_script() {
  local id="$1" url="$2" verify="$3"; shift 3
  msu_status "$id" installing "Running the vendor install script"
  local tmp="$STAGE/$id-install.sh"
  if ! curl -fsSL --connect-timeout 25 -o "$tmp" "$url"; then
    MSU_ERR="Could not fetch the install script from $url"; return 1
  fi
  if ! msu_as_user /usr/bin/env "$@" /bin/bash "$tmp" >>"$LOG" 2>&1; then
    MSU_ERR="The vendor install script exited with an error"; return 1
  fi
  if [ -n "$verify" ] && ! msu_have_cmd "$verify"; then
    for p in "$USER_HOME/.local/bin" /opt/homebrew/bin /usr/local/bin; do
      [ -x "$p/$verify" ] && return 0
    done
    MSU_ERR="Install script finished but '$verify' was not found on PATH"
    return 1
  fi
  return 0
}
"""#
}
