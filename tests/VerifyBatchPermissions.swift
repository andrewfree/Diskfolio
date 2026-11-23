import Foundation

@main
struct VerifyBatchPermissions {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fixture = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let recovery = root.appendingPathComponent("Recovery", isDirectory: true)
        let apps = root.appendingPathComponent("Apps", isDirectory: true)
        let files = FileManager.default
        try files.createDirectory(at: apps, withIntermediateDirectories: false)

        func app(_ name: String) throws -> URL {
            let target = apps.appendingPathComponent(name + ".app", isDirectory: true)
            try files.copyItem(at: fixture, to: target)
            return target
        }
        func mode(_ mode: Int, _ target: URL) throws {
            try files.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
        }
        func french(_ target: URL) -> URL {
            target.appendingPathComponent("Contents/Resources/fr.lproj/Example.txt")
        }

        let blocked = try app("Blocked Before Preview")
        let blockedLater = try app("Blocked After Preview")
        let available = try app("Writable")
        try mode(0o555, blocked)
        defer {
            try? mode(0o755, blocked)
            try? mode(0o755, blockedLater)
        }

        let groups: Set<ResourceGroup> = [.language]
        let preview = CleanupBatch.preview([blocked, blockedLater, available], groups: groups, roots: [apps], recovery: recovery)
        precondition(preview.apps.map(\.url) == [blockedLater, available], "\(preview.issues)")
        precondition(preview.issues.count == 1 && preview.issues[0].app == blocked)
        precondition(preview.issues[0].reason == CleanupError.filesystemPermission.localizedDescription)
        precondition([blocked, blockedLater, available].allSatisfy { files.fileExists(atPath: french($0).path) })

        try mode(0o555, blockedLater)
        let applied = CleanupBatch.apply(preview, groups: groups, keepBackup: true, roots: [apps], recovery: recovery)
        precondition(applied.pending == 0 && applied.receipts.count == 1)
        precondition(applied.issues.count == 1 && applied.issues[0].app == blockedLater)
        precondition(applied.issues[0].reason == CleanupError.filesystemPermission.localizedDescription)
        let recoveryCopy = applied.receipts[0].backup
        precondition(recoveryCopy != nil && files.fileExists(atPath: french(recoveryCopy!).path))
        precondition(files.fileExists(atPath: french(blocked).path) && files.fileExists(atPath: french(blockedLater).path))
        precondition(!files.fileExists(atPath: french(available).path))
        print("Verified batch skips a non-writable app during preview and continues past a later denial to replace the writable app with a backup.")
    }
}
