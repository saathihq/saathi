#!/usr/bin/env bash
#
# Builds, signs, notarizes and staples Saathi.app.
#
#   scripts/release.sh                 signed with Developer ID, notarized, stapled
#   scripts/release.sh --no-notarize   signed only (~30 s instead of a few minutes)
#   scripts/release.sh --adhoc         no identity at all; runs on this Mac only
#
# ── Why there is an .app bundle around a command-line tool ────────────────────
# Because a command-line executable has no main bundle, and macOS will not let a process ask for
# the microphone or for speech recognition unless the usage-description strings are in its main
# bundle. Probed on the loose binary: `main bundle id: none`, both usage strings `ABSENT`. The
# chain voice lane is the DEFAULT lane — the one that needs no key — so shipping the bare binary
# would have produced something notarized that still could not listen.
#
# The bundle is therefore about identity and permissions, not about a user interface: LSUIElement
# is true, there is no window, and you run it as
#
#   /Applications/Saathi.app/Contents/MacOS/saathi voice --listen
#
# ── One honest limitation ────────────────────────────────────────────────────
# TCC attributes a permission prompt to the RESPONSIBLE process. A binary started from a terminal
# is a child of that terminal, so the grant can land on the terminal rather than on Saathi. The
# bundle fixes identity, usage strings and distribution — it does not by itself fix attribution for
# terminal-launched processes. `open -a Saathi` goes through LaunchServices instead and attributes
# correctly. The real fix is the menu-bar shell, which is a product decision and not this script's.
#
# ── Credentials ──────────────────────────────────────────────────────────────
# Notarization uses a keychain profile so no key file is needed at build time, and nothing secret
# is ever read from the repository. Create it once:
#
#   xcrun notarytool store-credentials "saathi-notary" \
#     --key ~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8 \
#     --key-id XXXXXXXXXX --issuer <issuer-uuid>
#
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PACKAGE_DIR"

TEAM_ID="${SAATHI_TEAM_ID:-3U4384584Z}"
SIGN_IDENTITY="${SAATHI_SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${SAATHI_NOTARY_PROFILE:-saathi-notary}"
BUNDLE_ID="dev.saathi.Saathi"

NOTARIZE=1
for argument in "$@"; do
  case "$argument" in
    --no-notarize) NOTARIZE=0 ;;
    --adhoc)       SIGN_IDENTITY="-"; NOTARIZE=0 ;;
    -h|--help)     sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown option: $argument" >&2; exit 2 ;;
  esac
done

# The contract version is the product version: it is the thing the clients and the backend agree
# on, so a build is meaningfully identified by it rather than by a number kept somewhere else.
VERSION="$(node -p "require('$PACKAGE_DIR/../../contract/schema/saathi.json').version" 2>/dev/null || echo "0.0.0")"
BUILD_NUMBER="$(git -C "$PACKAGE_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"
COMMIT="$(git -C "$PACKAGE_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"

DIST="$PACKAGE_DIR/dist"
APP="$DIST/Saathi.app"
ZIP="$DIST/Saathi-$VERSION.zip"

echo "▸ Saathi $VERSION (build $BUILD_NUMBER, $COMMIT)"
echo "  identity: $SIGN_IDENTITY${SIGN_IDENTITY:+ }${TEAM_ID}"

# ── build ────────────────────────────────────────────────────────────────────
# Universal, so the same download works on an Intel Mac. Cheap here and impossible to add later
# without re-notarizing, which is the kind of thing that is worth doing once at the start.
echo "▸ building universal (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64 >/dev/null
BINARY="$PACKAGE_DIR/.build/apple/Products/Release/saathi"
[[ -f "$BINARY" ]] || { echo "build produced no binary at $BINARY" >&2; exit 1; }

# ── assemble ─────────────────────────────────────────────────────────────────
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/saathi"

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
  "$PACKAGE_DIR/Resources/Info.plist" > "$APP/Contents/Info.plist"

# Fail loudly if the placeholders did not get replaced: a bundle whose CFBundleVersion is the
# literal string "__BUILD__" installs perfectly well and is then impossible to tell apart from
# every other build.
if grep -q "__VERSION__\|__BUILD__" "$APP/Contents/Info.plist"; then
  echo "Info.plist still contains placeholders" >&2; exit 1
fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# ── sign ─────────────────────────────────────────────────────────────────────
# `--options runtime` is the hardened runtime, which notarization requires. `--timestamp` needs
# Apple's timestamp server, which fails often enough under a flaky connection that retrying is
# worth more than the three lines it costs — an unsigned-but-"successful" build is worse.
sign() {
  local attempt
  for attempt in 1 2 3; do
    if codesign --force --options runtime --timestamp \
        --entitlements "$PACKAGE_DIR/Resources/Saathi.entitlements" \
        --sign "$SIGN_IDENTITY" "$@"; then
      return 0
    fi
    echo "  codesign failed (attempt $attempt); retrying in 5 s" >&2
    sleep 5
  done
  return 1
}

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "▸ signing ad-hoc (this Mac only, not distributable)"
  codesign --force --sign - --entitlements "$PACKAGE_DIR/Resources/Saathi.entitlements" "$APP"
else
  echo "▸ signing"
  sign "$APP"
fi

codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
codesign -dvv "$APP" 2>&1 | grep -E '^(Authority|TeamIdentifier|Identifier)=' | sed 's/^/    /'

# The check that actually matters for a user: would Gatekeeper let this run on a Mac that has
# never seen it? Before notarization it says "rejected"; after stapling it says "accepted".
gatekeeper() {
  echo "▸ gatekeeper assessment"
  spctl --assess --type execute --verbose=4 "$APP" 2>&1 | sed 's/^/    /' || true
}

# ── notarize ─────────────────────────────────────────────────────────────────
if [[ $NOTARIZE -eq 1 ]]; then
  echo "▸ notarizing (a few minutes)"
  rm -f "$ZIP"
  # ditto rather than `zip`: it preserves the bundle's symlinks and extended attributes, and a
  # zip that loses them is rejected by the notary service with a message that does not say so.
  /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

  if ! xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | sed 's/^/    /'; then
    echo "notarization failed. For the reason:" >&2
    echo "  xcrun notarytool history --keychain-profile \"$NOTARY_PROFILE\"" >&2
    echo "  xcrun notarytool log <submission-id> --keychain-profile \"$NOTARY_PROFILE\"" >&2
    exit 1
  fi

  # Staple the .app, then re-zip. Stapling the zip would do nothing: the ticket has to be attached
  # to the bundle a user ends up with, or their Mac has to reach Apple to launch it offline.
  xcrun stapler staple "$APP" | sed 's/^/    /'
  xcrun stapler validate "$APP" | sed 's/^/    /'
  rm -f "$ZIP"
  /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
  gatekeeper
  echo "▸ notarized and stapled"
else
  gatekeeper
  rm -f "$ZIP"
  /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
fi

SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

echo
echo "  app     $APP"
echo "  zip     $ZIP  ($(du -h "$ZIP" | cut -f1))"
# Printed because the Homebrew cask pins it. A cask whose sha256 does not match the release refuses
# to install with a checksum error, which is the correct behaviour and a confusing thing to debug
# if the number had to be recomputed by hand each time.
echo "  sha256  $SHA"
echo
echo "  try it:  \"$APP/Contents/MacOS/saathi\" voice"
echo
echo "  release: gh release create v$VERSION \"$ZIP\" --repo saathihq/saathi"
echo "           then set version + sha256 in the tap's Casks/saathi.rb"
