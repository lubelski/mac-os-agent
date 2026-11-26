#!/usr/bin/env bash
# Draws panel states and Settings sections to PNG files without putting a window on screen, for
# pull request evidence. Nothing appears, nothing takes focus, and it needs no Screen Recording
# permission, so an agent can run it without asking the owner. See `PreviewRender`.
#
#   scripts/render-previews.sh panel:script-confirmation settings:tools:run_script
#   scripts/render-previews.sh --pr 81 panel:script-confirmation    renders, then attaches them
#                                                                   to pull request 81 in a comment
#   scripts/render-previews.sh --list                               lists the states
#
# A state is `panel:<name>`, a `--preview-panel` state, or `settings:<section>[:<item>]`, a
# `--preview-settings` section with an optional `--preview-item`. Options:
#
#   --out <folder>          where the PNGs go, build/renders by default
#   --appearances "dark"    dark and light by default
#   --theme <id>            the panel in a theme, without saving it
#   --glass on              keep glass on. Off by default: offscreen, glass and the vibrant
#                           colors drawn on it come out missing, most of all in light mode, while
#                           the theme's opaque fallback draws every box, line, and mark
#   --pr <number>           attach the PNGs to that pull request with `gh pr comment --attach`
#   --title "<text>"        the comment's first line, "Renders" by default
#
# Glass and blur need the window server, so the panel is drawn with Use glass off. States
# made of two windows (the inspector, incognito-beside) or of motion need
# scripts/capture-panel-previews.sh, which puts a window on screen: ask the owner first.
#
# It uses a debug build, copied to build/render, stamped with the SDK as bundle.sh does (or it
# draws in the old look), and signed ad hoc. Every run uses a fresh temporary data folder.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/renders"
APPEARANCES=(dark light)
THEME=()
GLASS=(--preview-glass off)
PR=""
TITLE="Renders"
STATES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --appearances) read -r -a APPEARANCES <<<"$2"; shift 2 ;;
    --theme) THEME=(--preview-theme "$2"); shift 2 ;;
    --glass) [[ "$2" == "on" ]] && GLASS=(); shift 2 ;;
    --pr) PR="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --list)
      echo "Panel states (panel:<name>):"
      grep -oE 'case "[a-z0-9-]+"(, "[a-z0-9-]+")*:' Sources/mac-os-agent/PanelPreview.swift Sources/mac-os-agent/*Preview.swift \
        | grep -oE '"[a-z0-9-]+"' | tr -d '"' | sort -u | grep -vE '^(incognito-beside|inspector-.*)$' | sed 's/^/  /'
      echo "Settings sections (settings:<section>[:<item>]):"
      awk '/^enum SettingsSection/ { on = 1; next } on && /^}/ { exit }
        on && $1 == "case" && $2 !~ /^\./ { if ($3 == "=") { gsub(/"/, "", $4); print "  " $4 } else print "  " $2 }' \
        Sources/mac-os-agent/SettingsWindow.swift
      exit 0 ;;
    --*) echo "unknown option $1" >&2; exit 2 ;;
    *) STATES+=("$1"); shift ;;
  esac
done
if [[ ${#STATES[@]} -eq 0 ]]; then
  echo "Name at least one state, such as panel:confirmation or settings:tools:run_script. --list lists them." >&2
  exit 2
fi

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift build --product mac-os-agent >/dev/null
SOURCE="$(swift build --show-bin-path)/mac-os-agent"
BIN="build/render/mac-os-agent"
mkdir -p build/render "$OUT"
cp "$SOURCE" "$BIN"
# The copy finds Sparkle beside it, as the debug binary does.
ln -sfn "$(dirname "$SOURCE")/Sparkle.framework" build/render/Sparkle.framework
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
xcrun vtool -set-build-version macos 27.0 "$SDK_VERSION" -replace -output "$BIN" "$BIN" 2>/dev/null
codesign --force --sign - "$BIN" 2>/dev/null

DATA="$(mktemp -d)"
trap 'rm -rf "$DATA"' EXIT
# Stand-in MCP servers, which only MCP Servers and an MCP tool in Tools show.
scripts/write-sample-mcp-data.sh "$DATA"
FILES=()
for state in "${STATES[@]}"; do
  IFS=: read -r kind name item <<<"$state"
  for appearance in "${APPEARANCES[@]}"; do
    case "$kind" in
      panel)
        file="$OUT/panel-$name-$appearance.png"
        args=(--preview-panel "$name" ${THEME[@]+"${THEME[@]}"} ${GLASS[@]+"${GLASS[@]}"}) ;;
      settings)
        file="$OUT/settings-$name${item:+-$item}-$appearance.png"
        args=(--preview-settings "$name")
        [[ -n "$item" ]] && args+=(--preview-item "$item") ;;
      *) echo "unknown state $state: use panel:<name> or settings:<section>[:<item>]" >&2; exit 2 ;;
    esac
    # A render quits on its own. The timeout is only a guard against a state that never draws.
    if ! timeout 20 "$BIN" --data-folder "$DATA" "${args[@]}" --appearance "$appearance" --render-to "$file"; then
      echo "failed to render $state in $appearance" >&2
      exit 1
    fi
    FILES+=("$file")
  done
done

if [[ -n "$PR" ]]; then
  BODY="$(mktemp)"
  ATTACH=()
  {
    echo "$TITLE, drawn offscreen with \`scripts/render-previews.sh\` from stand-in data, with Use glass off."
    echo
    for file in "${FILES[@]}"; do
      label="$(basename "$file" .png)"
      echo "![${label}](./$(basename "$file"))"
      ATTACH+=(--attach "./$(basename "$file")#${label}")
    done
  } >"$BODY"
  (cd "$OUT" && gh pr comment "$PR" --body-file "$BODY" "${ATTACH[@]}")
  rm -f "$BODY"
fi
