#!/usr/bin/env bash
# Shows each Settings pane with stand-in data and captures the window into docs/screenshots.
# Needs the bundle from scripts/bundle.sh, and Screen Recording permission for the terminal.
# The app runs against a temporary data folder with a few sample skills, never the real one,
# and without its menu bar item or hotkey.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="build/mac-os-agent.app/Contents/MacOS/mac-os-agent"
OUT="${1:-docs/screenshots}"
mkdir -p "$OUT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
DATA="$WORK/data"

skill() {
  mkdir -p "$DATA/skills/$1"
  printf '%s\n' "$2" > "$DATA/skills/$1/SKILL.md"
}
skill rename-photos $'---\nname: rename-photos\ndescription: Rename the photos in a folder by the date each one was taken.\n---\n\nRun rename.sh with the folder.'
touch "$DATA/skills/rename-photos/rename.sh"
skill focus-mode $'---\nname: focus-mode\ndescription: Quit chat apps, hide the Dock, and turn on Do Not Disturb for an hour.\n---\n\nSteps.'
skill wallpaper-of-the-day $'---\nname: wallpaper-of-the-day\ndescription: Set the desktop picture to the Bing image of the day.\n---\n\nSteps.'
skill half-written $'Notes for a skill, with no front matter yet.'
printf '{"disabled":["wallpaper-of-the-day"]}\n' > "$DATA/skill-settings.json"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for counts in '"input":4210,"cached":0,"output":96' '"input":4630,"cached":4096,"output":188' '"input":5120,"cached":4480,"output":74'; do
  printf '{"date":"%s","provider":"openai","model":"gpt-6-luna",%s}\n' "$NOW" "$counts" >> "$DATA/usage.jsonl"
done

# A small helper that prints the first normal window's number for a process id.
HELPER="$WORK/window-id"
cat > "$HELPER.swift" <<'SWIFT'
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for window in list where (window[kCGWindowOwnerPID as String] as? Int) == pid && (window[kCGWindowLayer as String] as? Int) == 0 {
    print(window[kCGWindowNumber as String]!)
    break
}
SWIFT
swiftc -O -o "$HELPER" "$HELPER.swift"

for appearance in light dark; do
  for pane in general instructions skills; do
    "$BIN" --preview-settings "$pane" --appearance "$appearance" --data-folder "$DATA" &
    PID=$!
    sleep 2
    ID="$("$HELPER" "$PID")"
    if [[ -n "$ID" ]]; then
      screencapture -x -o -l "$ID" "$OUT/settings-$pane-$appearance.png"
      echo "Captured $OUT/settings-$pane-$appearance.png"
    else
      echo "warning: no Settings window for $pane ($appearance)" >&2
    fi
    kill "$PID"
    wait "$PID" 2>/dev/null || true
  done
done
