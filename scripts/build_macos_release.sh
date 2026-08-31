#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
project="$repo_root/src/macos/MinisMac.xcodeproj"
artifact_root=${MINIS_MAC_ARTIFACT_DIR:-"$repo_root/.artifacts/macos"}
artifact_root=${artifact_root:A}
derived_data="$artifact_root/DerivedData"
configuration=Release
mode=${1:---unsigned}

if [[ "$mode" != "--unsigned" && "$mode" != "--signed" && "$mode" != "--notarize" ]]; then
  print -u2 "usage: $0 [--unsigned|--signed|--notarize]"
  exit 64
fi

if [[ -z "$artifact_root" || "$artifact_root" == "/" || "$artifact_root" == "$HOME" || "$artifact_root" == "$repo_root" ]]; then
  print -u2 "Refusing unsafe MINIS_MAC_ARTIFACT_DIR: $artifact_root"
  exit 64
fi

mkdir -p "$artifact_root"
rm -rf "$derived_data" "$artifact_root/MinisMac.app" "$artifact_root/MinisMac.zip"

xcodebuild \
  -project "$project" \
  -scheme MinisMac \
  -configuration "$configuration" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data" \
  -quiet \
  build CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO

built_app="$derived_data/Build/Products/$configuration/MinisMac.app"
runtime="$built_app/Contents/Helpers/MinisRuntimeService"
[[ -x "$built_app/Contents/MacOS/MinisMac" && -x "$runtime" ]] || {
  print -u2 "Release build did not contain both the GUI and Runtime helper."
  exit 66
}
ditto "$built_app" "$artifact_root/MinisMac.app"

if [[ "$mode" == "--unsigned" ]]; then
  file "$artifact_root/MinisMac.app/Contents/MacOS/MinisMac" "$artifact_root/MinisMac.app/Contents/Helpers/MinisRuntimeService"
  print "Unsigned release app: $artifact_root/MinisMac.app"
  exit 0
fi

: ${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to the full Developer ID Application identity.}
app="$artifact_root/MinisMac.app"
runtime="$app/Contents/Helpers/MinisRuntimeService"
runtime_entitlements="$repo_root/src/macos/RuntimeService/MinisRuntimeService.entitlements"

# Sign from the inside out. Neither executable needs JIT, unsigned memory nor
# disabled library validation exceptions.
codesign --force --timestamp --options runtime --entitlements "$runtime_entitlements" --sign "$DEVELOPER_ID_APPLICATION" "$runtime"
codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID_APPLICATION" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
spctl --assess --type execute --verbose=2 "$app" || true
ditto -c -k --keepParent "$app" "$artifact_root/MinisMac.zip"

if [[ "$mode" == "--signed" ]]; then
  print "Signed release archive: $artifact_root/MinisMac.zip"
  exit 0
fi

if [[ -n "${NOTARYTOOL_KEYCHAIN_PROFILE:-}" ]]; then
  xcrun notarytool submit "$artifact_root/MinisMac.zip" --keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE" --wait
else
  : ${APPLE_ID:?Set APPLE_ID or use NOTARYTOOL_KEYCHAIN_PROFILE.}
  : ${APPLE_TEAM_ID:?Set APPLE_TEAM_ID or use NOTARYTOOL_KEYCHAIN_PROFILE.}
  : ${APPLE_APP_SPECIFIC_PASSWORD:?Set APPLE_APP_SPECIFIC_PASSWORD or use NOTARYTOOL_KEYCHAIN_PROFILE.}
  xcrun notarytool submit "$artifact_root/MinisMac.zip" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait
fi

xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
rm -f "$artifact_root/MinisMac.zip"
ditto -c -k --keepParent "$app" "$artifact_root/MinisMac.zip"
print "Notarized release archive: $artifact_root/MinisMac.zip"
