#!/bin/sh
# Archives Time Breaker for the Mac App Store, then exports a signed installer package or uploads
# it to App Store Connect. Requires a paid Apple Developer Program team; a Personal Team can't
# distribute. See docs/app-store-release.md.
#
#   TEAM_ID=ABCDE12345 scripts/archive-app-store.sh          # build/AppStore/Export/TimeBreaker.pkg
#   TEAM_ID=ABCDE12345 scripts/archive-app-store.sh upload   # upload to App Store Connect
#
# Every upload needs a new build number: set BUILD_NUMBER, or raise CURRENT_PROJECT_VERSION.
set -eu

destination=${1:-export}
case $destination in
export | upload) ;;
*)
    echo "usage: TEAM_ID=<team ID> $0 [export|upload]" >&2
    exit 64
    ;;
esac
: "${TEAM_ID:?Set TEAM_ID to your paid team ID, shown in Xcode > Settings > Accounts.}"

root=$(cd "$(dirname "$0")/.." && pwd)
output=$root/build/AppStore
archive=$output/TimeBreaker.xcarchive
options=$output/ExportOptions.plist

rm -rf "$output"
mkdir -p "$output"

# The project signs to run locally so it builds without a team; archives use the paid team.
set -- DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development"
if [ -n "${BUILD_NUMBER:-}" ]; then
    set -- "$@" CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
fi

xcodebuild -project "$root/TimeBreaker.xcodeproj" -scheme TimeBreaker -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$archive" \
    -allowProvisioningUpdates "$@" archive

cat >"$options" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>destination</key>
	<string>$destination</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>method</key>
	<string>app-store-connect</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
EOF

xcodebuild -exportArchive -archivePath "$archive" -exportPath "$output/Export" \
    -exportOptionsPlist "$options" -allowProvisioningUpdates
