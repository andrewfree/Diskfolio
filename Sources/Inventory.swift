import CoreFoundation
import Darwin
import Foundation

struct InventorySize: Codable, Equatable, Sendable {
    var architecture: Int64 = 0
    var language: Int64 = 0
    var total: Int64 { architecture + language }

    static func + (left: Self, right: Self) -> Self {
        Self(architecture: left.architecture + right.architecture, language: left.language + right.language)
    }
}

struct AppResources: Identifiable, Codable, Sendable {
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    let url: URL
    var size = InventorySize()
}

struct CleanupResource: Sendable {
    let url: URL
    let identity: FileIdentity
    let action: Action

    enum Action: Sendable {
        case language
        case nativeSlice(offset: UInt64, length: UInt64)
    }
}

struct InventoryReport: Codable, Sendable {
    let apps: [AppResources]
    let scanned: Int
    let unreadable: Int
    let preference: KeepPreference
    var cleanupResources: [CleanupResource] = []

    enum CodingKeys: String, CodingKey {
        case apps, scanned, unreadable, preference
    }

    var size: InventorySize { apps.reduce(InventorySize()) { $0 + $1.size } }
}

struct KeepPreference: Codable, Sendable {
    let architecture: String
    let languages: [String]

    static var local: Self {
        var supportsArm: Int32 = 0
        var length = MemoryLayout<Int32>.size
        let isArm = sysctlbyname("hw.optional.arm64", &supportsArm, &length, nil, 0) == 0 && supportsArm == 1
        let preferred = Locale.preferredLanguages.filter { languageFamily($0) != nil }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = isArm ? "arm64" : "x86_64"
        #endif
        return Self(architecture: architecture, languages: preferred.isEmpty ? ["en"] : preferred)
    }

    static let knownLanguages = Set(Locale.LanguageCode.isoLanguageCodes.map { $0.identifier.lowercased() })
    static let localeTag = try! NSRegularExpression(pattern: "^[a-z]{2,3}(?:[-_][a-z0-9]{2,8})*$")

    static func languageFamily(_ label: String) -> String? {
        var tag = label.lowercased().replacingOccurrences(of: "_", with: "-")
        if let last = tag.split(separator: "-").last, tag.hasSuffix("-\(last)"),
           ["feminine", "masculine", "neuter"].contains(last) {
            tag.removeLast(last.count + 1)
        }
        let tagRange = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        if localeTag.firstMatch(in: tag, range: tagRange) == nil {
            tag = Locale.canonicalLanguageIdentifier(from: label).lowercased().replacingOccurrences(of: "_", with: "-")
        }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        guard localeTag.firstMatch(in: tag, range: range) != nil,
              let family = tag.split(separator: "-").first.map(String.init) else { return nil }
        switch family {
        case "nb", "nn", "no": return "no"
        case "fil", "tl": return "fil"
        case "zh", "yue": return "zh"
        default:
            return knownLanguages.contains(family) && !["und", "mul", "zxx"].contains(family) ? family : nil
        }
    }
}

struct DiskObject: Hashable {
    let device: Int32
    let inode: UInt64

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }
}

