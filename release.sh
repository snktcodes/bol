#!/bin/zsh
# Publishes a release: builds Bol.app signed with Developer ID, notarizes and staples it, wraps it in a signed,
# notarized DMG, uploads that to R2 ($BOL_R2_BUCKET, served at $BOL_DOWNLOAD_HOST), then points $BOL_SITE/latest.json
# (the feed Bol's update checker polls) and $BOL_SITE/download at it.
#
# Usage: ./release.sh <version> <build> ["release notes"]      e.g. ./release.sh 0.2.0 2 "Faster replies."
#
# One-time setup:
#   - Apple Developer Program; a "Developer ID Application" certificate in the login keychain.
#   - export BOL_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   - xcrun notarytool store-credentials bol-notary --apple-id <id> --team-id <TEAMID> --password <app-specific>
#     (or set BOL_NOTARY_PROFILE to another profile name)
#   - Your own site and download host (website/ deployed to it as a Cloudflare Worker, an R2 bucket behind the host):
#     export BOL_SITE=example.com BOL_DOWNLOAD_HOST=https://dl.example.com BOL_R2_BUCKET=bol-releases
#   - cf signed in to the account that holds $BOL_SITE (cf auth login)
#   - Constants.updateFeedURL set to https://$BOL_SITE/latest.json (it's nil, updates off, until you do)
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"

VERSION="${1:-}"
BUILD="${2:-}"
NOTES="${3:-}"
PROFILE="${BOL_NOTARY_PROFILE:-bol-notary}"
SITE="${BOL_SITE:-}"
BUCKET="${BOL_R2_BUCKET:-}"
DOWNLOAD_HOST="${BOL_DOWNLOAD_HOST:-}"
FEED="$ROOT/website/public/latest.json"
REDIRECTS="$ROOT/website/public/_redirects"

die() { echo "✘ $*" >&2; exit 1; }
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || die "usage: ./release.sh <version x.y.z> <build> [notes]"
[[ "$BUILD" =~ '^[0-9]+$' ]] || die "build must be an integer"
[[ -n "$SITE" && -n "$BUCKET" && -n "$DOWNLOAD_HOST" ]] || die "set BOL_SITE, BOL_DOWNLOAD_HOST and BOL_R2_BUCKET"
grep -q "updateFeedURL: URL? = URL(string: \"https://$SITE/latest.json\")" src/swift/app/constants.swift \
  || die "set Constants.updateFeedURL to https://$SITE/latest.json first, or the release can't update itself"
[[ -n "${BOL_SIGN_IDENTITY:-}" ]] || die "set BOL_SIGN_IDENTITY to your Developer ID Application identity"
security find-identity -p codesigning -v | grep -qF "$BOL_SIGN_IDENTITY" || die "identity not in keychain"
CURRENT_BUILD="$(bun -e "console.log(JSON.parse(await Bun.file('$FEED').text()).build)")"
(( BUILD > CURRENT_BUILD )) || die "build $BUILD must be above the published build $CURRENT_BUILD"

DMG_NAME="Bol-$VERSION.dmg"
DMG="$ROOT/build/$DMG_NAME"
APP="$ROOT/build/Bol.app"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BOL_UNIVERSAL=1 BOL_VERSION="$VERSION" BOL_BUILD="$BUILD" ./build.sh

echo "→ Notarizing Bol.app"
ditto -c -k --keepParent "$APP" "$WORK/Bol.zip"
xcrun notarytool submit "$WORK/Bol.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

echo "→ Building $DMG_NAME"
# dmgbuild lays out the window (background, icon positions, no toolbar) without scripting Finder.
# It lives in its own pinned environment under build/, made on first use.
DMGBUILD="$ROOT/build/dmg-venv/bin/dmgbuild"
if [[ ! -x "$DMGBUILD" ]]; then
  python3 -m venv "$ROOT/build/dmg-venv"
  "$ROOT/build/dmg-venv/bin/pip" install -q --disable-pip-version-check \
    dmgbuild==1.6.5 ds-store==1.3.1 mac-alias==2.2.2
fi
rm -f "$DMG"
"$DMGBUILD" -s assets/dmg/settings.py -D app="$APP" -D background=assets/dmg/background.tiff Bol "$DMG" >/dev/null 2>&1 \
  || die "dmgbuild failed (eject any mounted \"Bol\" disk and try again)"
codesign --force --sign "$BOL_SIGN_IDENTITY" --timestamp "$DMG"

echo "→ Notarizing $DMG_NAME"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

SHA256="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
URL="$DOWNLOAD_HOST/$DMG_NAME"

echo "→ Uploading to R2 ($BUCKET/$DMG_NAME)"
cf r2 objects put "$DMG_NAME" --bucket-name "$BUCKET" --file "$DMG" \
  --content-type application/x-apple-diskimage -q >/dev/null
# The edge may hold an earlier response for this URL (e.g. a 404 from before the upload): drop it, then check
# that what people actually download is this DMG, byte for byte.
cf cache purge -z "$SITE" --force --body "{\"files\":[\"$URL\"]}" >/dev/null
curl -sfL "$URL" -o "$WORK/check.dmg" || die "$URL isn't downloadable after upload"
[[ "$(shasum -a 256 "$WORK/check.dmg" | cut -d' ' -f1)" == "$SHA256" ]] || die "$URL doesn't serve the uploaded DMG"

echo "→ Publishing the update feed"
VERSION="$VERSION" BUILD="$BUILD" URL="$URL" SHA256="$SHA256" NOTES="$NOTES" FEED="$FEED" bun -e '
const env = process.env
const feed = {
	version: env.VERSION,
	build: Number(env.BUILD),
	url: env.URL,
	sha256: env.SHA256,
	minimumSystemVersion: "13.0",
	releasedAt: new Date().toISOString(),
	notes: env.NOTES ?? "",
}
await Bun.write(env.FEED, JSON.stringify(feed, null, "\t") + "\n")
'
printf '/download %s 302\n' "$URL" > "$REDIRECTS"
website/deploy.sh "Release $VERSION ($BUILD)"
# A deploy takes a few seconds to reach every edge: wait for the feed and /download to show this release.
for attempt in {1..24}; do
  FEED_OK=0; DOWNLOAD_OK=0
  curl -sf "https://$SITE/latest.json?v=$BUILD-$attempt" | grep -q "\"build\": $BUILD" && FEED_OK=1
  [[ "$(curl -s -o /dev/null -w '%{redirect_url}' "https://$SITE/download?v=$BUILD-$attempt")" == "$URL"* ]] && DOWNLOAD_OK=1
  (( FEED_OK && DOWNLOAD_OK )) && break
  sleep 5
done
(( FEED_OK )) || die "the live feed doesn't show build $BUILD after 2 minutes"
(( DOWNLOAD_OK )) || die "$SITE/download doesn't point at $URL after 2 minutes"

echo "✓ Released Bol $VERSION ($BUILD): $URL"
echo "  sha256 $SHA256"
echo "  Tag it: git tag v$VERSION && git push origin v$VERSION"
