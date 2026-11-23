import Darwin
import Foundation

enum Kind: String, Codable, CaseIterable, Sendable {
    case folder, app, image, video, audio, archive, document, other

    var icon: String {
        switch self {
        case .folder: "folder.fill"
        case .app: "app.dashed"
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .archive: "archivebox"
        case .document: "doc.text"
        case .other: "doc"
        }
    }

    static func identify(_ url: URL, directory: Bool) -> Self {
        let ext = url.pathExtension.lowercased()
        if directory { return ext == "app" ? .app : .folder }
        switch ext {
        case "png", "jpeg", "jpg", "heic", "tiff", "raw", "webp", "gif", "svg": return .image
        case "mov", "mp4", "mkv", "webm", "m4v", "avi": return .video
        case "mp3", "wav", "aif", "aiff", "m4a", "flac": return .audio
        case "zip", "tar", "gz", "dmg", "7z", "rar", "xz", "bz2", "iso", "pkg": return .archive
        case "pdf", "docx", "txt", "md", "pages", "numbers", "xlsx", "csv": return .document
        default: return .other
        }
    }
}

struct FileIdentity: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let mode: UInt16
    let modified: Int
    let nanoseconds: Int
    let changed: Int
    let changeNanoseconds: Int
    let size: Int64

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        mode = info.st_mode
        modified = info.st_mtimespec.tv_sec
        nanoseconds = info.st_mtimespec.tv_nsec
        changed = info.st_ctimespec.tv_sec
        changeNanoseconds = info.st_ctimespec.tv_nsec
        size = info.st_size
    }
}

struct DiskItem: Identifiable, Codable, Sendable {
    var id: String { url.path }
    var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
    var canOpen: Bool { directory && !package }
    let url: URL
    let directory: Bool
    let package: Bool
    let kind: Kind
    let bytes: Int64
    let identity: FileIdentity
    let cache: String?
}

struct ScanReport: Codable, Sendable {
    let root: URL
    let items: [DiskItem]
    let largest: [DiskItem]
    let caches: [DiskItem]
    let bytes: Int64
    let files: Int
    let skipped: Int
    let available: Int64?
    let capacity: Int64?
}

enum ScanError: LocalizedError {
    case inaccessible

    var errorDescription: String? {
        switch self {
        case .inaccessible: "Diskfolio couldn’t read this folder."
        }
    }
}

enum Scanner {
    static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    static let packages: Set<String> = [
        "app", "appex", "bundle", "framework", "photoslibrary", "photolibrary", "musiclibrary",
        "fcpbundle", "logicx", "band", "pages", "numbers", "key", "rtfd", "xcodeproj", "xcworkspace", "pkg"
    ]
    static let cachePaths = [
        "Library/Developer/Xcode/DerivedData": "Xcode Derived Data",
        "Library/Caches/com.apple.dt.Xcode": "Xcode cache",
        "Library/Caches/Homebrew": "Homebrew cache",
        "Library/Caches/pip": "pip cache",
        "Library/Caches/CocoaPods": "CocoaPods cache",
        "Library/Caches/org.swift.swiftpm": "SwiftPM cache",
        ".npm/_cacache": "npm package cache",
        ".cache/pip": "pip cache",
        ".cache/uv": "uv cache",
        ".cache/yarn": "Yarn cache"
    ]

