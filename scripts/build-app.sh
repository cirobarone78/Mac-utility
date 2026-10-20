#!/bin/bash
# Crea OmniTools.app (e con --install la copia in /Applications).
# Uso:  ./scripts/build-app.sh            → build/OmniTools.app
#       ./scripts/build-app.sh --install  → anche /Applications/OmniTools.app
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/OmniTools.app
VERSION=$(git describe --tags --always 2>/dev/null || echo "0.3")

echo "▸ Compilo (release)…"
swift build -c release
BIN=$(swift build -c release --show-bin-path)

echo "▸ Preparo ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/OmniTools" "$APP/Contents/MacOS/OmniTools"
cp -R "$BIN/OmniTools_OmniTools.bundle" "$APP/Contents/Resources/"
iconutil -c icns Assets/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>OmniTools</string>
  <key>CFBundleDisplayName</key><string>OmniTools</string>
  <key>CFBundleIdentifier</key><string>app.omnitools.mac</string>
  <key>CFBundleExecutable</key><string>OmniTools</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>OmniTools</string>
</dict>
</plist>
PLIST

echo "▸ Firma locale (ad-hoc)…"
codesign --force --deep --sign - "$APP"

if [[ "${1:-}" == "--install" ]]; then
  echo "▸ Installo in /Applications…"
  osascript -e 'quit app "OmniTools"' 2>/dev/null || true
  # Aspetta che la versione vecchia sia davvero chiusa (al massimo 10 secondi), poi la chiude a forza.
  for _ in $(seq 1 20); do pgrep -x OmniTools >/dev/null || break; sleep 0.5; done
  pkill -x OmniTools 2>/dev/null || true
  rm -rf /Applications/OmniTools.app
  cp -R "$APP" /Applications/
  # Registra la nuova copia presso macOS e aprila (con un secondo tentativo).
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/OmniTools.app 2>/dev/null || true
  sleep 1
  open /Applications/OmniTools.app 2>/dev/null || { sleep 2; open /Applications/OmniTools.app; }
  echo "✓ Installata: /Applications/OmniTools.app"
else
  echo "✓ Pronta: ${APP}  (per installarla: ./scripts/build-app.sh --install)"
fi
