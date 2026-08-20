#!/bin/bash
# Builds MacSetup.app — a self-contained bundle that runs on a fresh Mac with
# no Xcode, no Homebrew and no other dependencies.
#
#   ./Scripts/build-app.sh [--debug]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
[ "${1:-}" = "--debug" ] && CONFIG=debug

APP="build/MacSetup.app"
BIN_NAME=MacSetup

echo "==> Building ($CONFIG)…"
if [ "$CONFIG" = "release" ]; then
  # A universal binary via --arch needs full Xcode. Build each slice with
  # --triple instead, which works with Command Line Tools alone, then lipo.
  ARM_TRIPLE=arm64-apple-macosx14.0
  X86_TRIPLE=x86_64-apple-macosx14.0

  swift build -c release --triple "$ARM_TRIPLE"
  ARM_DIR="$(swift build -c release --triple "$ARM_TRIPLE" --show-bin-path)"
  ARM_BIN="$ARM_DIR/$BIN_NAME"
  ARM_HOST="$ARM_DIR/WebAppHost"

  if swift build -c release --triple "$X86_TRIPLE" >/tmp/macsetup-x86.log 2>&1; then
    X86_DIR="$(swift build -c release --triple "$X86_TRIPLE" --show-bin-path)"
    X86_BIN="$X86_DIR/$BIN_NAME"
    X86_HOST="$X86_DIR/WebAppHost"
  else
    echo "    WARNING: the Intel slice failed to build — this app will NOT run"
    echo "             on Intel Macs. Last lines of /tmp/macsetup-x86.log:"
    tail -5 /tmp/macsetup-x86.log | sed 's/^/               /'
    X86_BIN=""; X86_HOST=""
  fi
else
  swift build
  ARM_DIR="$(swift build --show-bin-path)"
  ARM_BIN="$ARM_DIR/$BIN_NAME"
  ARM_HOST="$ARM_DIR/WebAppHost"
  X86_BIN=""; X86_HOST=""
fi

echo "==> Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ -n "$X86_BIN" ] && [ -f "$X86_BIN" ]; then
  lipo -create "$ARM_BIN" "$X86_BIN" -output "$APP/Contents/MacOS/$BIN_NAME"
else
  cp "$ARM_BIN" "$APP/Contents/MacOS/$BIN_NAME"
fi
chmod +x "$APP/Contents/MacOS/$BIN_NAME"

# The catalogue is read from Resources/ so it can be edited in place without a rebuild.
cp Sources/MacSetup/Resources/catalog.json "$APP/Contents/Resources/catalog.json"

# About details live alongside the catalogue so they can be edited in a built
# app (Show Package Contents -> Contents/Resources/about.json) without a rebuild.
cp Sources/MacSetup/Resources/about.json "$APP/Contents/Resources/about.json"

# Embedded host for standalone web apps. Each generated web app bundle gets a
# copy of this, which is what gives it a real Dock icon of its own.
if [ -n "${X86_HOST:-}" ] && [ -f "${X86_HOST:-}" ] && [ -f "$ARM_HOST" ]; then
  lipo -create "$ARM_HOST" "$X86_HOST" -output "$APP/Contents/Resources/WebAppHost"
elif [ -f "$ARM_HOST" ]; then
  cp "$ARM_HOST" "$APP/Contents/Resources/WebAppHost"
fi
[ -f "$APP/Contents/Resources/WebAppHost" ] && chmod +x "$APP/Contents/Resources/WebAppHost"

# Read the copyright straight out of about.json so there is one source of truth.
COPYRIGHT=$(python3 -c "import json;print(json.load(open('Sources/MacSetup/Resources/about.json')).get('copyright',''))" 2>/dev/null || echo "")

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>MacSetup</string>
  <key>CFBundleDisplayName</key>       <string>MacSetup</string>
  <key>CFBundleExecutable</key>        <string>$BIN_NAME</string>
  <key>CFBundleIdentifier</key>        <string>local.macsetup.app</string>
  <key>CFBundleVersion</key>           <string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleIconFile</key>          <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key>   <string>$COPYRIGHT</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>MacSetup needs to ask for administrator authorisation so it can install .pkg installers.</string>
</dict>
</plist>
PLIST

# --- icon ---------------------------------------------------------------
if command -v sips >/dev/null && command -v iconutil >/dev/null; then
  echo "==> Generating icon…"
  ICONSET=$(mktemp -d)/AppIcon.iconset
  mkdir -p "$ICONSET"
  SRC=$(mktemp -d)/icon.png
  # A simple rounded-square glyph drawn with Python's built-in tools.
  python3 - "$SRC" <<'PYICON'
import struct, zlib, sys, math
S = 1024
px = bytearray()
def blend(a, b, t): return tuple(round(a[i] + (b[i]-a[i])*t) for i in range(3))
TOP, BOT = (64,124,255), (128,72,232)
R = 224
for y in range(S):
    row = bytearray()
    for x in range(S):
        # rounded-rect mask with a soft edge
        dx = max(R - x, 0, x - (S-1-R)); dy = max(R - y, 0, y - (S-1-R))
        d = math.hypot(dx, dy)
        a = 1.0 if d <= R-1 else (0.0 if d >= R+1 else (R+1-d)/2)
        c = blend(TOP, BOT, y/(S-1))
        # downward arrow + baseline, the "install" glyph
        cx, cy = S/2, S/2 - 40
        inside = False
        if abs(x-cx) < 62 and cy-230 < y < cy+70: inside = True
        if y >= cy+40 and y <= cy+210 and abs(x-cx) <= (210 - (y-(cy+40)))*1.15: inside = True
        if cy+300 < y < cy+360 and abs(x-cx) < 250: inside = True
        if inside: c = (255,255,255)
        row += bytes((*c, round(a*255)))
    px += b'\x00' + row
def chunk(t, d):
    c = struct.pack('>I', len(d)) + t + d
    return c + struct.pack('>I', zlib.crc32(t+d) & 0xffffffff)
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', S, S, 8, 6, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(bytes(px), 9))
       + chunk(b'IEND', b''))
open(sys.argv[1], 'wb').write(png)
PYICON
  for s in 16 32 128 256 512; do
    sips -z $s $s "$SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1
    sips -z $((s*2)) $((s*2)) "$SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || \
    echo "    (icon generation skipped)"
fi

# --- signing ------------------------------------------------------------
# Ad-hoc signing is enough for a locally built tool and keeps macOS from
# complaining about a damaged bundle. Replace with your Developer ID to
# distribute it across a fleet:
#   codesign --deep --force --options runtime --sign "Developer ID Application: …" "$APP"
echo "==> Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "    (ad-hoc signing skipped)"

echo
echo "Built: $APP"
du -sh "$APP" | awk '{print "Size:  " $1}'
file "$APP/Contents/MacOS/$BIN_NAME" | sed 's/^/Arch:  /'
echo
echo "Run it:      open $APP"
echo "Install it:  cp -R $APP /Applications/"
