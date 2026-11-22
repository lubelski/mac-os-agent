#!/usr/bin/env bash
# Builds, signs, notarizes and publishes a release that installed copies update to.
#
#   scripts/release.sh 1.2.0            # publish version 1.2.0 from main
#   scripts/release.sh 1.2.0 --dry-run  # build the files into build/release, publish nothing
#
# A release is a GitHub Release tagged v<version> with two files: the zipped app and
# appcast.xml, the feed Sparkle reads. Installed copies fetch the feed from the latest
# release, so publishing the release is what ships the update.
#
# One-time setup on the Mac that releases:
#   1. A Developer ID Application certificate in the Keychain.
#   2. A notarization login:  xcrun notarytool store-credentials AIMeter
#      The login belongs to the Apple ID, not the app, so this one is shared with AI Meter
#      and Claude FM.
#   3. A Sparkle signing key: .build/artifacts/sparkle/Sparkle/bin/generate_keys
#      It keeps the private key in the Keychain and prints the public key. Put the public
#      key in scripts/sparkle-public-key.txt. Back the private key up: without it, installed
#      copies can't be updated. generate_keys reuses a key that is already in the Keychain,
#      so on a Mac that releases AI Meter or Claude FM this is the same key.
#
# Environment, all optional:
#   MAC_OS_AGENT_RELEASE_REPO     The GitHub repository that hosts releases. Defaults to
#                                 lubelski/mac-os-agent. Installed copies download the feed
#                                 and the zip without signing in, so it must be public.
#   MAC_OS_AGENT_NOTARY_PROFILE   The notarytool profile name. Defaults to AIMeter.
#   MAC_OS_AGENT_SPARKLE_KEY_FILE A file with the private signing key, instead of the Keychain.
#   MAC_OS_AGENT_PUBLIC_KEY       The public signing key, instead of scripts/sparkle-public-key.txt.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
DRY_RUN=false
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=true
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "usage: scripts/release.sh <version> [--dry-run]   (for example 1.2.0)" >&2
  exit 2
fi

REPO="${MAC_OS_AGENT_RELEASE_REPO:-lubelski/mac-os-agent}"
NOTARY_PROFILE="${MAC_OS_AGENT_NOTARY_PROFILE:-AIMeter}"
TAG="v$VERSION"
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
OUT=build/release
ZIP="$OUT/mac-os-agent-$VERSION.zip"

fail() { echo "error: $*" >&2; exit 1; }

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# --- Checks, before anything is built ---

PUBLIC_KEY="${MAC_OS_AGENT_PUBLIC_KEY:-$(cat scripts/sparkle-public-key.txt 2>/dev/null || true)}"
[[ -n "$PUBLIC_KEY" ]] || fail "no Sparkle public key. See step 3 at the top of this script."

if ! $DRY_RUN; then
  [[ -z "$(git status --porcelain)" ]] || fail "the working tree has uncommitted changes"
  git fetch --quiet origin main --tags
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
    || fail "HEAD is not origin/main. Releases are built from main, so build numbers only grow."
  git rev-parse --quiet --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG already exists"
  security find-identity -v -p codesigning | grep -q "Developer ID Application" \
    || fail "no Developer ID Application certificate in the Keychain"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "no notarytool profile named '$NOTARY_PROFILE'. Run: xcrun notarytool store-credentials $NOTARY_PROFILE"
fi

# --- Build ---

MAC_OS_AGENT_VERSION="$VERSION" \
MAC_OS_AGENT_FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml" \
MAC_OS_AGENT_PUBLIC_KEY="$PUBLIC_KEY" \
  ./scripts/bundle.sh

APP="build/mac-os-agent.app"
rm -rf "$OUT"
mkdir -p "$OUT"

# --- Notarize ---

if $DRY_RUN; then
  echo "Dry run: skipping notarization"
else
  # Apple notarizes an archive, but the ticket is stapled to the app. So zip, submit,
  # staple, and zip again below with the ticket inside.
  ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
  xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  rm "$OUT/notarize.zip"
  xcrun stapler staple "$APP"
  spctl --assess --type execute "$APP"
fi

# --- Feed ---

ditto -c -k --keepParent "$APP" "$ZIP"
KEY_ARGS=()
[[ -n "${MAC_OS_AGENT_SPARKLE_KEY_FILE:-}" ]] && KEY_ARGS=(--ed-key-file "$MAC_OS_AGENT_SPARKLE_KEY_FILE")
"$SPARKLE_BIN/generate_appcast" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link "https://github.com/$REPO" \
  -o "$OUT/appcast.xml" "$OUT"
grep -q 'sparkle:edSignature=' "$OUT/appcast.xml" || fail "the feed has no signature for the update"

if $DRY_RUN; then
  echo "Dry run: built $ZIP and $OUT/appcast.xml, published nothing"
  exit 0
fi

# --- Publish ---

git tag "$TAG"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" "$OUT/appcast.xml" --repo "$REPO" --title "mac-os-agent $VERSION" --generate-notes
echo "Released $TAG. Installed copies pick it up at their next update check."
