import os
import plistlib
import struct
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()

def write(relative, size):
    target = root / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("wb") as stream:
        stream.truncate(size)
    return target

def write_header(stream, cpu):
    stream.write(struct.pack("<8I", 0xFEEDFACF, cpu, 0, 2, 1, 24, 0, 0))
    stream.write(struct.pack("<6I", 0x32, 24, 1, 0x000D0000, 0x000D0000, 0))

def binary(relative, alternate, native=None):
    target = write(relative, 4096 + alternate + (4096 + native if native else 0))
    with target.open("r+b") as stream:
        if native is None:
            write_header(stream, 0x01000007)
            return
        entries = ((0x01000007, 4096, alternate), (0x0100000C, 8192 + alternate, native))
        stream.write(struct.pack(">II", 0xCAFEBABE, 2))
        for cpu, offset, size in entries:
            stream.write(struct.pack(">IIIII", cpu, 0, offset, size, 12))
        for cpu, offset, _ in entries:
            stream.seek(offset)
            write_header(stream, cpu)

def manifest(relative, fallback, identifier=None):
    target = write(relative, 0)
    contents = {"CFBundleDevelopmentRegion": fallback}
    if identifier is not None:
        contents["CFBundleIdentifier"] = identifier
    target.write_bytes(plistlib.dumps(contents))

manifest("Suite/Atlas.app/Contents/Info.plist", "en")
binary("Suite/Atlas.app/Contents/Frameworks/Engine", 2_000 * 4096, 4096)
binary("Suite/Atlas.app/Contents/Helpers/Helper", 500 * 4096, 4096)
write("Suite/Atlas.app/Contents/Resources/fr.lproj/strings", 2_500_000)
write("Suite/Atlas.app/Contents/Resources/fr_MASCULINE.lproj/strings", 200_000)
write("Suite/Atlas.app/Contents/Resources/unmatched/pl.lproj/strings", 4_000_000)
write("Suite/Atlas.app/Contents/Resources/neuter.lproj/strings", 4_000_000)
write("Suite/Atlas.app/Contents/Resources/en-US.lproj/strings", 9_000_000)
write("Suite/Atlas.app/Contents/Resources/Base.lproj/strings", 8_000_000)
write("Suite/Atlas.app/Contents/Resources/unknown.lproj/strings", 7_000_000)
write("Suite/Atlas.app/Contents/Resources/locales/fr.pak", 500_000)
write("Suite/Atlas.app/Contents/Resources/locales/en-GB.pak", 6_000_000)
manifest("Suite/Atlas.app/Contents/Frameworks/Widget.framework/Versions/A/Resources/Info.plist", "ja")
write("Suite/Atlas.app/Contents/Frameworks/Widget.framework/Versions/A/Resources/ja.lproj/strings", 6_000_000)
write("Suite/Atlas.app/Contents/Frameworks/Widget.framework/Versions/A/Resources/it.lproj/strings", 1_000_000)

manifest("Beacon.APP/Contents/Info.plist", "de")
binary("Beacon.APP/Contents/MacOS/Beacon", 800 * 4096, 8192)
write("Beacon.APP/Contents/Resources/de.lproj/strings", 10_000_000)
write("Beacon.APP/Contents/Resources/ko.lproj/strings", 5_000_000)
shared = write("Beacon.APP/Contents/Resources/fr.lproj/shared", 750_000)
second = shared.with_name("shared-copy")
if not second.exists():
    os.link(shared, second)
external = write("Beacon.APP/Contents/Resources/ru.lproj/external", 5_000_000)
outside = root / "Beacon.APP/Contents/Resources/en.lproj/shared-with-language"
if not outside.exists():
    outside.parent.mkdir(exist_ok=True)
    adjacent = external.with_name("external-link")
    if not adjacent.exists():
        os.link(external, adjacent)
    adjacent.rename(outside)
manifest("Legacy.app/Contents/Info.plist", "en")
binary("Legacy.app/Contents/MacOS/Legacy", 3_000_000)
binary("Legacy.app/Contents/Frameworks/UniversalLib", 1_000 * 4096, 4096)
write("Legacy.app/Contents/Resources/en.lproj/strings", 900_000)
write("Legacy.app/Contents/Resources/es.lproj/strings", 200_000)

nested = "Suite/Installer.bundle/Resources/Language Workbench.APP/Contents"
manifest(f"{nested}/Info.plist", "en", "local.diskfolio.fixture.languages")
for locale, size in [
    ("en", 9_000_000), ("fr", 12_000_000), ("fr_MASCULINE", 1_000_000),
    ("nb", 700_000), ("no", 600_000), ("tl", 500_000), ("yue", 400_000),
]:
    write(f"{nested}/Resources/{locale}.lproj/strings", size)

symlink = root / "Alias.app"
if not symlink.is_symlink():
    symlink.symlink_to(root / "Beacon.APP", target_is_directory=True)
root_link = root.with_name("Inventory Fixture Alias")
if not root_link.is_symlink():
    root_link.symlink_to(root, target_is_directory=True)
print(root)
