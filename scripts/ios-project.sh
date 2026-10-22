#!/bin/bash
# Genera il progetto Xcode dell'app per iPhone e lo apre.
# Uso: ./scripts/ios-project.sh
set -euo pipefail
cd "$(dirname "$0")/../iOS"

if ! command -v xcodegen >/dev/null; then
  echo "▸ Installo XcodeGen (una volta sola)…"
  brew install xcodegen
fi

# Il "Team" per firmare l'app: lo ricava dal tuo certificato Apple Development (campo OU).
if [[ -z "${OMNITOOLS_TEAM:-}" ]]; then
  OMNITOOLS_TEAM=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null | sed -nE 's/.*OU ?= ?([A-Z0-9]{10}).*/\1/p' | head -1 || true)
fi
export OMNITOOLS_TEAM
if [[ -n "$OMNITOOLS_TEAM" ]]; then
  echo "▸ Team di sviluppo: $OMNITOOLS_TEAM"
else
  echo "▸ Team non trovato: sceglilo in Xcode (target OmniToolsiOS › Signing & Capabilities › Team)."
fi

xcodegen generate
open OmniToolsiOS.xcodeproj
echo "✓ In Xcode: collega l'iPhone, sceglilo in alto come destinazione e premi ⌘R."
