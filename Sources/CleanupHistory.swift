import Foundation

struct CleanupHistory: Sendable {
    struct Entry: Codable, Sendable {
        let name: String
        let bytes: Int64
        let detail: String
        var recoveryID: UUID? = nil
    }

    struct Receipt: Codable, Identifiable, Sendable {
        var id = UUID()
        var date = Date()
        let title: String
        let entries: [Entry]
    }

    struct Copy: Identifiable, Sendable {
        let id: UUID
        let name: String
        let source: URL
        let date: Date
        let bytes: Int64?
        let deleting: Bool
        let app: Bool
    }

    private struct Record: Codable {
        let name: String
        let source: String
        let date: Date
        let bytes: Int64
        let device: Int32
        let inode: UInt64
    }

    let home: URL
    init(home: URL = Scanner.home) { self.home = home }

    private var base: URL { home.appendingPathComponent("Library/Application Support/Diskfolio", isDirectory: true) }
    private var copies: URL { base.appendingPathComponent("CacheRecovery", isDirectory: true) }
    private var appCopies: URL { base.appendingPathComponent("Recovery", isDirectory: true) }
    private var receipts: URL { base.appendingPathComponent("History", isDirectory: true) }

    func history() throws -> [Receipt] {
        try list(receipts).filter { $0.pathExtension == "json" }
            .map { try read(Receipt.self, at: $0) }.sorted { $0.date > $1.date }
    }

    func save(_ receipt: Receipt) throws {
        try ensureFolder(receipts)
        try write(receipt, to: receipts.appendingPathComponent(receipt.id.uuidString + ".json"))
    }

    func recovery() throws -> [Copy] {
        let caches = try list(copies).compactMap { folder -> Copy? in
            guard let id = UUID(uuidString: folder.lastPathComponent) else { return nil }
            let (record, _, deleting) = try copy(at: folder)
            guard let record else { return nil }
            return Copy(id: id, name: record.name, source: URL(fileURLWithPath: record.source),
                        date: record.date, bytes: record.bytes, deleting: deleting, app: false)
        }
        let apps = try list(appCopies).compactMap { folder -> Copy? in
            guard let id = UUID(uuidString: folder.lastPathComponent) else { return nil }
            try checkFolder(folder)
            guard let saved = try Cleanup.savedApp(in: folder) else { return nil }
            return Copy(id: id, name: saved.source.lastPathComponent, source: saved.source,
                        date: saved.date, bytes: nil, deleting: saved.deleting, app: true)
        }
        return (caches + apps).sorted { $0.date > $1.date }
    }