enum AppInventory {
    static let roots = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        Scanner.home.appendingPathComponent("Applications", isDirectory: true)
    ]

    private enum LocaleScope {
        case unclassified, kept, candidate
    }

    private struct LinkedCandidate {
        let app: Int
        let size: InventorySize
        let links: UInt16
    }

    static func scan(
        roots: [URL] = roots,
        preference: KeepPreference = .local,
        requireRoots: Bool = false,
        collectCleanupResources: Bool = false,
        appLanguagePreferences: @Sendable (String) -> [String] = { identifier in
            CFPreferencesCopyAppValue("AppleLanguages" as CFString, identifier as CFString) as? [String] ?? []
        },
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) throws -> InventoryReport {
        let manager = FileManager.default
        var visited = Set<DiskObject>()
        var appDirectories: [(URL, Int32)] = []
        var unreadable = 0

        func children(_ url: URL) -> [URL] {
            do {
                return try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            } catch {
                unreadable += 1
                return []
            }
        }

        func discover(_ url: URL, info: stat, device: Int32, depth: Int) throws {
            try Task.checkCancellation()
            guard depth < 256, info.st_dev == device, Scanner.isDirectory(info),
                  (info.st_flags & UInt32(SF_DATALESS)) == 0,
                  visited.insert(DiskObject(info)).inserted else { return }
            if url.pathExtension.lowercased() == "app" {
                appDirectories.append((url, device))
                return
            }
            for directory in children(url) where !directory.lastPathComponent.hasPrefix(".") {
                guard let metadata = Scanner.metadata(directory) else { unreadable += 1; continue }
                try discover(directory, info: metadata, device: device, depth: depth + 1)
            }
        }

        var accessibleRoots = 0
        for root in roots {
            let (resolved, code) = Scanner.resolve(root)
            guard let url = resolved, let info = Scanner.metadata(url), Scanner.isDirectory(info),
                  (info.st_flags & UInt32(SF_DATALESS)) == 0 else {
                if requireRoots { throw ScanError.inaccessible }
                if code != ENOENT { unreadable += 1 }
                continue
            }
            accessibleRoots += 1
            try discover(url, info: info, device: info.st_dev, depth: 0)
        }
        guard accessibleRoots > 0 else { throw ScanError.inaccessible }

        appDirectories.sort { $0.0.path < $1.0.path }
        var apps = appDirectories.map { AppResources(url: $0.0) }
        visited.removeAll(keepingCapacity: true)
        var links: [DiskObject: [LinkedCandidate]] = [:]
        var requiresAlternateArchitecture = Set<Int>()
        var cleanupResources: [(app: Int, resource: CleanupResource)] = []
        let userLanguages = Set(preference.languages.compactMap(KeepPreference.languageFamily)).union(["en"])
        progress(0, apps.count)

        func walk(
            _ url: URL, info: stat, app: Int, device: Int32, locale: LocaleScope,
            kept: Set<String>?, depth: Int
        ) throws {
            try Task.checkCancellation()
            guard depth < 256, info.st_dev == device else { return }
            if (info.st_flags & UInt32(SF_DATALESS)) != 0 {
                unreadable += 1
                return
            }
            let type = info.st_mode & S_IFMT
            if type == S_IFDIR {
                guard visited.insert(DiskObject(info)).inserted else { return }
                var nextKept = kept
                if let manifest = bundleManifest(at: url) {
                    if let identifier = manifest["CFBundleIdentifier"] as? String {
                        nextKept?.formUnion(appLanguagePreferences(identifier).compactMap(KeepPreference.languageFamily))
                    }
                    if let region = manifest["CFBundleDevelopmentRegion"] {
                        if let label = region as? String, let family = KeepPreference.languageFamily(label) {
                            nextKept?.insert(family)
                        } else {
                            nextKept = nil
                        }
                    }
                }
                let descendants = children(url)
                let isLocaleFolder = ["locale", "locales"].contains(url.lastPathComponent.lowercased())
                let localizations = nextKept.map { languages in
                    locale == .unclassified
                        ? candidateLocalizations(descendants, kept: languages, includePacks: isLocaleFolder)
                        : []
                } ?? []
                for child in descendants {
                    guard let metadata = Scanner.metadata(child) else { unreadable += 1; continue }
                    var nextLocale = locale
                    let extensionName = child.pathExtension.lowercased()
                    if locale == .unclassified && (extensionName == "lproj" || (isLocaleFolder && extensionName == "pak")) {
                        nextLocale = localizations.contains(child.lastPathComponent) ? .candidate : .kept
                    }
                    try walk(child, info: metadata, app: app, device: device, locale: nextLocale, kept: nextKept, depth: depth + 1)
                }
                return
            }
            guard type == S_IFREG, info.st_size > 0 else { return }

            var inspected = MachO.Finding()
            if info.st_size >= 28 {
                do {
                    inspected = try MachO.inspect(at: url, info: info, keeping: preference.architecture)
                    if inspected.requiresAlternate { requiresAlternateArchitecture.insert(app) }
                } catch {
                    unreadable += 1
                }
            }

            let size: InventorySize
            switch locale {
            case .candidate: size = InventorySize(language: info.st_size)
            case .kept: return
            case .unclassified: size = InventorySize(architecture: inspected.extraBytes)
            }
            guard size.total > 0 else { return }
            if info.st_nlink > 1 {
                links[DiskObject(info), default: []].append(LinkedCandidate(app: app, size: size, links: info.st_nlink))
            } else {
                apps[app].size = apps[app].size + size
                if collectCleanupResources {
                    let action: CleanupResource.Action?
                    if locale == .candidate {
                        action = .language
                    } else if let slice = inspected.nativeSlice {
                        action = .nativeSlice(offset: slice.offset, length: slice.length)
                    } else {
                        action = nil
                    }
                    if let action {
                        cleanupResources.append((app, CleanupResource(url: url, identity: FileIdentity(info), action: action)))
                    }
                }
            }
        }

        for (index, entry) in appDirectories.enumerated() {
            let (url, device) = entry
            if let info = Scanner.metadata(url), Scanner.isDirectory(info) {
                try walk(url, info: info, app: index, device: device, locale: .unclassified,
                         kept: userLanguages, depth: 0)
            } else {
                unreadable += 1
            }
            progress(index + 1, apps.count)
        }

        for index in requiresAlternateArchitecture {
            apps[index].size.architecture = 0
        }
        for candidates in links.values {
            guard let first = candidates.first, candidates.count == Int(first.links),
                  candidates.allSatisfy({
                      $0.size == first.size && $0.links == first.links &&
                      (first.size.architecture == 0 || !requiresAlternateArchitecture.contains($0.app))
                  }) else { continue }
            apps[first.app].size = apps[first.app].size + first.size
        }
        return InventoryReport(
            apps: apps.filter { $0.size.total > 0 }.sorted {
                $0.size.total == $1.size.total ? $0.url.path < $1.url.path : $0.size.total > $1.size.total
            },
            scanned: apps.count, unreadable: unreadable, preference: preference,
            cleanupResources: cleanupResources.compactMap { entry in
                if case .nativeSlice = entry.resource.action, requiresAlternateArchitecture.contains(entry.app) { return nil }
                return entry.resource
            }
        )
    }

    private static func candidateLocalizations(
        _ urls: [URL], kept: Set<String>, includePacks: Bool
    ) -> Set<String> {
        var names = Set<String>()
        for kind in includePacks ? ["lproj", "pak"] : ["lproj"] {
            let resources = urls.filter { $0.pathExtension.lowercased() == kind }.compactMap { url -> (name: String, family: String)? in
                guard let info = Scanner.metadata(url), (info.st_flags & UInt32(SF_DATALESS)) == 0,
                      (info.st_mode & S_IFMT) == (kind == "lproj" ? S_IFDIR : S_IFREG),
                      let family = KeepPreference.languageFamily(url.deletingPathExtension().lastPathComponent)
                else { return nil }
                return (url.lastPathComponent, family)
            }
            guard resources.contains(where: { kept.contains($0.family) }) else { continue }
            names.formUnion(resources.filter { !kept.contains($0.family) }.map(\.name))
        }
        return names
    }

    private static let bundleExtensions: Set<String> = ["app", "appex", "bundle", "framework", "plugin", "xpc"]

    private static func bundleManifest(at url: URL) -> [String: Any]? {
        let isFrameworkVersion = url.deletingLastPathComponent().lastPathComponent == "Versions" &&
            url.deletingLastPathComponent().deletingLastPathComponent().pathExtension.lowercased() == "framework"
        guard isFrameworkVersion || bundleExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        for relative in ["Contents/Info.plist", "Resources/Info.plist", "Info.plist"] {
            let manifest = url.appendingPathComponent(relative)
            guard let info = Scanner.metadata(manifest), (info.st_mode & S_IFMT) == S_IFREG,
                  (info.st_flags & UInt32(SF_DATALESS)) == 0,
                  info.st_size > 0, info.st_size <= 1_048_576,
                  let data = try? Data(contentsOf: manifest),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let manifest = plist as? [String: Any] else { continue }
            return manifest
        }
        return nil
    }
}

