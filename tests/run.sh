#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
mkdir -p build
work=$(mktemp -d "$PWD/build/.test.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fixture="$work/Fixture.app"
mkdir -p "$fixture/Contents/MacOS"
for language in en de fr; do
    resource="$fixture/Contents/Resources/$language.lproj"
    mkdir -p "$resource"
    printf 'hello world\n' > "$resource/Example.txt"
done
cat > "$fixture/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.diskfolio.fixture.signed</string>
<key>CFBundleExecutable</key><string>Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>German</string>
</dict></plist>
PLIST
printf 'int main(void) { return 0; }\n' > "$work/main.c"
printf 'int diskfolio_fixture(void) { return 0; }\n' > "$work/helper.c"
xcrun clang -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 "$work/main.c" -o "$fixture/Contents/MacOS/Fixture"
codesign --sign - "$fixture"

unknown="$work/Unknown.app"
ditto "$fixture" "$unknown"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDevelopmentRegion UnrecognizedLanguage' "$unknown/Contents/Info.plist"
codesign --force --sign - "$unknown"

mixed="$work/Mixed.app"
ditto "$fixture" "$mixed"
xcrun clang -target arm64-apple-macos13.0 "$work/main.c" -o "$mixed/Contents/MacOS/Fixture"
mkdir -p "$mixed/Contents/Frameworks"
xcrun clang -target arm64-apple-macos13.0 -dynamiclib "$work/helper.c" -o "$work/arm.dylib"
xcrun vtool -set-build-version ios 15.0 15.0 -replace -output "$work/ios.dylib" "$work/arm.dylib"
xcrun clang -target x86_64-apple-macos13.0 -dynamiclib "$work/helper.c" -o "$work/mac.dylib"
xcrun lipo -create "$work/ios.dylib" "$work/mac.dylib" -output "$mixed/Contents/Frameworks/Mixed.dylib"
codesign --force --sign - "$mixed/Contents/Frameworks/Mixed.dylib"
codesign --force --sign - "$mixed"
codesign --verify --strict --deep "$mixed"

compile() {
    xcrun swiftc -target arm64-apple-macos13.0 -swift-version 5 -parse-as-library \
        Sources/Scan.swift Sources/Inventory.swift Sources/Model.swift Sources/Cleanup.swift \
        Sources/CleanupBatch.swift Sources/CleanupCommand.swift Sources/AppManagement.swift Sources/CacheCleanup.swift Sources/CleanupHistory.swift \
        "tests/$1.swift" -o "$work/$1"
}
for test in VerifyInventory VerifyReplacement VerifyCleanupBatch VerifyBatchPermissions VerifyCleanupCommand VerifyCacheCleanup; do
    compile "$test"
done
inventory="$work/Inventory Fixture"
python3 tests/make-inventory-fixture.py "$inventory"
"$work/VerifyInventory" "$inventory"

for test in VerifyReplacement VerifyCleanupBatch VerifyBatchPermissions; do
    mkdir "$work/$test-data"
    "$work/$test" "$work/$test-data" "$fixture" "$mixed" "$unknown" -AppleLanguages '(en-US)'
done
codesign --verify --strict --deep "$work/VerifyReplacement-data/Normal.app"
"$work/VerifyReplacement-data/Normal.app/Contents/MacOS/Fixture"

cli="$work/CLI"
mkdir "$cli"
ditto "$fixture" "$cli/Fixture.app"
resource="$cli/Fixture.app/Contents/Resources/fr.lproj/Example.txt"
"$work/VerifyCleanupCommand" "$cli" cleanup --all --languages-only -AppleLanguages '(en-US)'
test -f "$resource"
"$work/VerifyCleanupCommand" "$cli" cleanup --all --languages-only --apply -AppleLanguages '(en-US)'
test ! -e "$resource"
codesign --verify --strict --deep "$cli/Fixture.app"
mkdir "$work/Cache Fixture"
"$work/VerifyCacheCleanup" "$work/Cache Fixture" "$fixture" -AppleLanguages '(en-US)'
printf '%s\n' 'All disposable fixture checks passed.'
