#!/usr/bin/env bash
set -euo pipefail

preview_root="$RUNNER_TEMP/cinescout-liquid-glass"
screenshots="$1"
mkdir -p "$preview_root" "$screenshots"
cp -R CineScout project.yml "$preview_root/"
sed -i '' '/^@main$/d' "$preview_root/CineScout/CineScoutApp.swift"
cp Checks/LiquidGlassPreview.swift "$preview_root/CineScout/"

device=$(xcrun simctl list devices available -j | jq -r '
  [.devices | to_entries[] | select(.key | contains("iOS-26"))
    | .value[] | select(.name == "iPhone 17 Pro") | .udid] | last // empty
')
test -n "$device"
xcrun simctl boot "$device"

cd "$preview_root"
xcodegen generate
xcodebuild -project CineScout.xcodeproj -scheme CineScout -configuration Debug \
  -sdk iphonesimulator -destination "generic/platform=iOS Simulator" -derivedDataPath build \
  ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" build/Build/Products/Debug-iphonesimulator/CineScout.app
xcrun simctl status_bar "$device" override --time 9:41 --dataNetwork wifi --wifiMode active \
  --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100

xcrun simctl ui "$device" appearance light
xcrun simctl launch "$device" com.akarukasu.cinescout
sleep 6
xcrun simctl io "$device" screenshot "$screenshots/Decouvrir-clair.png"
xcrun simctl ui "$device" appearance dark
sleep 2
xcrun simctl io "$device" screenshot "$screenshots/Decouvrir-sombre.png"
xcrun simctl terminate "$device" com.akarukasu.cinescout
xcrun simctl launch "$device" com.akarukasu.cinescout --detail
sleep 6
xcrun simctl io "$device" screenshot "$screenshots/Fiche-sombre.png"
xcrun simctl terminate "$device" com.akarukasu.cinescout
xcrun simctl launch "$device" com.akarukasu.cinescout --catalog-search
sleep 3
xcrun simctl io "$device" screenshot "$screenshots/Recherche-sombre.png"
xcrun simctl terminate "$device" com.akarukasu.cinescout
xcrun simctl launch "$device" com.akarukasu.cinescout --classics
sleep 4
xcrun simctl io "$device" screenshot "$screenshots/A-redecouvrir-sombre.png"
xcrun simctl terminate "$device" com.akarukasu.cinescout
xcrun simctl launch "$device" com.akarukasu.cinescout --roulette
sleep 3
xcrun simctl io "$device" screenshot "$screenshots/Roulette-sombre.png"