private enum MachO {
    private struct Slice {
        let cpu: UInt32
        let offset: UInt64
        let length: UInt64
    }

    struct Finding {
        var extraBytes: Int64 = 0
        var requiresAlternate = false
        var nativeSlice: (offset: UInt64, length: UInt64)?
    }

    static func inspect(at url: URL, info: stat, keeping architecture: String) throws -> Finding {
        let arm: UInt32 = 0x0100000c
        let intel: UInt32 = 0x01000007
        let keptCPU = architecture == "arm64" ? arm : intel
        let otherCPU: Set<UInt32> = architecture == "arm64" ? [intel, 7] : [arm, 12]

        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) } ?? -1
        }
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var current = stat()
        guard fstat(descriptor, &current) == 0, (current.st_mode & S_IFMT) == S_IFREG,
              DiskObject(current) == DiskObject(info), current.st_size == info.st_size else { return Finding() }
        guard let header = try handle.read(upToCount: 8), header.count == 8 else { return Finding() }
        let magic = read(header, at: 0, width: 4, littleEndian: false)
        if let little = thinEndian(magic),
           otherCPU.contains(UInt32(read(header, at: 4, width: 4, littleEndian: little))),
           let tail = try handle.read(upToCount: 8), tail.count == 8 {
            return Finding(requiresAlternate: isLoadable(tail, typeOffset: 4, little: little))
        }
        guard [0xcafebabe, 0xcafebabf, 0xbebafeca, 0xbfbafeca].contains(magic) else { return Finding() }

        let little = magic == 0xbebafeca || magic == 0xbfbafeca
        let wide = magic == 0xcafebabf || magic == 0xbfbafeca
        let count = Int(read(header, at: 4, width: 4, littleEndian: little))
        let stride = wide ? 32 : 20
        guard (2...64).contains(count),
              let data = try handle.read(upToCount: count * stride), data.count == count * stride else { return Finding() }

        let fileSize = UInt64(current.st_size)
        var slices: [Slice] = []
        for index in 0..<count {
            let base = index * stride
            let cpu = UInt32(read(data, at: base, width: 4, littleEndian: little))
            let offset = read(data, at: base + 8, width: wide ? 8 : 4, littleEndian: little)
            let length = read(data, at: base + (wide ? 16 : 12), width: wide ? 8 : 4, littleEndian: little)
            let alignment = read(data, at: base + (wide ? 24 : 16), width: 4, littleEndian: little)
            guard offset >= UInt64(8 + count * stride), offset <= fileSize,
                  length >= 8, length <= fileSize - offset, alignment <= 40,
                  offset % (UInt64(1) << alignment) == 0 else { return Finding() }
            slices.append(Slice(cpu: cpu, offset: offset, length: length))
        }

        slices.sort { $0.offset < $1.offset }
        guard zip(slices, slices.dropFirst()).allSatisfy({ $0.offset + $0.length <= $1.offset }) else { return Finding() }

        guard slices.contains(where: { otherCPU.contains($0.cpu) }) else { return Finding() }
        var hasMacNative = false
        var allMacOS = true
        var alternateLoadable = false
        var nativeSlice: (offset: UInt64, length: UInt64)?
        for slice in slices {
            try handle.seek(toOffset: slice.offset)
            let peek = Int(min(32, slice.length))
            guard let peer = try handle.read(upToCount: peek), peer.count == peek else { return Finding() }
            if peer.prefix(8) == Data("!<arch>\n".utf8) {
                allMacOS = false
                continue
            }
            let mark = read(peer, at: 0, width: 4, littleEndian: false)
            guard let little = thinEndian(mark), peer.count >= 16,
                  read(peer, at: 4, width: 4, littleEndian: little) == slice.cpu else { return Finding() }
            let loadable = isLoadable(peer, typeOffset: 12, little: little)
            let macOS = try loadable && targetsMacOS(handle, slice: slice, header: peer, magic: mark, little: little)
            allMacOS = allMacOS && macOS
            if otherCPU.contains(slice.cpu) {
                alternateLoadable = alternateLoadable || loadable
            } else if slice.cpu == keptCPU, macOS {
                hasMacNative = true
                if slices.count == 2 {
                    nativeSlice = (slice.offset, slice.length)
                }
            }
        }
        guard hasMacNative else { return Finding(requiresAlternate: alternateLoadable) }
        guard allMacOS else { return Finding() }
        return Finding(
            extraBytes: slices.filter { otherCPU.contains($0.cpu) }.reduce(0) { $0 + Int64($1.length) },
            nativeSlice: nativeSlice
        )
    }

    private static func targetsMacOS(
        _ handle: FileHandle, slice: Slice, header: Data, magic: UInt64, little: Bool
    ) throws -> Bool {
        let headerSize = magic == 0xfeedfacf || magic == 0xcffaedfe ? 32 : 28
        guard header.count >= headerSize else { return false }
        let count = Int(read(header, at: 16, width: 4, littleEndian: little))
        let commandBytes = Int(read(header, at: 20, width: 4, littleEndian: little))
        guard commandBytes <= 4_194_304, count > 0, count <= commandBytes / 8,
              UInt64(headerSize + commandBytes) <= slice.length else { return false }
        try handle.seek(toOffset: slice.offset + UInt64(headerSize))
        guard let commands = try handle.read(upToCount: commandBytes), commands.count == commandBytes else {
            return false
        }
        var position = 0
        var declaresMacOS = false
        for _ in 0..<count {
            guard position <= commands.count - 8 else { return false }
            let type = read(commands, at: position, width: 4, littleEndian: little)
            let size = Int(read(commands, at: position + 4, width: 4, littleEndian: little))
            guard size >= 8, size % 4 == 0, size <= commands.count - position else { return false }
            switch type {
            case 0x32: // LC_BUILD_VERSION
                guard size >= 24, read(commands, at: position + 8, width: 4, littleEndian: little) == 1 else {
                    return false
                }
                declaresMacOS = true
            case 0x24: // LC_VERSION_MIN_MACOSX
                guard size >= 16 else { return false }
                declaresMacOS = true
            case 0x25, 0x2f, 0x30: // Other LC_VERSION_MIN commands
                return false
            default:
                break
            }
            position += size
        }
        return declaresMacOS && position == commands.count
    }

    private static func thinEndian(_ magic: UInt64) -> Bool? {
        switch magic {
        case 0xfeedface, 0xfeedfacf: false
        case 0xcefaedfe, 0xcffaedfe: true
        default: nil
        }
    }

    private static func isLoadable(_ header: Data, typeOffset: Int, little: Bool) -> Bool {
        [2, 6, 8].contains(read(header, at: typeOffset, width: 4, littleEndian: little))
    }

    private static func read(_ data: Data, at offset: Int, width: Int, littleEndian: Bool) -> UInt64 {
        let bytes = data[offset..<(offset + width)]
        if littleEndian {
            return bytes.reversed().reduce(0) { ($0 << 8) | UInt64($1) }
        }
        return bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
