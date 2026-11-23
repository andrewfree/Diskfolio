import AppKit
import Darwin
import Foundation
import Security

enum CleanupError: LocalizedError {
    case unsupportedApp, running, changed, noCandidates, signature, differentVolume, filesystemPermission, permission, incomplete

    var errorDescription: String? {
        switch self {
        case .unsupportedApp: "Choose a standalone app in Applications or ~/Applications."
        case .running: "Quit the app you selected before replacing it."
        case .changed: "The app changed during review. Prepare a fresh copy before replacing it."
        case .noCandidates: "No resources in the selected categories qualified for cleanup."
        case .signature: "The app copy couldn't pass the original signature check. Try reviewing one category at a time."
        case .differentVolume: "The app and its recovery folder must be on the same volume."
        case .filesystemPermission: "Your account can’t write to this app bundle or its containing folder."
        case .permission: "macOS denied this replacement. Check App Management and the app’s file permissions."
        case .incomplete: "Diskfolio couldn’t read the complete app, including its offline or protected resources."
        }
    }
}

struct CleanupPlan: Sendable {
    let original: URL
    let staged: URL
    let workspace: URL
    let recovery: URL
    let originalState: [String: FileIdentity]
    let stagedState: [String: FileIdentity]
    let resourcePaths: [String]
    let bytes: InventorySize
}

struct CleanupReceipt: Sendable {
    let bytes: Int64
    let backup: URL?
    let warning: String?
}

enum Cleanup {
    private struct RecoveryRecord: Encodable {
        let installedPath: String
        let original: FileIdentity
        let replacement: FileIdentity
        let preparedAt: Date
    }

    static func prepare(
        _ requested: URL, groups: Set<ResourceGroup>, roots: [URL] = AppInventory.roots,
        recovery: URL? = nil
    ) throws -> CleanupPlan {
        let original = try approvedApp(requested, roots: roots)
        try checkWritable(original)
        try checkRunning(original)
        let originalState = try snapshot(original)
        let code = try signedCode(original)
        var originalRequirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &originalRequirement) == errSecSuccess,
              let originalRequirement else { throw CleanupError.signature }

        let scan = try AppInventory.scan(roots: [original], requireRoots: true, collectCleanupResources: true)
        guard scan.scanned == 1, scan.unreadable == 0 else { throw CleanupError.incomplete }
        let resources = scan.cleanupResources.filter { resource in
            switch resource.action {
            case .language: groups.contains(.language)
            case .nativeSlice: groups.contains(.architecture)
            }
        }
        guard !resources.isEmpty else { throw CleanupError.noCandidates }

        let files = FileManager.default
        let recoveryFolder = try recovery ?? files.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("Diskfolio/Recovery", isDirectory: true)
        let staging = recoveryFolder.deletingLastPathComponent().appendingPathComponent("Staging", isDirectory: true)
        for folder in [recoveryFolder, staging] {
            try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard let info = Scanner.metadata(folder), Scanner.isDirectory(info) else {
                throw CleanupError.incomplete
            }
        }
        let workspace = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var prepared = false
        defer { if !prepared { try? files.removeItem(at: workspace) } }
        guard let device = Scanner.metadata(original)?.st_dev, Scanner.metadata(workspace)?.st_dev == device,
              Scanner.metadata(recoveryFolder)?.st_dev == device else {
            throw CleanupError.differentVolume
        }
        let staged = workspace.appendingPathComponent(original.lastPathComponent, isDirectory: true)
        try files.copyItem(at: original, to: staged)
        guard try snapshot(original) == originalState else { throw CleanupError.changed }

        var bytes = InventorySize()
        var resourcePaths: [String] = []
        for resource in resources {
            try Task.checkCancellation()
            let relative = try relativePath(resource.url, in: original)
            guard originalState[relative] == resource.identity else { throw CleanupError.changed }
            resourcePaths.append(relative)
            let item = staged.appendingPathComponent(relative)
            guard let info = Scanner.metadata(item), (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size == resource.identity.size, info.st_nlink == 1 else { throw CleanupError.changed }
            switch resource.action {
            case .language:
                try files.removeItem(at: item)
                bytes.language += info.st_size
            case let .nativeSlice(offset, length):
                try keepSlice(in: item, info: info, offset: offset, length: length)
                bytes.architecture += info.st_size - Int64(length)
            }
        }
        _ = try signedCode(staged, requirement: originalRequirement)
        let stagedState = try snapshot(staged)
        prepared = true
        return CleanupPlan(original: original, staged: staged, workspace: workspace, recovery: recoveryFolder,
                           originalState: originalState, stagedState: stagedState, resourcePaths: resourcePaths, bytes: bytes)
    }

