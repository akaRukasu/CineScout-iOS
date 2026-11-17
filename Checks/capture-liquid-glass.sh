#!/usr/bin/env bash
set -euo pipefail

preview_root="$RUNNER_TEMP/cinescout-liquid-glass"
screenshots="$1"
mkdir -p "$preview_root" "$screenshots"
swiftc Checks/CheckScreenshot.swift -o "$preview_root/check-screenshot"
cp -R CineScout project.yml "$preview_root/"
sed -i '' '/^@main$/d' "$preview_root/CineScout/CineScoutApp.swift"
cp Checks/LiquidGlassPreview.swift "$preview_root/CineScout/"

device=$(xcrun simctl list devices available -j | jq -r '
  [.devices | to_entries[] | select(.key | contains("iOS-26"))
    | .value[] | select(.name == "iPhone 17 Pro") | .udid] | last // empty
')
test -n "$device"
trap 'xcrun simctl spawn "$device" log show --last 8m --style compact --predicate '\''process == "CineScout"'\'' > "$screenshots/simulator.log" 2>&1 || true
find "$HOME/Library/Logs/DiagnosticReports" -name "CineScout*" -exec cp {} "$screenshots/" \; 2>/dev/null || true' EXIT
xcrun simctl boot "$device"

cd "$preview_root"
xcodegen generate
xcodebuild -project CineScout.xcodeproj -scheme CineScout -configuration Debug \
  -sdk iphonesimulator -destination "generic/platform=iOS Simulator" -derivedDataPath build \
  ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
xcrun simctl bootstatus "$device" -b

preview_app=build/Build/Products/Debug-iphonesimulator/CineScout.app
xcrun simctl install "$device" "$preview_app"
xcrun simctl status_bar "$device" override --time 9:41 --dataNetwork wifi --wifiMode active \
  --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100

capture() {
  local path="$screenshots/$1"
  for attempt in 1 2 3 4; do
    xcrun simctl io "$device" screenshot "$path"
    if "$preview_root/check-screenshot" "$path"; then return 0; fi
    sleep 5
  done
  echo "The simulator did not render $1."
  return 1
}

xcrun simctl ui "$device" appearance light
xcrun simctl launch "$device" com.akarukasu.cinescout
sleep 8
capture Decouvrir-clair.png

xcrun simctl terminate "$device" com.akarukasu.cinescout
xcrun simctl ui "$device" appearance dark
xcrun simctl launch "$device" com.akarukasu.cinescout
sleep 8
capture Decouvrir-sombre.png

for screen in detail catalog-search classics roulette; do
  xcrun simctl terminate "$device" com.akarukasu.cinescout
  xcrun simctl launch "$device" com.akarukasu.cinescout "--$screen"
  sleep 8
  capture "$screen.png"
done

xcrun simctl terminate "$device" com.akarukasu.cinescout
app_container=$(xcrun simctl get_app_container "$device" com.akarukasu.cinescout data)
mkdir -p "$app_container/Documents"
rm -f "$app_container/Documents/roulette-start"
xcrun simctl launch "$device" com.akarukasu.cinescout --roulette-motion
sleep 8
capture Roulette-prete.png

xcrun simctl io "$device" recordVideo --codec=h264 "$screenshots/Roulette-animation.mp4" &
recorder=$!
sleep 1
touch "$app_container/Documents/roulette-start"
sleep 2
capture Roulette-animation.png
sleep 5
capture Roulette-resultats.png
kill -INT "$recorder"
wait "$recorder"
