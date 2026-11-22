#!/usr/bin/env bash
# Shows the panel in each stand-in state and captures it into docs/screenshots.
# Needs the bundle from scripts/bundle.sh, and Screen Recording permission for the terminal.
#
#   scripts/capture-panel-previews.sh [out-dir]             window captures, no backdrop
#   scripts/capture-panel-previews.sh --backdrop [out-dir]  the panel over a busy page, which
#                                                           shows the glass and its edges
#   scripts/capture-panel-previews.sh --states "a b" [out-dir]  only the states named
#   scripts/capture-panel-previews.sh --dock right [out-dir]    docked to that edge of the screen
#
# The options go in the order shown: --backdrop, then --dock, then --states.
#
# Preview runs never register the hotkey, open the thread, read the Keychain, or touch the
# panel's saved frame.
set -euo pipefail
cd "$(dirname "$0")/.."

BACKDROP=0
if [[ "${1:-}" == "--backdrop" ]]; then
  BACKDROP=1
  shift
fi

DOCK=()
SUFFIX=""
if [[ "${1:-}" == "--dock" ]]; then
  DOCK=(--preview-dock "$2")
  SUFFIX="-docked-$2"
  shift 2
fi

STATES=(empty history running confirmation finished draft multiline-draft fresh-start scrollback incognito command-hint tool-states first-message streaming fresh-start-slot)
if [[ "${1:-}" == "--states" ]]; then
  read -r -a STATES <<<"$2"
  shift 2
fi

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
  for state in "${STATES[@]}"; do
    LOG="$(mktemp)"
    if [[ $BACKDROP == 1 ]]; then
      "$BIN" --preview-panel "$state" --appearance "$appearance" --backdrop ${DOCK[@]+"${DOCK[@]}"} >"$LOG" &
    else
      "$BIN" --preview-panel "$state" --appearance "$appearance" ${DOCK[@]+"${DOCK[@]}"} >"$LOG" &
    fi
    PID=$!
    sleep 2
    if [[ $BACKDROP == 1 ]]; then
      RECT="$(awk '/^capture-rect / { print $2 }' "$LOG")"
      FILE="$OUT/panel-$state$SUFFIX-$appearance-backdrop.png"
      if [[ -n "$RECT" ]]; then
        screencapture -x -R "$RECT" "$FILE"
        echo "Captured $FILE"
      else
        echo "warning: no capture rect for $state ($appearance)" >&2
      fi
    else
      ID="$("$HELPER" "$PID")"
      FILE="$OUT/panel-$state$SUFFIX-$appearance.png"
      if [[ -n "$ID" ]]; then
        screencapture -x -o -l "$ID" "$FILE"
        echo "Captured $FILE"
      else
        echo "warning: no panel window for $state ($appearance)" >&2
      fi
    fi
    kill "$PID"
    wait "$PID" 2>/dev/null || true
    rm -f "$LOG"
  done
done

# Each preview also quits on its own after a few seconds. Report any that did not.
if pgrep -fl "mac-os-agent --preview-panel"; then
  echo "warning: preview processes are still running" >&2
fi
