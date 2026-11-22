#!/usr/bin/env bash
# Shows each Settings section with stand-in data and captures the window into docs/screenshots.
# Needs the bundle from scripts/bundle.sh, and Screen Recording permission for the terminal.
# The app runs against a temporary data folder with sample skills, never the real one, and
# without its menu bar item or hotkey. Each preview quits on its own and never takes focus.
#
#   scripts/capture-settings-previews.sh [output folder]
#
# BIN picks another build, and SECTIONS another list of sections. An entry with a colon, such
# as skills:half-written, selects that skill or tool in its section, or scrolls Debugging
# to that part, as debugging:sign-in does. general:recording, general:conflict, and
# general:rejected show the summon shortcut recorder in those states.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="${BIN:-build/mac-os-agent.app/Contents/MacOS/mac-os-agent}"
OUT="${1:-docs/screenshots}"
SECTIONS="${SECTIONS:-general general:recording general:conflict instructions skills skills:half-written actions actions:empty-downloads tools history history:receipts debugging debugging:sign-in}"
mkdir -p "$OUT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
DATA="$WORK/data"

skill() {
  mkdir -p "$DATA/skills/$1"
  printf -- '---\nname: %s\ndescription: %s\n---\n\n%s\n' "$1" "$2" "${3:-Steps for this skill.}" > "$DATA/skills/$1/SKILL.md"
}
skill archive-downloads "Move files older than a month from Downloads into a dated archive folder." \
$'# Archive downloads\n\nUse this when the owner asks to tidy the Downloads folder.\n\n1. Run `archive.sh`. It moves files older than 30 days into `~/Downloads/Archive/<year>-<month>`.\n2. Report how many files moved and how much space they take.\n\nThe script never deletes anything and never overwrites a file that is already in the archive.'
mkdir -p "$DATA/skills/archive-downloads/tests"
touch "$DATA/skills/archive-downloads/archive.sh" "$DATA/skills/archive-downloads/README.txt" "$DATA/skills/archive-downloads/tests/sample-folder.txt"
skill battery-report "Summarize battery health, cycle count, and the apps using the most energy."
skill clean-desktop "Sort the files on the desktop into folders by kind."
skill connect-headphones "Connect the AirPods and set them as the sound output."
skill convert-heic "Convert HEIC images in a folder to JPEG."
skill disk-space "Find the largest folders in the home folder and what can be cleared."
skill empty-trash-safely "Show what is in the Trash and empty it after a go-ahead."
skill export-notes "Export notes from the Notes app to Markdown files."
skill focus-mode "Quit chat apps, hide the Dock, and turn on Do Not Disturb for an hour."
skill git-status-everywhere "Report uncommitted work in every repo under the dev folder."
mkdir -p "$DATA/skills/half-written"
printf 'Notes for a skill, with no front matter yet.\n\nIt should list the open windows and ask which ones to close.\n' > "$DATA/skills/half-written/SKILL.md"
skill meeting-prep "Open the next calendar event's notes and documents."
skill network-check "Check Wi-Fi, DNS, and the route to the internet, and say what is wrong."
skill night-shift "Turn Night Shift on or off and set its schedule."
skill print-last-pdf "Print the most recent PDF in Downloads on the default printer."
skill rename-photos "Rename the photos in a folder by the date each one was taken."
touch "$DATA/skills/rename-photos/rename.sh"
skill resize-windows "Arrange the front windows side by side or in a grid."
skill screenshot-folder "Move new screenshots into a folder for the month."
skill update-apps "Check for app and Homebrew updates and install them after a go-ahead."
skill wallpaper-of-the-day "Set the desktop picture to the Bing image of the day."
skill zoom-cleanup "Quit Zoom and remove its leftover launch agents."
printf '{"disabled":["wallpaper-of-the-day","night-shift"]}\n' > "$DATA/skill-settings.json"

