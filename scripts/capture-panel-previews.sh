#!/usr/bin/env bash
# Shows the panel in each stand-in state and captures the window into docs/screenshots.
# Needs the bundle from scripts/bundle.sh, and Screen Recording permission for the terminal.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="build/mac-os-agent.app/Contents/MacOS/mac-os-agent"
OUT="${1:-docs/screenshots}"
mkdir -p "$OUT"

# A small helper that prints the panel's window number for a process id.
HELPER="$(mktemp -d)/panel-window-id"
cat > "$HELPER.swift" <<'SWIFT'
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for window in list where (window[kCGWindowOwnerPID as String] as? Int) == pid && (window[kCGWindowLayer as String] as? Int) == 3 {
    print(window[kCGWindowNumber as String]!)
    break
}
SWIFT
swiftc -O -o "$HELPER" "$HELPER.swift"

for appearance in dark light; do
  for state in empty running confirmation finished; do
    "$BIN" --preview-panel "$state" --appearance "$appearance" &
    PID=$!
    sleep 1.5
    ID="$("$HELPER" "$PID")"
    if [[ -n "$ID" ]]; then
      screencapture -x -o -l "$ID" "$OUT/panel-$state-$appearance.png"
      echo "Captured $OUT/panel-$state-$appearance.png"
    else
      echo "warning: no panel window for $state ($appearance)" >&2
    fi
    kill "$PID"
    wait "$PID" 2>/dev/null || true
  done
done
