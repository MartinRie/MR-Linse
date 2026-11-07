#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$(dirname "$ROOT")/MR-Linse.app"
cd "$ROOT"
VERSION="$(cat "$ROOT/VERSION")"
export MR_APP_VERSION="$VERSION"
export MR_UPDATE_REPOSITORY="${MR_UPDATE_REPOSITORY:-${GITHUB_REPOSITORY:-}}"
python3 - <<'PYVALIDATE'
import os, re
assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", os.environ['MR_APP_VERSION']), 'VERSION must be x.y.z'
repo = os.environ['MR_UPDATE_REPOSITORY']
assert not repo or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*", repo), 'Invalid update repository'
PYVALIDATE
swift build -c release
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/.build/release/SoulearLupe" "$APP/Contents/MacOS/SoulearLupe"
FLASH="$APP/Contents/Resources/C3"
mkdir -p "$FLASH"
cp "$ROOT/Artwork/Linsli.icns" "$APP/Contents/Resources/Linsli.icns"
cp "$ROOT/FlashResources/"* "$FLASH/"
cp "$ROOT/C3-Bruecke/.pio/build/supermini/"{bootloader,partitions,firmware}.bin "$FLASH/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SoulearLupe</string>
<key>CFBundleIdentifier</key><string>de.martin.soulear-lupe</string>
<key>CFBundleIconFile</key><string>Linsli.icns</string>
<key>CFBundleName</key><string>MR-Linse</string>
<key>CFBundleDisplayName</key><string>MR-Linse</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>MR-Linse greift lokal auf den Videostream deiner Soulear-Kamera zu.</string>
</dict></plist>
PLIST
MR_APP_PLIST="$APP/Contents/Info.plist" python3 - <<'PYPLIST'
import os, plistlib
path = os.environ['MR_APP_PLIST']
with open(path, 'rb') as f:
    info = plistlib.load(f)
info['CFBundleShortVersionString'] = os.environ['MR_APP_VERSION']
info['CFBundleVersion'] = os.environ['MR_APP_VERSION']
info['MRUpdateRepository'] = os.environ['MR_UPDATE_REPOSITORY']
with open(path, 'wb') as f:
    plistlib.dump(info, f)
PYPLIST
printf 'App gebaut: %s\n' "$APP"