# A few quick actions, one of them off and one that no longer fits its tool.
mkdir -p "$DATA/quick-actions"
cat > "$DATA/quick-actions/start-screensaver.json" <<'JSON'
{
  "format": 1,
  "name": "Start Screensaver",
  "description": "Starts the screen saver.",
  "phrases": ["screensaver", "screen saver"],
  "enabled": true,
  "steps": [
    { "tool": "open_application", "arguments": { "bundle_identifier_or_path": "/System/Library/CoreServices/ScreenSaverEngine.app" } }
  ]
}
JSON
cat > "$DATA/quick-actions/empty-downloads.json" <<'JSON'
{
  "format": 1,
  "name": "Empty Downloads",
  "description": "Moves everything in Downloads older than a week to the Trash.",
  "phrases": ["clean downloads"],
  "steps": [
    { "tool": "run_shell_command", "arguments": { "command": "find ~/Downloads -mindepth 1 -maxdepth 1 -mtime +7 -exec trash {} +", "destructive": true } },
    { "tool": "open_item", "arguments": { "target": "~/Downloads", "application": null, "reveal": false } }
  ]
}
JSON
cat > "$DATA/quick-actions/focus-music.json" <<'JSON'
{ "format": 1, "name": "Focus Music", "description": "Opens Music for a work session.", "enabled": false,
  "steps": [ { "tool": "open_application", "arguments": { "bundle_identifier_or_path": "com.apple.Music" } } ] }
JSON

# Usage lines from the last hour, and a thread file with a few entries that hold no real content.
for minutes in 52 47 31 30 12 3; do
  date="$(date -u -v-"${minutes}"M +%Y-%m-%dT%H:%M:%SZ)"
  case $minutes in
    52) counts='"input":4210,"cached":0,"output":96,"reasoning":32,"seconds":2.8' ;;
    47) counts='"input":4630,"cached":4096,"output":188,"reasoning":64,"seconds":3.4' ;;
    31) counts='"input":5120,"cached":4480,"output":74,"seconds":1.9' ;;
    30) counts='"input":5402,"cached":4992,"output":312,"reasoning":120,"seconds":5.2' ;;
    12) counts='"input":6011,"cached":0,"output":58,"seconds":2.2' ;;
    3) counts='"input":6290,"cached":5888,"output":141,"reasoning":48,"seconds":2.6' ;;
  esac
  printf '{"date":"%s","provider":"openai","model":"gpt-6-luna",%s}\n' "$date" "$counts" >> "$DATA/usage.jsonl"
done
for _ in 1 2 3 4 5 6 7 8; do
  printf '{"date":"%s","item":{"type":"note"}}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$DATA/thread.jsonl"
done

# A small helper that prints the first normal window's number and size for a process id.
HELPER="$WORK/window-id"
cat > "$HELPER.swift" <<'SWIFT'
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for window in list where (window[kCGWindowOwnerPID as String] as? Int) == pid && (window[kCGWindowLayer as String] as? Int) == 0 {
    let bounds = window[kCGWindowBounds as String] as! [String: Any]
    print(window[kCGWindowNumber as String]!, "\(bounds["Width"]!)x\(bounds["Height"]!)")
    break
}
SWIFT
swiftc -O -o "$HELPER" "$HELPER.swift"

for appearance in light dark; do
  for entry in $SECTIONS; do
    section="${entry%%:*}"
    arguments=(--preview-settings "$section" --appearance "$appearance" --data-folder "$DATA")
    name="$section"
    if [[ "$entry" == *:* ]]; then
      arguments+=(--preview-item "${entry#*:}")
      name="$section-${entry#*:}"
    fi
    "$BIN" "${arguments[@]}" &
    PID=$!
    sleep 2
    ID="" SIZE=""
    read -r ID SIZE <<< "$("$HELPER" "$PID")" || true
    if [[ -n "$ID" ]]; then
      screencapture -x -o -l "$ID" "$OUT/settings-$name-$appearance.png"
      echo "Captured $OUT/settings-$name-$appearance.png, window $SIZE points"
    else
      echo "warning: no Settings window for $name ($appearance)" >&2
    fi
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  done
done
