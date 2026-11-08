#!/bin/bash
# Baut die App und startet sie im eigenen Test-Simulator, angemeldet per Startumgebung (kein Passwort-Tippen).
# Zugang aus einer gitignorten Datei: NOTES_SERVER=…, NOTES_USER=…, NOTES_PASSWORD=… (z. B. .test-account)
#   ./sim-run.sh [.test-account]   – Simulator-UDID in .sim-udid (xcrun simctl create "HomeNotes Test" "iPhone 17 Pro Max")
set -euo pipefail
cd "$(dirname "$0")"
ACCOUNT="${1:-.test-account}"
UDID="$(cat .sim-udid)"
set -a; . "$ACCOUNT"; set +a
xcodegen generate -q
xcodebuild -project HomeNotes.xcodeproj -scheme HomeNotes -destination "id=$UDID" -derivedDataPath build -quiet build 2>&1 \
  | grep -E "error:" || true
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl install "$UDID" build/Build/Products/Debug-iphonesimulator/HomeNotes.app
SIMCTL_CHILD_NOTES_SERVER="$NOTES_SERVER" SIMCTL_CHILD_NOTES_USER="$NOTES_USER" SIMCTL_CHILD_NOTES_PASSWORD="$NOTES_PASSWORD" \
  xcrun simctl launch --terminate-running-process "$UDID" org.homeroll.notes >/dev/null
echo "gestartet"
