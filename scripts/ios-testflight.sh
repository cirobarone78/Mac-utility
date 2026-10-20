#!/bin/bash
# Prepara l'app per iPhone e la carica su TestFlight.
# Prima volta: leggi iOS/TESTFLIGHT.md (app da creare su App Store Connect).
# Uso: ./scripts/ios-testflight.sh
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "▸ Installo XcodeGen…"; brew install xcodegen; }

# Team di sviluppo (dal certificato Apple Development, campo OU), salvo indicazione diversa.
if [[ -z "${OMNITOOLS_TEAM:-}" ]]; then
  OMNITOOLS_TEAM=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null | sed -nE 's/.*OU ?= ?([A-Z0-9]{10}).*/\1/p' | head -1 || true)
fi
if [[ -z "$OMNITOOLS_TEAM" ]]; then
  echo "✗ Team non trovato. Avvia così: OMNITOOLS_TEAM=XXXXXXXXXX ./scripts/ios-testflight.sh"
  echo "  (il Team ID è in developer.apple.com › Account › Membership)"
  exit 1
fi
export OMNITOOLS_TEAM
echo "▸ Team: $OMNITOOLS_TEAM"

# Numero di build sempre crescente (TestFlight rifiuta un numero già usato).
BUILD=$(date +%Y%m%d%H%M)
echo "▸ Build numero $BUILD"

(cd iOS && xcodegen generate --quiet)

ARCHIVE=build/ios/OmniTools.xcarchive
rm -rf build/ios && mkdir -p build/ios

echo "▸ Archivio (Release)…"
xcodebuild -project iOS/OmniToolsiOS.xcodeproj -scheme OmniToolsiOS -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$OMNITOOLS_TEAM" CURRENT_PROJECT_VERSION="$BUILD" \
  archive | grep -E "error:|warning: .*signing|ARCHIVE (SUCCEEDED|FAILED)" || true
[[ -d "$ARCHIVE" ]] || { echo "✗ Archivio non riuscito: rilancia senza filtro per vedere l'errore completo"; exit 1; }

cat > build/ios/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>${OMNITOOLS_TEAM}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

echo "▸ Caricamento su App Store Connect…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist build/ios/ExportOptions.plist \
  -exportPath build/ios/export -allowProvisioningUpdates

echo "✓ Caricata la build $BUILD."
echo "  Tra 5-15 minuti compare in App Store Connect › OmniTools › TestFlight;"
echo "  poi arriva sull'iPhone dall'app TestFlight (aggiornamento automatico se attivo)."
