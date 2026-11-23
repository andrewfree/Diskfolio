#!/bin/sh
set -eu

cd "$(dirname "$0")"
mkdir -p build site/downloads
work=$(mktemp -d "$PWD/build/.package.XXXXXX")
app="$PWD/build/Diskfolio.app"
archive="$PWD/site/downloads/Diskfolio-macOS.zip"
staged="$work/Diskfolio.app"

cleanup() {
    if [ -e "$work/previous.app" ] && [ ! -e "$app" ]; then
        if ! mv "$work/previous.app" "$app"; then
            printf 'Previous app remains at %s\n' "$work/previous.app" >&2
            return
        fi
    fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$staged/Contents/MacOS" "$staged/Contents/Resources"
xcrun swiftc -target arm64-apple-macos13.0 -swift-version 5 -O -parse-as-library \
    Sources/*.swift -o "$staged/Contents/MacOS/Diskfolio"
cp Sources/Info.plist "$staged/Contents/Info.plist"
cp Sources/Diskfolio.icns "$staged/Contents/Resources/Diskfolio.icns"

codesign --sign - "$staged"
codesign --verify --strict --deep "$staged"
ditto -c -k --keepParent --norsrc --noextattr "$staged" "$work/Diskfolio-macOS.zip"
/usr/bin/zip -q -j "$work/Diskfolio-macOS.zip" "$PWD/diskfolio" "$PWD/LICENSE"
/usr/bin/unzip -tq "$work/Diskfolio-macOS.zip"

if [ -e "$app" ]; then
    mv "$app" "$work/previous.app"
fi
mv "$staged" "$app"
mv -f "$work/Diskfolio-macOS.zip" "$archive"
printf 'App: %s\nDownload: %s\n' "$app" "$archive"
