#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

xcodebuild -version
xcodebuild \
  -project YandexFinance.xcodeproj \
  -scheme YandexFinance \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath .build-ios \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  build

app_path="$project_root/.build-ios/Build/Products/Release-iphoneos/YandexFinance.app"
test -d "$app_path"
test -f "$app_path/Info.plist"
test -f "$app_path/YandexFinance"
widget_path="$app_path/PlugIns/HorizonWidget.appex"
test -f "$widget_path/HorizonWidget"
test "$(/usr/bin/plutil -extract NSExtension.NSExtensionPointIdentifier raw "$widget_path/Info.plist")" = com.apple.widgetkit-extension
test "$(/usr/bin/plutil -extract CFBundleVersion raw "$widget_path/Info.plist")" = "$(/usr/bin/plutil -extract CFBundleVersion raw "$app_path/Info.plist")"

mkdir -p dist
package_dir="$(mktemp -d "$project_root/dist/ipa-stage.XXXXXX")"
trap 'rm -rf "$package_dir"' EXIT
mkdir -p "$package_dir/Payload"
/usr/bin/ditto "$app_path" "$package_dir/Payload/YandexFinance.app"
# The build is unsigned, so the App Group would be lost: SideStore reads entitlements from the binaries.
# An ad-hoc signature carries them (the widget first, the app last); SideStore re-signs both on the phone.
staged_app="$package_dir/Payload/YandexFinance.app"
/usr/bin/codesign --force --sign - --timestamp=none --entitlements HorizonWidget/HorizonWidget.entitlements "$staged_app/PlugIns/HorizonWidget.appex"
/usr/bin/codesign --force --sign - --timestamp=none --entitlements YandexFinance/YandexFinance.entitlements "$staged_app"
for bundle in "$staged_app/PlugIns/HorizonWidget.appex" "$staged_app"; do
  entitlements="$(/usr/bin/codesign -d --entitlements - --xml "$bundle" 2>/dev/null)"
  grep -q 'group.com.example.YandexFinancePrototype' <<<"$entitlements" || { echo "App Group missing in $bundle"; exit 1; }
done
/usr/bin/codesign --verify --deep "$staged_app"
ipa_path="$project_root/dist/YandexFinance-unsigned.ipa"
rm -f "$ipa_path"
(
  cd "$package_dir"
  /usr/bin/zip -qr "$ipa_path" Payload
)
/usr/bin/unzip -t "$ipa_path"
echo 'IPA packaged. Install by signing locally with AltStore; direct installation is not supported.'