    func move(_ candidates: [CacheCleanup.Candidate], reviewedIssues: [String] = []) throws -> Receipt {
        try ensureFolder(copies)
        try ensureFolder(receipts)
        var entries = reviewedIssues.map { Entry(name: "Skipped", bytes: 0, detail: $0) }
        for candidate in candidates {
            let name = candidate.app + " · " + candidate.label
            let folder = copies.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                guard let info = Scanner.metadata(candidate.url), Scanner.isDirectory(info) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                let record = Record(name: name, source: candidate.url.path, date: Date(), bytes: candidate.bytes,
                                    device: info.st_dev, inode: info.st_ino)
                try write(record, to: folder.appendingPathComponent("source.json"))
                try CacheCleanup.archive(candidate, to: folder.appendingPathComponent("cache"))
                entries.append(Entry(name: name, bytes: candidate.bytes, detail: "Moved to recovery",
                                     recoveryID: UUID(uuidString: folder.lastPathComponent)))
            } catch {
                if Scanner.metadata(folder.appendingPathComponent("cache")) == nil {
                    removeMetadata(folder, app: false)
                }
                entries.append(Entry(name: name, bytes: 0, detail: error.localizedDescription))
            }
        }
        let receipt = Receipt(title: "Cache cleanup", entries: entries)
        try save(receipt)
        return receipt
    }

    func restore(_ selection: Copy, roots: [URL] = AppInventory.roots) throws {
        let folder = (selection.app ? appCopies : copies).appendingPathComponent(selection.id.uuidString, isDirectory: true)
        if selection.app {
            try withAppLock(folder) { try Cleanup.restoreSavedApp(in: folder, roots: roots) }
        } else {
            let (record, payload, deleting) = try copy(at: folder)
            guard let record, let payload, !deleting else { throw CocoaError(.fileNoSuchFile) }
            try CacheCleanup.restore(URL(fileURLWithPath: record.source), from: payload, home: home)
        }
        removeMetadata(folder, app: selection.app)
    }

    func delete(_ selection: Copy) throws {
        let folder = (selection.app ? appCopies : copies).appendingPathComponent(selection.id.uuidString, isDirectory: true)
        func remove(_ payload: URL, deleting: Bool) throws {
            let claimed = folder.appendingPathComponent("deleting")
            if !deleting { try CacheCleanup.renameExclusively(payload, claimed) }
            try FileManager.default.removeItem(at: claimed)
        }
        if selection.app {
            try withAppLock(folder) {
                guard let saved = try Cleanup.savedApp(in: folder) else { throw CocoaError(.fileNoSuchFile) }
                try remove(saved.payload, deleting: saved.deleting)
            }
        } else {
            let (record, payload, deleting) = try copy(at: folder)
            guard record != nil, let payload else { throw CocoaError(.fileNoSuchFile) }
            try remove(payload, deleting: deleting)
        }
        removeMetadata(folder, app: selection.app)
    }

    private func withAppLock(_ folder: URL, _ operation: () throws -> Void) throws {
        try checkFolder(folder)
        let fd = folder.withUnsafeFileSystemRepresentation { path in path.map { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) } ?? -1 }
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try operation()
    }

    func freeSpace() -> Int64? {
        (try? home.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(Int64.init)
    }

    private func copy(at folder: URL) throws -> (Record?, URL?, Bool) {
        try checkFolder(folder)
        let cache = folder.appendingPathComponent("cache")
        let deleting = folder.appendingPathComponent("deleting")
        let pending = Scanner.metadata(deleting) != nil
        let payload = pending ? deleting : cache
        guard let info = Scanner.metadata(payload) else { return (nil, nil, false) }
        let record = try read(Record.self, at: folder.appendingPathComponent("source.json"))
        guard Scanner.isDirectory(info), info.st_uid == geteuid(), info.st_dev == record.device,
              info.st_ino == record.inode else { throw CocoaError(.fileReadNoPermission) }
        return (record, payload, pending)
    }

    private func removeMetadata(_ folder: URL, app: Bool) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(app ? "recovery.json" : "source.json"))
        _ = folder.withUnsafeFileSystemRepresentation { path in path.map { rmdir($0) } }
    }

    private func list(_ folder: URL) throws -> [URL] {
        if Scanner.metadata(folder) == nil { return [] }
        try checkFolder(folder)
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    private func ensureFolder(_ folder: URL) throws {
        let components = folder.path.dropFirst(home.path.count + 1).split(separator: "/")
        var current = home
        for component in components {
            current.appendPathComponent(String(component), isDirectory: true)
            if Scanner.metadata(current) == nil {
                do {
                    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])
                } catch where Scanner.metadata(current) != nil {}
            }
            try checkFolder(current)
        }
    }

    private func checkFolder(_ folder: URL) throws {
        guard folder.path.hasPrefix(home.path + "/") else { throw CocoaError(.fileReadNoPermission) }
        var current = folder
        while current.path != home.path {
            guard let info = Scanner.metadata(current), Scanner.isDirectory(info), info.st_uid == geteuid()
            else { throw CocoaError(.fileReadNoPermission) }
            current.deleteLastPathComponent()
        }
    }

    private func read<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> Value {
        guard let info = Scanner.metadata(url), (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid()
        else { throw CocoaError(.fileReadNoPermission) }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
