#!/bin/zsh
# Builds Bol.app into ./build. Running it needs only Claude Code (the app's setup checks for it).
# Usage: ./build.sh [--install] [--run]
# Bun and Swift are needed to build only: the brain ships as a single compiled executable.
# Env: BOL_VERSION / BOL_BUILD (Info.plist versions; release.sh sets them), BOL_SIGN_IDENTITY (a "Developer ID
# Application: …" identity: signs with the hardened runtime for notarization; without it, local signing),
# BOL_UNIVERSAL=1 (arm64 + x86_64 app and brain, as release.sh builds; default: this Mac's architecture only).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
APP="$ROOT/build/Bol.app"
BRAIN="$ROOT/build/brain"
VERSION="${BOL_VERSION:-0.1.0}"
BUILD="${BOL_BUILD:-1}"

echo "→ Installing brain dependencies"
bun install --frozen-lockfile --silent

ARCHS=("$(uname -m)")
[[ "${BOL_UNIVERSAL:-0}" == 1 ]] && ARCHS=(arm64 x86_64)

echo "→ Compiling brain (single executable: ${ARCHS[*]})"
bun check src/typescript/index.ts
rm -rf "$BRAIN"; mkdir -p "$BRAIN"
SLICES=()
for ARCH in "${ARCHS[@]}"; do
  TARGET="bun-darwin-${ARCH/x86_64/x64}"
  bun build src/typescript/index.ts --compile --minify --target="$TARGET" --outfile "$BRAIN/bol-brain-$ARCH" >/dev/null
  SLICES+=("$BRAIN/bol-brain-$ARCH")
done
lipo -create "${SLICES[@]}" -output "$BRAIN/bol-brain"

echo "→ Compiling Swift (${ARCHS[*]})"
# One build per architecture (a multi-arch `swift build` needs full Xcode), merged with lipo. Fails on compile
# errors rather than packaging a previous build's binary.
SLICES=()
for ARCH in "${ARCHS[@]}"; do
  TRIPLE=(--triple "$ARCH-apple-macosx13.0")
  if ! SWIFT_LOG="$(swift build -c release "${TRIPLE[@]}" 2>&1)"; then
    print -r -- "$SWIFT_LOG" | grep -E "error:" | sort -u
    echo "✘ Swift build failed ($ARCH)"
    exit 1
  fi
  SLICES+=("$(swift build -c release "${TRIPLE[@]}" --show-bin-path)/Bol")
done
BIN="$ROOT/build/Bol"
lipo -create "${SLICES[@]}" -output "$BIN"

echo "→ Rendering app icon"
ICONSET="$(mktemp -d)/bol.iconset"; mkdir -p "$ICONSET"
swift assets/make-icon.swift "$ICONSET/icon_1024.png" >/dev/null
for size in 16 32 128 256 512; do
  sips -z $size $size "$ICONSET/icon_1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size*2)) $((size*2)) "$ICONSET/icon_1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
rm "$ICONSET/icon_1024.png"

echo "→ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/brain"
cp "$BIN" "$APP/Contents/MacOS/Bol"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/bol.icns"
cp "$BRAIN/bol-brain" "$APP/Contents/Resources/brain/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Bol</string>
  <key>CFBundleDisplayName</key><string>Bol</string>
  <key>CFBundleIdentifier</key><string>com.snktcodes.bol</string>
  <key>CFBundleExecutable</key><string>Bol</string>
  <key>CFBundleIconFile</key><string>bol</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Bol listens to your voice when you press ⌘J.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Bol turns other apps' sound down while you talk to it and while it speaks.</string>
  <key>NSAppleEventsUsageDescription</key><string>Bol controls other apps on your behalf when you ask it to.</string>
</dict>
</plist>
PLIST

# macOS ties privacy grants (mic, Accessibility, Screen Recording…) to the bundle id and signature. Local builds
# sign with a stable self-signed identity so grants survive rebuilds: BOL_LOCAL_IDENTITY (default "Bol Local
# Signing"), else ad-hoc. Nested executables are signed first, then the app.
if [[ -n "${BOL_SIGN_IDENTITY:-}" ]]; then
  echo "→ Signing with $BOL_SIGN_IDENTITY (hardened runtime)"
  SIGN=(--force --sign "$BOL_SIGN_IDENTITY" --options runtime --timestamp)
  codesign "${SIGN[@]}" --entitlements assets/entitlements/brain.entitlements \
    "$APP/Contents/Resources/brain/bol-brain" >/dev/null
  codesign "${SIGN[@]}" --entitlements assets/entitlements/bol.entitlements \
    --identifier com.snktcodes.bol "$APP" >/dev/null
  codesign --verify --deep --strict "$APP"
else
  NAME="${BOL_LOCAL_IDENTITY:-Bol Local Signing}"
  IDENTITY="$(security find-identity -p codesigning 2>/dev/null | awk -v n="\"$NAME\"" 'index($0, n) {print $2; exit}')"
  if [[ -n "$IDENTITY" ]]; then echo "→ Signing with $NAME"; else echo "→ Signing (ad-hoc; permissions may reset after rebuilds)"; fi
  SIGN=(--force --sign "${IDENTITY:--}")
  codesign "${SIGN[@]}" "$APP/Contents/Resources/brain/bol-brain" >/dev/null
  codesign "${SIGN[@]}" --identifier com.snktcodes.bol "$APP" >/dev/null
fi

DEST="$APP"
if [[ " $* " == *" --install "* ]]; then
  pkill -x Bol 2>/dev/null || true
  rm -rf "/Applications/Bol.app"
  cp -R "$APP" /Applications/
  DEST="/Applications/Bol.app"
  echo "→ Installed to $DEST"
fi
if [[ " $* " == *" --run "* ]]; then
  pkill -x Bol 2>/dev/null || true
  open "$DEST"
  echo "→ Launched"
fi
echo "✓ Done: $DEST ($(du -sh "$APP" | cut -f1))"
