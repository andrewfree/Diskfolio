import Foundation

@main
struct VerifyCleanupBatch {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fixture = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let recovery = root.appendingPathComponent("Recovery", isDirectory: true)
        let apps = root.appendingPathComponent("Apps", isDirectory: true)
        let files = FileManager.default
        try files.createDirectory(at: apps, withIntermediateDirectories: false)

        func copy(_ name: String) throws -> URL {
            let copy = apps.appendingPathComponent(name + ".app", isDirectory: true)
            try files.copyItem(at: fixture, to: copy)
            return copy
        }
        func french(_ app: URL) -> URL {
            app.appendingPathComponent("Contents/Resources/fr.lproj/Example.txt")
        }

        let first = try copy("Atlas")
        let second = try copy("Beacon")
        let changed = try copy("Changed")
        let skipped = try copy("Broken signature")
        try files.removeItem(at: skipped.appendingPathComponent("Contents/_CodeSignature/CodeResources"))

        let groups: Set<ResourceGroup> = [.language]
        let preview = CleanupBatch.preview([first, second, changed, skipped], groups: groups, roots: [apps], recovery: recovery)
        precondition(preview.apps.map(\.url) == [first, second, changed], "\(preview.apps.map(\.url)) \(preview.issues)")
        precondition(preview.bytes == InventorySize(language: 36))
        precondition(preview.issues.map(\.app) == [skipped])
        let retained = try files.contentsOfDirectory(atPath: recovery.path)
        precondition(retained.isEmpty, "Preview left a staged copy.")
        precondition([first, second, changed, skipped].allSatisfy { files.fileExists(atPath: french($0).path) })

        try files.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10_000)], ofItemAtPath: french(changed).path)
        let done = CleanupBatch.apply(preview, groups: groups, keepBackup: true, roots: [apps], recovery: recovery)
        precondition(done.receipts.count == 2 && done.bytes == 24 && done.pending == 0)
        precondition(done.issues.map(\.app) == [changed])
        precondition(!files.fileExists(atPath: french(first).path) && !files.fileExists(atPath: french(second).path))
        precondition(files.fileExists(atPath: french(changed).path) && files.fileExists(atPath: french(skipped).path))
        precondition(done.receipts.compactMap(\.backup).allSatisfy { files.fileExists(atPath: french($0).path) })
        print("Batch preview left originals intact and discarded staging. Apply replaced two verified copies, retained both backups, and refused the changed and unsigned fixtures.")
    }
}
