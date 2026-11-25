#!/usr/bin/env bash
# Shows the panel in each stand-in state and captures it into docs/screenshots.
# Needs the bundle from scripts/bundle.sh, and Screen Recording permission for the terminal.
#
#   scripts/capture-panel-previews.sh [out-dir]             window captures, no backdrop
#   scripts/capture-panel-previews.sh --backdrop [out-dir]  the panel over a busy page, which
#                                                           shows the glass and its edges
#   scripts/capture-panel-previews.sh --states "a b" [out-dir]  only the states named
#   scripts/capture-panel-previews.sh --preset slideOverRight [out-dir]  in that layout preset
#   scripts/capture-panel-previews.sh --states instant [out-dir]  the instant action row
#   scripts/capture-panel-previews.sh --states inspector [out-dir]  the tool call inspector beside
#                                                           the panel, one state per kind of output
#   scripts/capture-panel-previews.sh --states incognito [out-dir]  the incognito window, and the
#                                                           two windows side by side
#   scripts/capture-panel-previews.sh --states bars [out-dir]  the panel with bars and an input
#                                                           pill experiment: at rest, typing, a long
#                                                           message, a match, the slash list, running,
#                                                           Stop under the pointer, queued messages,
#                                                           the lines in the conversation, the same
#                                                           lines with the experiment off, three task
#                                                           links, five with the overflow, and the
#                                                           match card down, up, and with the slash
#                                                           list
#
# An inspector state is always captured over the busy page, since it is two windows: the panel
# and the inspector attached to it. `incognito-beside` is captured as the rectangle around both
# windows, the main panel and the incognito window beside it.
#
#   scripts/capture-panel-previews.sh --theme tidewater [out-dir]  in a theme, without saving it
#   scripts/capture-panel-previews.sh --glass off [out-dir]        as drawn with Use glass off
#   scripts/capture-panel-previews.sh --appearances "dark" [out-dir]  only those appearances
#
# The options can come in any order, before the output folder.
#
# Preview runs never register the hotkey, open the thread, read the Keychain, or touch the
# panel's saved frame.
set -euo pipefail
cd "$(dirname "$0")/.."

BACKDROP=0
DOCK=()
THEME=()
SUFFIX=""
STATES=(empty history running confirmation finished draft multiline-draft fresh-start scrollback incognito incognito-empty incognito-closing incognito-command-hint command-hint tool-states first-message streaming fresh-start-slot markdown markdown-streaming markdown-code-streaming controls web-search)
APPEARANCES=(dark light)
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --backdrop) BACKDROP=1; shift ;;
    --preset) DOCK+=(--preview-preset "$2"); SUFFIX="$SUFFIX-$2"; shift 2 ;;
    --states)
      if [[ "$2" == "inspector" ]]; then
        STATES=(inspector-json inspector-table inspector-diff inspector-long inspector-running inspector-fields)
      elif [[ "$2" == "incognito" ]]; then
        STATES=(incognito incognito-empty incognito-closing incognito-command-hint incognito-beside)
      elif [[ "$2" == "instant" ]]; then
        STATES=(instant-one instant-several)
      elif [[ "$2" == "bars" ]]; then
        STATES=(bars-rest bars-typing bars-long bars-match bars-slash bars-running bars-working-hover bars-queued bars-lines bars-lines-off bars-links bars-links-more bars-card-down bars-card-up bars-card-slash)
      else
        read -r -a STATES <<<"$2"
      fi
      shift 2 ;;
    --theme) THEME+=(--preview-theme "$2"); SUFFIX="$SUFFIX-$2"; shift 2 ;;
    --glass) THEME+=(--preview-glass "$2"); SUFFIX="$SUFFIX-glass-$2"; shift 2 ;;
    --appearances) read -r -a APPEARANCES <<<"$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

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

for appearance in "${APPEARANCES[@]}"; do
  for state in "${STATES[@]}"; do
    LOG="$(mktemp)"
    if [[ $BACKDROP == 1 || $state == inspector-* ]]; then
      "$BIN" --preview-panel "$state" --appearance "$appearance" --backdrop ${DOCK[@]+"${DOCK[@]}"} ${THEME[@]+"${THEME[@]}"} >"$LOG" &
    else
      "$BIN" --preview-panel "$state" --appearance "$appearance" ${DOCK[@]+"${DOCK[@]}"} ${THEME[@]+"${THEME[@]}"} >"$LOG" &
    fi
    PID=$!
    sleep 2
    if [[ $BACKDROP == 1 || $state == inspector-* || $state == incognito-beside ]]; then
      RECT="$(awk '/^capture-rect / { rect = $2 } END { print rect }' "$LOG")"
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
