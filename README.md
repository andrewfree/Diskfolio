# Diskfolio

Diskfolio is a native macOS utility for removing extra Intel slices and unused translations from installed apps. It also previews app caches before moving selected folders to the Trash.

## Build and test

Use an Apple Silicon Mac running macOS 13 or later, Xcode or the Xcode Command Line Tools, and Python 3 for the test fixtures.

```sh
./build-app.sh
./tests/run.sh
open build/Diskfolio.app
```

The build script creates an ad hoc signed app and a ZIP under `site/downloads/`. The local build uses ad hoc signing. The release package is built separately with Developer ID signing and notarization.

The tests create disposable signed apps under `build/` and run the scanner, CLI, and replacement engine against those fixtures. They do not use your installed apps. The site in [`site/`](site/) is a static demo with sample data.

The app and site icons are generated from [`scripts/make-icon.swift`](scripts/make-icon.swift). To regenerate them, run `xcrun swift scripts/make-icon.swift` from the repository root.

## Clean apps

1. Open Diskfolio. It scans **Applications** and **~/Applications**, then prepares one temporary copy at a time to check what can be cleaned.
2. Choose the categories you want to check. Diskfolio keeps Apple Silicon code, English and Base resources, your preferred languages, and each app's declared fallback language.
3. Choose **Free Space**, then **Review Cleanup**. **All apps** is the default. Expand the skipped list to see why an app was excluded.
4. Review the copies and confirm the replacements. Quit the apps and their helpers first.

The preview checks the original and prepared copies against the original app's code signature requirement. Diskfolio skips files whose Mach-O slices target different platforms. It also preserves code needed by Intel-only components and skips apps it cannot read or write. App Management controls replacement. Your user account also needs write access to the app and its containing folder. Use **Open App Management** in the cleanup sheet if macOS denies a replacement.

If you used a development build, add the new Diskfolio app to App Management when macOS requests it.

Language choices reflect the current account and app settings. On a shared Mac, another account may need languages you have selected for removal. Architecture cleanup can remove Rosetta support from a universal app. Some app updaters may reject modified bundles or restore removed resources on update.

The preview reports logical file content, and preparing copies uses temporary disk space. APFS sharing, compression, and snapshots affect how much storage is reclaimed. Keeping an original retains its data and may increase disk usage while both copies exist.

## Clean app caches

Choose **App Caches** to review recognized cache folders for Chrome, Edge, Brave, and VS Code. Quit the apps you want to clean, select their caches, and confirm **Move to Trash**. Diskfolio rechecks the reviewed folders before moving them. Check the Trash if you need a folder back. The listed sizes describe the selected files, and the folders still occupy space until the Trash is emptied.

## Restore an original

Recovery copies are kept by default. Use **Reveal recovery copies** or open `~/Library/Application Support/Diskfolio/Recovery` in Finder.

1. Find the original bundle and read `recovery.json` beside it. The `installedPath` field identifies where it belongs.
2. Quit the installed app and its helpers, then move the installed copy to the Trash.
3. Move the original back to the recorded path. Open it and verify it works before emptying the Trash.

When you have verified an installed copy and no longer need its original, you can move that recovery folder to the Trash. **Replace & Discard Originals** skips normal recovery and permanently discards originals that still match the reviewed apps.

Diskfolio uses a separate `Staging` folder while working. An interrupted replacement can leave an original there. If the workspace has a recovery record, use `stat -f '%i' /path/to/the/staged.app` and compare the inode to `original.inode` in `recovery.json`. A match identifies the displaced original. Preserve the files if the record or identity is unclear.

## Use the command line

Use the launcher from the repository after building, or keep it next to the app from the locally built ZIP.

```sh
./diskfolio cleanup --all
./diskfolio cleanup "/Applications/Example.app" --languages-only
./diskfolio cleanup "/Applications/Example.app" --apply
./diskfolio permissions
./diskfolio --inventory-json
./diskfolio --inventory-json /path/to/apps
```

Cleanup previews by default. `--apply` replaces eligible apps and keeps recovery copies. `--apply --discard-original` permits permanent discard. Use `--architecture-only` or `--languages-only` to check one category. `--inventory-json` lists inventory candidates before verification. The read-only folder scan is available as `./diskfolio --scan-json /path/to/folder`.

## Source layout

- [`Sources/Inventory.swift`](Sources/Inventory.swift) discovers bundles and classifies resource candidates.
- [`Sources/Cleanup.swift`](Sources/Cleanup.swift) prepares copies, validates signatures, exchanges bundles, and records recovery locations.
- [`Sources/CleanupBatch.swift`](Sources/CleanupBatch.swift) handles batch preview, replacement, and per-app results.
- [`tests/`](tests/) contains the disposable test harnesses.

## Windows edition

The Rust desktop app is in [`windows/`](windows/). It previews caches for Chrome, Edge, Brave, and VS Code on Windows. Select a folder, quit its app, and confirm **Move to recovery**. Use **Recovery** to restore it if its original location is free. To reclaim space, open the recovery folder and remove copies you no longer need.

To build on Windows 11 x64, use a Rust stable toolchain and the Visual Studio C++ build tools from an x64 developer command prompt.

```powershell
cargo test --locked --manifest-path windows/Cargo.toml
cargo build --release --locked --manifest-path windows/Cargo.toml
```

The executable is `windows/target/release/diskfolio-windows.exe`.

## License

Diskfolio is available under the [MIT License](LICENSE).
