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

mkdir -p dist
package_dir="$(mktemp -d "$project_root/dist/ipa-stage.XXXXXX")"
trap 'rm -rf "$package_dir"' EXIT
mkdir -p "$package_dir/Payload"
/usr/bin/ditto "$app_path" "$package_dir/Payload/YandexFinance.app"
ipa_path="$project_root/dist/YandexFinance-unsigned.ipa"
rm -f "$ipa_path"
(
  cd "$package_dir"
  /usr/bin/zip -qr "$ipa_path" Payload
)
/usr/bin/unzip -t "$ipa_path"
echo 'IPA packaged. Install by signing locally with AltStore; direct installation is not supported.'
