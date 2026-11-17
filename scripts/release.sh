#!/bin/zsh
# Builds a release and its update feed: build/release/Aerialist.dmg and build/release/appcast.xml.
# Usage: scripts/release.sh [--test] [release-notes.md]
#
# Set VERSION and BUILD in scripts/app.config first. BUILD must be greater than the published one,
# because the app compares build numbers to decide whether an update is newer; the script checks it.
#
# The disk image and the appcast are signed with the EdDSA key in the login Keychain (Sparkle's
# sign_update, account SPARKLE_KEY_ACCOUNT); macOS may ask to allow Keychain access. The appcast lists
# only this release and points at its disk image on GitHub. Attach both files to the GitHub release, so
# that releases/latest/download/appcast.xml (SUFeedURL) always serves the newest one. Nothing is
# uploaded here.
#
# Optional release notes (Markdown) are embedded in the appcast and shown in the update window.
#
# --test builds an update for a local test feed: it allows VERSION_OVERRIDE, BUILD_OVERRIDE,
# BUNDLE_ID_OVERRIDE, FEED_URL_OVERRIDE (see build-app.sh) and DOWNLOAD_URL_OVERRIDE (the disk image's
# address in the appcast), and skips the checks against GitHub. Without --test these are refused, so a
# leftover variable can't ship an app that reads the wrong feed.
set -euo pipefail

TEST=0
NOTES=""
for arg in "$@"; do
  case "$arg" in
    --test) TEST=1 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) NOTES="${arg:A}" ;;  # absolute, before the cd below
  esac
done
[[ -z "$NOTES" || -f "$NOTES" ]] || { echo "no such release notes file: $NOTES" >&2; exit 2; }

cd "$(dirname "$0")/.."
source scripts/app.config
REPO_URL="https://github.com/eddytwist/aerialist"

OVERRIDES=(${(k)parameters[(I)*_OVERRIDE]})
if [[ "$TEST" == 0 && ${#OVERRIDES} -gt 0 ]]; then
  echo "test overrides are set (${OVERRIDES[*]}); unset them or pass --test" >&2
  exit 2
fi
VERSION="${VERSION_OVERRIDE:-$VERSION}"
BUILD="${BUILD_OVERRIDE:-$BUILD}"
EXPECTED_BUNDLE_ID="${BUNDLE_ID_OVERRIDE:-$BUNDLE_ID}"
EXPECTED_FEED_URL="${FEED_URL_OVERRIDE:-$FEED_URL}"
DOWNLOAD_URL="${DOWNLOAD_URL_OVERRIDE:-${REPO_URL}/releases/download/v${VERSION}/Aerialist.dmg}"

# sign_update and generate_keys ship with the Sparkle package (resolved by swift build).
swift package resolve >/dev/null
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
[[ -x "$SPARKLE_BIN/sign_update" ]] || { echo "sign_update not found in $SPARKLE_BIN" >&2; exit 1; }

# The private key in the Keychain must match the public key the app will carry.
[[ "$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_KEY_ACCOUNT" -p)" == "$SPARKLE_PUBLIC_KEY" ]] \
  || { echo "the Keychain key ($SPARKLE_KEY_ACCOUNT) doesn't match SPARKLE_PUBLIC_KEY in scripts/app.config" >&2; exit 1; }

if [[ "$TEST" == 0 ]]; then
  # A new tag, and a build number above the one users have now.
  if gh release view "v${VERSION}" --repo eddytwist/aerialist >/dev/null 2>&1; then
    echo "release v${VERSION} already exists" >&2; exit 1
  fi
  PUBLISHED="$(curl -fsSL "$FEED_URL" 2>/dev/null | sed -nE 's:.*<sparkle\:version>([0-9]+)</sparkle\:version>.*:\1:p' | head -1 || true)"
  if [[ -n "$PUBLISHED" && "$BUILD" -le "$PUBLISHED" ]]; then
    echo "BUILD $BUILD must be greater than the published build $PUBLISHED" >&2; exit 1
  fi
  echo "published build: ${PUBLISHED:-none (first release with updates)}; this build: $BUILD"
fi

scripts/build-app.sh --universal --dmg

OUT="build/release"
rm -rf "$OUT"
mkdir -p "$OUT"
cp "build/Aerialist-${VERSION}.dmg" "$OUT/Aerialist.dmg"

# Check the app inside the disk image, exactly as users will get it.
MOUNT="$(mktemp -d)"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$OUT/Aerialist.dmg" >/dev/null
PLIST="$MOUNT/${APP_NAME}.app/Contents/Info.plist"
check() {
  local actual
  actual="$(plutil -extract "$1" raw "$PLIST")"
  [[ "$actual" == "$2" ]] || { hdiutil detach "$MOUNT" -quiet; echo "$1 in the built app is '$actual', expected '$2'" >&2; exit 1; }
}
check CFBundleIdentifier "$EXPECTED_BUNDLE_ID"
check CFBundleShortVersionString "$VERSION"
check CFBundleVersion "$BUILD"
check SUFeedURL "$EXPECTED_FEED_URL"
check SUPublicEDKey "$SPARKLE_PUBLIC_KEY"
codesign --verify --strict --deep "$MOUNT/${APP_NAME}.app"
hdiutil detach "$MOUNT" -quiet
rmdir "$MOUNT"

# Prints: sparkle:edSignature="…" length="…"
SIGNATURE="$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_KEY_ACCOUNT" "$OUT/Aerialist.dmg")"
[[ "$SIGNATURE" == sparkle:edSignature=* ]] || { echo "sign_update failed: $SIGNATURE" >&2; exit 1; }

DESCRIPTION=""
if [[ -n "$NOTES" ]]; then
  # CDATA can't contain its own terminator; split it if the notes ever do.
  DESCRIPTION="
      <description sparkle:format=\"markdown\"><![CDATA[$(sed 's/]]>/]]]]><![CDATA[>/g' "$NOTES")]]></description>"
fi

cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>${APP_NAME}</title>
    <link>${REPO_URL}</link>
    <item>
      <title>${APP_NAME} ${VERSION}</title>
      <link>${REPO_URL}/releases/tag/v${VERSION}</link>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>${REPO_URL}/releases</sparkle:fullReleaseNotesLink>${DESCRIPTION}
      <enclosure url="${DOWNLOAD_URL}" ${SIGNATURE} type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$OUT/appcast.xml"
# The app requires a signed feed (SURequireSignedFeed): sign_update embeds the signature in the file.
"$SPARKLE_BIN/sign_update" --account "$SPARKLE_KEY_ACCOUNT" "$OUT/appcast.xml"
"$SPARKLE_BIN/sign_update" --account "$SPARKLE_KEY_ACCOUNT" --verify "$OUT/appcast.xml"

echo
echo "release files: $OUT/Aerialist.dmg, $OUT/appcast.xml (version $VERSION, build $BUILD)"
[[ "$TEST" == 1 ]] && { echo "TEST build: do not publish"; exit 0; }
echo "publish (after review):"
echo "  gh release create v${VERSION} $OUT/Aerialist.dmg $OUT/appcast.xml --title \"${APP_NAME} ${VERSION}\" --notes-file <notes>"
