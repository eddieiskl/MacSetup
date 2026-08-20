#!/bin/bash
# Packages MacSetup.app for handing to someone else.
#
#   ./Scripts/package-for-sharing.sh                 ad-hoc signed (default)
#   ./Scripts/package-for-sharing.sh "Developer ID Application: Your Co (TEAMID)"
#
# Produces build/MacSetup.zip plus a README the recipient actually needs,
# because an ad-hoc signed app arrives quarantined and macOS refuses to open it.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${1:-}"
APP="build/MacSetup.app"
[ -d "$APP" ] || { echo "Build it first: ./Scripts/build-app.sh"; exit 1; }

if [ -n "$IDENTITY" ]; then
  echo "==> Signing with: $IDENTITY"
  codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  echo
  echo "Signed. To notarise (needed for a clean first launch on other Macs):"
  echo "  xcrun notarytool submit build/MacSetup.zip --keychain-profile <profile> --wait"
  echo "  xcrun stapler staple $APP"
  SIGNED=1
else
  echo "==> No Developer ID given — keeping the ad-hoc signature."
  SIGNED=0
fi

echo "==> Zipping…"
rm -f build/MacSetup.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" build/MacSetup.zip

cat > build/READ-ME-FIRST.txt <<'NOTE'
MacSetup — how to open it the first time
========================================

macOS flags anything downloaded or AirDropped as quarantined. This build is
signed ad-hoc (no paid Apple Developer certificate), so macOS will refuse to
open it with a message like "MacSetup is damaged and can't be opened."

It is not damaged. Do this once:

  1. Unzip MacSetup.zip and move MacSetup.app to /Applications
  2. Open Terminal and run:

       xattr -dr com.apple.quarantine /Applications/MacSetup.app

  3. Open MacSetup normally from then on.

If you prefer not to use Terminal: right-click the app, choose Open, then
Open again in the dialog. On macOS 15 and later you may instead need
System Settings > Privacy & Security > "Open Anyway".

What it does
------------
MacSetup installs apps from a curated catalogue, pulling each one from the
vendor's own servers. It shows you the exact bash script before running it
(Preview Script), so nothing happens that you cannot read first.

Things worth knowing
--------------------
* Most apps install with no password. Only .pkg installers need one, and they
  are batched behind a single prompt per run.
* 14 apps install via Homebrew as a .pkg and need a terminal for their password
  prompt — the app tells you which, and they are marked with a lock. Export the
  script and run it in Terminal for those.
* Web apps default to opening in your browser, so Google and Microsoft sign-in
  keeps working. "Standalone app" mode gives a real Dock icon but its own
  separate sign-in, and Google blocks sign-in from embedded windows.
* Nothing is ever deleted. Uninstall moves apps to the Trash.
NOTE

echo
echo "Ready to share:"
echo "  build/MacSetup.zip           $(du -h build/MacSetup.zip | cut -f1)"
echo "  build/READ-ME-FIRST.txt      (send this with it)"
if [ "$SIGNED" = "0" ]; then
  echo
  echo "NOTE: ad-hoc signed. Recipients must run the xattr command in the README,"
  echo "      or macOS will say the app is damaged. Sign with a Developer ID and"
  echo "      notarise to avoid that entirely."
fi
