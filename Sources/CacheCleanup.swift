import AppKit
import Foundation

enum CacheCleanup {
    struct Target: Sendable {
        let app: String
        let bundleID: String
        let folder: String
        let profiles: Bool
        let caches: [String]
    }

    struct Candidate: Identifiable, Sendable {
        var id: URL { url }
        let app: String
        let label: String
        let url: URL
        let bytes: Int64
        let running: Bool
        fileprivate let bundleID: String
        fileprivate let home: URL
        fileprivate let state: [String: FileIdentity]
    }

    struct Review: Sendable {
        var candidates: [Candidate] = []
        var skipped: [String] = []
    }


    private static let browserCaches = ["Cache", "Code Cache", "GPUCache"]
    private static let targets = [
        Target(app: "Chrome", bundleID: "com.google.Chrome", folder: "Library/Caches/Google/Chrome",
               profiles: true, caches: browserCaches),
        Target(app: "Edge", bundleID: "com.microsoft.edgemac", folder: "Library/Caches/Microsoft Edge",
               profiles: true, caches: browserCaches),
        Target(app: "Brave", bundleID: "com.brave.Browser", folder: "Library/Caches/BraveSoftware/Brave-Browser",
               profiles: true, caches: browserCaches),
        Target(app: "VS Code", bundleID: "com.microsoft.VSCode", folder: "Library/Application Support/Code",
               profiles: false, caches: browserCaches + ["CachedData"])
    ]

    static func review(home: URL = Scanner.home) -> Review {
        let manager = FileManager.default
        var review = Review()
        for target in targets {
            let root = home.appendingPathComponent(target.folder, isDirectory: true)
            guard Scanner.metadata(root) != nil else { continue }
            do {
                try checkPath(root, under: home)
                let parents = target.profiles
                    ? try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                        .filter { isBrowserProfile($0.lastPathComponent) }
                    : [root]
                let running = !NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID).isEmpty
                for parent in parents {
                    for cache in target.caches {
                        let url = parent.appendingPathComponent(cache, isDirectory: true)
                        guard Scanner.metadata(url) != nil else { continue }
                        let label = target.profiles ? "\(parent.lastPathComponent) / \(cache)" : cache
                        do {
                            let (bytes, state) = try snapshot(url, under: home)
                            guard bytes > 0 else { continue }
                            review.candidates.append(Candidate(
                                app: target.app, label: label, url: url, bytes: bytes,
                                running: running, bundleID: target.bundleID, home: home, state: state
                            ))
                        } catch {
                            review.skipped.append("\(target.app) · \(label): \(error.localizedDescription)")
                        }
                    }
                }
            } catch {
                review.skipped.append("\(target.app): \(error.localizedDescription)")
            }
        }
        review.candidates.sort {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.url.path < $1.url.path
        }
        return review
    }

    static func archive(_ candidate: Candidate, to payload: URL) throws {
        try checkClosed(candidate)
        let (_, state) = try snapshot(candidate.url, under: candidate.home)
        guard state == candidate.state else { throw CacheError.changed }
        try checkClosed(candidate)
        try renameExclusively(candidate.url, payload)
    }

    static func restore(_ path: URL, from payload: URL, home: URL) throws {
        guard path.path.hasPrefix(home.path + "/"), path.standardizedFileURL.path == path.path,
              let target = targets.first(where: { target in
                  let base = home.appendingPathComponent(target.folder).path
                  guard path.path.hasPrefix(base + "/") else { return false }
                  let names = path.path.dropFirst(base.count + 1).split(separator: "/")
                  guard let cache = names.last, target.caches.contains(String(cache)) else { return false }
                  return target.profiles
                      ? names.count == 2 && isBrowserProfile(String(names[0]))
                      : names.count == 1
              }) else { throw CacheError.unsafePath }
        try checkPath(path.deletingLastPathComponent(), under: home)
        guard NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID).isEmpty else {
            throw CacheError.appOpen(target.app)
        }
        try renameExclusively(payload, path)
    }

    static func renameExclusively(_ from: URL, _ to: URL) throws {
        let status = from.withUnsafeFileSystemRepresentation { source in
            to.withUnsafeFileSystemRepresentation { destination -> Int32 in
                guard let source, let destination else { return EINVAL }
                return renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
            }
        }
        if status == EEXIST { throw CacheError.destinationExists }
        if status != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(status)) }
    }

    private static func checkClosed(_ candidate: Candidate) throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: candidate.bundleID).isEmpty else {
            throw CacheError.appOpen(candidate.app)
        }
    }

    private static func isBrowserProfile(_ name: String) -> Bool {
        if name == "Default" { return true }
        guard name.hasPrefix("Profile ") else { return false }
        let number = name.dropFirst("Profile ".count)
        return !number.isEmpty && number.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func checkPath(_ url: URL, under home: URL) throws {
        let prefix = home.path + "/"
        guard url.path.hasPrefix(prefix),
              let root = Scanner.metadata(home), Scanner.isDirectory(root) else { throw CacheError.unsafePath }
        var current = home
        for component in url.path.dropFirst(prefix.count).split(separator: "/") {
            guard component != ".", component != ".." else { throw CacheError.unsafePath }
            current.appendPathComponent(String(component), isDirectory: true)
            guard let info = Scanner.metadata(current), Scanner.isDirectory(info),
                  info.st_dev == root.st_dev, info.st_flags & UInt32(SF_DATALESS) == 0
            else { throw CacheError.unsafePath }
        }
    }

    private static func snapshot(_ url: URL, under home: URL) throws -> (Int64, [String: FileIdentity]) {
        try checkPath(url, under: home)
        guard let root = Scanner.metadata(url), Scanner.isDirectory(root), root.st_uid == geteuid() else {
            throw CacheError.unsafePath
        }
        var state: [String: FileIdentity] = [:]
        var seen: Set<DiskObject> = []
        var bytes: Int64 = 0
        func visit(_ node: URL, depth: Int) throws {
            guard depth < 256, let info = Scanner.metadata(node),
                  info.st_dev == root.st_dev, info.st_uid == root.st_uid,
                  info.st_flags & UInt32(SF_DATALESS) == 0 else { throw CacheError.unsafePath }
            state[node.path] = FileIdentity(info)
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard seen.insert(DiskObject(info)).inserted else { throw CacheError.unsafePath }
                for child in try FileManager.default.contentsOfDirectory(at: node, includingPropertiesForKeys: nil) {
                    try visit(child, depth: depth + 1)
                }
            case S_IFREG:
                let (total, overflow) = bytes.addingReportingOverflow(info.st_size)
                guard !overflow else { throw CacheError.unsafePath }
                bytes = total
            default:
                throw CacheError.unsafePath
            }
            guard let latest = Scanner.metadata(node), FileIdentity(latest) == FileIdentity(info) else {
                throw CacheError.changed
            }
        }
        try visit(url, depth: 0)
        try checkPath(url, under: home)
        guard state[url.path] == FileIdentity(root) else { throw CacheError.changed }
        return (bytes, state)
    }

    private enum CacheError: LocalizedError {
        case changed, unsafePath, destinationExists, appOpen(String)

        var errorDescription: String? {
            switch self {
            case .changed: "Cache changed. Preview it again."
            case .unsafePath: "Cache includes a linked, unreadable, or unsupported path."
            case .destinationExists: "A cache already exists there. Move it to recovery before restoring."
            case let .appOpen(app): "Quit \(app) before cleaning its cache."
            }
        }
    }
}