    static func apply(
        _ plan: CleanupPlan,
        keepBackup: Bool,
        exchange: (URL, URL) throws -> Void = exchangeBundles
    ) throws -> CleanupReceipt {
        try checkWritable(plan.original)
        guard let originalRoot = plan.originalState[""], let replacementRoot = plan.stagedState[""] else {
            throw CleanupError.changed
        }
        let record = RecoveryRecord(installedPath: plan.original.path, original: originalRoot,
                                    replacement: replacementRoot, preparedAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: plan.workspace.appendingPathComponent("recovery.json"), options: .atomic)
        guard try snapshot(plan.staged) == plan.stagedState,
              try snapshot(plan.original) == plan.originalState else { throw CleanupError.changed }
        try checkRunning(plan.original)
        try Task.checkCancellation()
        try exchange(plan.original, plan.staged)

        if !matchesDisplacedOriginal(plan) {
            return retainOriginal(plan, bytes: 0,
                                  warning: "The app changed during replacement. Its displaced copy was preserved for review.")
        }
        if keepBackup {
            return retainOriginal(plan, bytes: plan.bytes.total)
        }
        do {
            try FileManager.default.removeItem(at: plan.staged)
            try? FileManager.default.removeItem(at: plan.workspace)
            return CleanupReceipt(bytes: plan.bytes.total, backup: nil, warning: nil)
        } catch {
            return CleanupReceipt(bytes: plan.bytes.total, backup: plan.staged,
                                  warning: "The original could not be fully discarded. Its remaining files are in Staging.")
        }
    }

    static func exchangeBundles(_ original: URL, _ staged: URL) throws {
        let status: Int32 = original.withUnsafeFileSystemRepresentation { originalPath in
            staged.withUnsafeFileSystemRepresentation { stagedPath in
                guard let originalPath, let stagedPath else { return EINVAL }
                if renamex_np(originalPath, stagedPath, UInt32(RENAME_SWAP)) == 0 { return 0 }
                return errno
            }
        }
        switch status {
        case 0: return
        case EPERM, EACCES: throw CleanupError.permission
        case EXDEV: throw CleanupError.differentVolume
        default: throw NSError(domain: NSPOSIXErrorDomain, code: Int(status))
        }

    }

    private static func matchesDisplacedOriginal(_ plan: CleanupPlan) -> Bool {
        guard var displaced = try? snapshot(plan.staged),
              let displacedRoot = displaced.removeValue(forKey: "") else { return false }
        var expected = plan.originalState
        guard let root = expected.removeValue(forKey: "") else { return false }
        // The exchange changes the root directory's change time.
        return displacedRoot.device == root.device && displacedRoot.inode == root.inode &&
            displacedRoot.mode == root.mode && displacedRoot.size == root.size &&
            displacedRoot.modified == root.modified && displacedRoot.nanoseconds == root.nanoseconds &&
            displaced == expected
    }

    private static func retainOriginal(_ plan: CleanupPlan, bytes: Int64, warning: String? = nil) -> CleanupReceipt {
        let destination = plan.recovery.appendingPathComponent(plan.workspace.lastPathComponent, isDirectory: true)
        do {
            try FileManager.default.moveItem(at: plan.workspace, to: destination)
            return CleanupReceipt(bytes: bytes,
                                  backup: destination.appendingPathComponent(plan.staged.lastPathComponent),
                                  warning: warning)
        } catch {
            let locationWarning = "The displaced copy remains in Staging."
            return CleanupReceipt(bytes: bytes, backup: plan.staged,
                                  warning: warning.map { "\($0) \(locationWarning)" } ?? locationWarning)
        }
    }

