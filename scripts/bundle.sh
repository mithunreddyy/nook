#!/bin/sh
# Builds Nook.app into ./build. Usage: scripts/bundle.sh [--install] [--open]
set -e
cd "$(dirname "$0")/.."
# Prefer Xcode's toolchain when it's installed, without needing xcode-select.
if [ -z "$DEVELOPER_DIR" ] && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift --version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
ROOT="$(pwd)"
VERSION="1.0.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
APP="$ROOT/build/Nook.app"

swift build -c release --product Nook
BIN="$(swift build -c release --product Nook --show-bin-path)/Nook"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Nook"
cp "$ROOT/Resources/nook" "$APP/Contents/Resources/nook"

# Icon, drawn by the app itself.
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
"$APP/Contents/MacOS/Nook" --render-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Nook</string>
  <key>CFBundleDisplayName</key><string>Nook</string>
  <key>CFBundleIdentifier</key><string>dev.mithun.nook</string>
  <key>CFBundleExecutable</key><string>Nook</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Mithun Reddy</string>
  <key>NSAccessibilityUsageDescription</key><string>Nook moves and resizes windows to tile them.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>dev.mithun.nook</string>
      <key>CFBundleURLSchemes</key><array><string>nook</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# A stable signing identity keeps the Accessibility grant across rebuilds;
# an ad-hoc signature changes every build and macOS asks again.
IDENTITY="${NOOK_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
if [ -z "$IDENTITY" ] && security find-certificate -c "Nook Local Signing" >/dev/null 2>&1; then
  IDENTITY="Nook Local Signing"
fi
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
  echo "Signed with: $IDENTITY"
else
  codesign --force --deep --sign - "$APP"
  ADHOC=1
  echo "Signed ad hoc: macOS will ask for Accessibility again (scripts/make-signing-identity.sh fixes that)"
fi

# Test fixtures: --fixtures builds the two window-opening apps scripts/e2e.swift drives.
case " $* " in *" --fixtures "*)
  swift build -c release --product NookFixture
  FIX_BIN="$(swift build -c release --product NookFixture --show-bin-path)/NookFixture"
  for variant in "NookFixture:dev.mithun.nook.fixture" "NookFixtureBig:dev.mithun.nook.fixture.big"; do
    NAME="${variant%%:*}"; ID="${variant#*:}"
    FAPP="$ROOT/build/$NAME.app"
    rm -rf "$FAPP"; mkdir -p "$FAPP/Contents/MacOS"
    cp "$FIX_BIN" "$FAPP/Contents/MacOS/$NAME"
    cat > "$FAPP/Contents/Info.plist" <<FPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
FPLIST
    codesign --force --sign - "$FAPP"
  done
  echo "Built fixtures" ;;
esac

for arg in "$@"; do
  case "$arg" in
    --install)
      pkill -x Nook 2>/dev/null || true
      rm -rf /Applications/Nook.app
      cp -R "$APP" /Applications/Nook.app
      APP=/Applications/Nook.app
      # An ad-hoc build can't use the previous build's grant; clear the stale
      # entry so System Settings doesn't show a switch that's on but dead.
      if [ "${ADHOC:-0}" = 1 ]; then tccutil reset Accessibility dev.mithun.nook >/dev/null 2>&1 || true; fi
      # Only the installed copy should answer nook:// links.
      LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
      "$LSREG" -u "$ROOT/build/Nook.app" >/dev/null 2>&1 || true
      "$LSREG" -f /Applications/Nook.app >/dev/null 2>&1 || true
      echo "Installed to /Applications/Nook.app" ;;
    --open)
      pkill -x Nook 2>/dev/null || true
      open "$APP" ;;
  esac
done
echo "Built $APP"
