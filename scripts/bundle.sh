#!/usr/bin/env bash
# Builds mac-os-agent.app into ./build. Pass --install to move it to ~/Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

# Use full Xcode for SwiftUI without changing the global xcode-select setting.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/mac-os-agent"

APP="build/mac-os-agent.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/mac-os-agent"

# SwiftPM writes the deployment target into the binary's SDK field. macOS reads that field
# to decide whether to run the app in a compatibility mode for older apps, so stamp the
# SDK the app was really built with.
MIN_OS=27.0
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
xcrun vtool -set-build-version macos "$MIN_OS" "$SDK_VERSION" -replace \
  -output "$APP/Contents/MacOS/mac-os-agent" "$APP/Contents/MacOS/mac-os-agent"
STAMPED="$(xcrun vtool -show-build "$APP/Contents/MacOS/mac-os-agent" | awk '$1 == "sdk" { print $2 }')"
if [[ "$STAMPED" != "$SDK_VERSION" ]]; then
  echo "error: the binary is stamped with SDK '$STAMPED', expected '$SDK_VERSION'" >&2
  exit 1
fi

GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  GIT_COMMIT="$GIT_COMMIT-dirty"
fi
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>mac-os-agent</string>
  <key>CFBundleDisplayName</key><string>mac-os-agent</string>
  <key>CFBundleIdentifier</key><string>dev.lubelski.mac-os-agent</string>
  <key>CFBundleExecutable</key><string>mac-os-agent</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>MacOSAgentGitCommit</key><string>$GIT_COMMIT</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>mac-os-agent runs AppleScript to carry out what you ask it to do.</string>
</dict>
</plist>
PLIST

# There is no signing identity on this Mac, so sign ad hoc.
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($GIT_COMMIT)"

if [[ "${1:-}" == "--install" ]]; then
  DEST=~/Applications/mac-os-agent.app
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

  # Stop the running copy and wait until it has exited, so the old process does not still
  # hold the menu bar item or the hotkey when the new one starts.
  if pkill -x mac-os-agent; then
    for _ in {1..50}; do
      pgrep -x mac-os-agent >/dev/null || break
      sleep 0.1
    done
    pkill -9 -x mac-os-agent || true
  fi

  mkdir -p ~/Applications
  rm -rf "$DEST"
  # Move instead of copy, so only one bundle with this identifier exists.
  mv "$APP" "$DEST"
  "$LSREGISTER" -f "$DEST"
  open "$DEST"
  echo "Installed and launched $DEST"
fi