    static func discard(_ plan: CleanupPlan) {
        guard let info = Scanner.metadata(plan.staged), FileIdentity(info) == plan.stagedState[""] else { return }
        try? FileManager.default.removeItem(at: plan.workspace)
    }

    private static func approvedApp(_ requested: URL, roots: [URL]) throws -> URL {
        guard let app = Scanner.resolve(requested).url, requested.standardizedFileURL.path == app.path,
              app.pathExtension.lowercased() == "app", app.path != Bundle.main.bundleURL.path else {
            throw CleanupError.unsupportedApp
        }
        for root in roots.compactMap({ Scanner.resolve($0).url }) {
            guard let relative = try? relativePath(app, in: root) else { continue }
            var ancestor = root
            var insidePackage = false
            for part in relative.split(separator: "/").dropLast() {
                ancestor.appendPathComponent(String(part), isDirectory: true)
                if Scanner.isPackage(ancestor) { insidePackage = true; break }
            }
            if !insidePackage { return app }
        }
        throw CleanupError.unsupportedApp
    }

    private static func checkWritable(_ app: URL) throws {
        let paths = [app, app.deletingLastPathComponent()]
        for path in paths {
            guard path.withUnsafeFileSystemRepresentation({ name in
                guard let name else { return false }
                return access(name, W_OK | X_OK) == 0
            }) else { throw CleanupError.filesystemPermission }
        }
    }

    private static func checkRunning(_ app: URL) throws {
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.standardizedFileURL.path == app.path }) {
            throw CleanupError.running
        }
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { throw CleanupError.incomplete }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 128)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0, count < pids.count else { throw CleanupError.incomplete }
        let bundlePrefix = app.path + "/"
        var executable = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(count)) where pid > 0 {
            let length = executable.withUnsafeMutableBytes {
                proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
            }
            if length > 0 && String(cString: executable).hasPrefix(bundlePrefix) {
                throw CleanupError.running
            }
        }
    }

    private static func signedCode(_ url: URL, requirement: SecRequirement? = nil) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw CleanupError.signature
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures))
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { throw CleanupError.signature }
        return code
    }

    private static func relativePath(_ url: URL, in root: URL) throws -> String {
        let prefix = root.path == "/" ? "/" : root.path + "/"
        guard url.path.hasPrefix(prefix), url.path != root.path else { throw CleanupError.unsupportedApp }
        return String(url.path.dropFirst(prefix.count))
    }

    private static func snapshot(_ root: URL) throws -> [String: FileIdentity] {
        guard let info = Scanner.metadata(root), Scanner.isDirectory(info) else { throw CleanupError.changed }
        var identities = ["": FileIdentity(info)]
        var visited = Set([DiskObject(info)])
        func visit(_ directory: URL, depth: Int) throws {
            guard depth < 256 else { throw CleanupError.incomplete }
            for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                try Task.checkCancellation()
                guard let childInfo = Scanner.metadata(child), childInfo.st_dev == info.st_dev,
                      (childInfo.st_flags & UInt32(SF_DATALESS)) == 0 else { throw CleanupError.incomplete }
                identities[try relativePath(child, in: root)] = FileIdentity(childInfo)
                if Scanner.isDirectory(childInfo) {
                    guard visited.insert(DiskObject(childInfo)).inserted else { throw CleanupError.incomplete }
                    try visit(child, depth: depth + 1)
                }
            }
        }
        try visit(root, depth: 0)
        return identities
    }

    private static func keepSlice(in url: URL, info: stat, offset: UInt64, length: UInt64) throws {
        let mode = mode_t(info.st_mode & 0o7777)
        guard chmod(url.path, mode | mode_t(S_IWUSR)) == 0 else { throw POSIXError(.EACCES) }
        defer { _ = chmod(url.path, mode) }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        var written: UInt64 = 0
        while written < length {
            try Task.checkCancellation()
            let count = Int(min(length - written, 1_048_576))
            try handle.seek(toOffset: offset + written)
            guard let data = try handle.read(upToCount: count), data.count == count else { throw CleanupError.changed }
            try handle.seek(toOffset: written)
            try handle.write(contentsOf: data)
            written += UInt64(count)
        }
        try handle.truncate(atOffset: length)
        try handle.synchronize()
    }
}