    static func scan(
        _ requested: URL,
        progress: @escaping @Sendable (Int) -> Void = { _ in }
    ) throws -> ScanReport {
        guard let root = resolve(requested).url, let rootInfo = metadata(root), isDirectory(rootInfo),
              (rootInfo.st_flags & UInt32(SF_DATALESS)) == 0 else { throw ScanError.inaccessible }
        let manager = FileManager.default
        var skipped = 0
        var files = 0
        var largest: [DiskItem] = []
        var caches: [DiskItem] = []
        var directories: Set<DiskObject> = [DiskObject(rootInfo)]

        func walk(_ url: URL, _ info: stat, insidePackage: Bool, depth: Int) throws -> DiskItem? {
            try Task.checkCancellation()
            guard info.st_dev == rootInfo.st_dev, depth < 256,
                  (info.st_flags & UInt32(SF_DATALESS)) == 0 else {
                skipped += 1
                return nil
            }
            let type = info.st_mode & S_IFMT
            guard type == S_IFDIR || type == S_IFREG else {
                skipped += 1
                return nil
            }

            let directory = type == S_IFDIR
            let isStartupAlias = root.path == "/" && url.path == "/System/Volumes"
            if directory && (isStartupAlias || !directories.insert(DiskObject(info)).inserted) {
                skipped += 1
                return nil
            }
            let package = directory && isPackage(url)
            var bytes = max(0, info.st_size)
            if directory {
                bytes = 0
                guard let children = try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
                    skipped += 1
                    return nil
                }
                for child in children {
                    guard let childInfo = metadata(child) else {
                        skipped += 1
                        continue
                    }
                    if let childItem = try walk(child, childInfo, insidePackage: insidePackage || package, depth: depth + 1) {
                        bytes += childItem.bytes
                    }
                }
            } else {
                files += 1
                if files.isMultiple(of: 2_000) { progress(files) }
            }

            let item = DiskItem(
                url: url, directory: directory, package: package, kind: Kind.identify(url, directory: directory),
                bytes: bytes, identity: FileIdentity(info), cache: directory && !package ? cacheLabel(url) : nil
            )
            if !insidePackage {
                if item.cache != nil, bytes > 0 { caches.append(item) }
                if !directory, bytes > 0,
                   largest.count < 50 || largest.last.map({ ranksBefore(item, $0) }) == true {
                    let index = largest.firstIndex { ranksBefore(item, $0) } ?? largest.endIndex
                    largest.insert(item, at: index)
                    if largest.count > 50 { largest.removeLast() }
                }
            }
            return item
        }

        guard let children = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            throw ScanError.inaccessible
        }
        var items: [DiskItem] = []
        let rootIsPackage = isPackage(root)
        for child in children {
            guard let info = metadata(child) else {
                skipped += 1
                continue
            }
            if let item = try walk(child, info, insidePackage: rootIsPackage, depth: 0) {
                items.append(item)
            }
        }
        try Task.checkCancellation()
        let volume = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        return ScanReport(
            root: root, items: items.sorted(by: ranksBefore), largest: largest,
            caches: caches.sorted(by: ranksBefore), bytes: items.reduce(0) { $0 + $1.bytes }, files: files,
            skipped: skipped, available: volume?.volumeAvailableCapacity.map(Int64.init),
            capacity: volume?.volumeTotalCapacity.map(Int64.init)
        )
    }

    static func ranksBefore(_ first: DiskItem, _ second: DiskItem) -> Bool {
        first.bytes == second.bytes ? first.id < second.id : first.bytes > second.bytes
    }

    static func resolve(_ url: URL) -> (url: URL?, code: Int32) {
        url.withUnsafeFileSystemRepresentation { name in
            guard let name else { return (nil, EINVAL) }
            guard let fullName = realpath(name, nil) else { return (nil, errno) }
            defer { free(fullName) }
            return (URL(fileURLWithPath: String(cString: fullName), isDirectory: true), 0)
        }
    }

    static func metadata(_ url: URL) -> stat? {
        var info = stat()
        return url.withUnsafeFileSystemRepresentation { filename in
            guard let filename, lstat(filename, &info) == 0 else { return nil }
            return info
        }
    }

    static func isDirectory(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func isPackage(_ url: URL) -> Bool {
        packages.contains(url.pathExtension.lowercased()) ||
        (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    private static func cacheLabel(_ url: URL) -> String? {
        let prefix = home.path + "/"
        guard url.path.hasPrefix(prefix) else { return nil }
        return cachePaths[String(url.path.dropFirst(prefix.count))]
    }
}
