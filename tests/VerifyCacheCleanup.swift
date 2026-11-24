import Foundation

@main
struct VerifyCacheCleanup {
    static func main() throws {
        let manager = FileManager.default
        let home = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let code = home.appendingPathComponent("Library/Application Support/Code", isDirectory: true)
        let changed = code.appendingPathComponent("Code Cache", isDirectory: true)
        let cache = code.appendingPathComponent("CachedData", isDirectory: true)
        let settings = code.appendingPathComponent("User/settings.json")
        let chrome = home.appendingPathComponent("Library/Caches/Google/Chrome", isDirectory: true)
        let profile = chrome.appendingPathComponent("Profile 2", isDirectory: true)
        let ignored = chrome.appendingPathComponent("Guest Profile/Cache", isDirectory: true)
        for folder in [changed, cache, settings.deletingLastPathComponent(), profile, ignored] {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        let bytes = Data("fixture cache".utf8)
        let changedFile = changed.appendingPathComponent("cached")
        try bytes.write(to: changedFile)
        try bytes.write(to: cache.appendingPathComponent("cached"))
        try bytes.write(to: settings)
        try bytes.write(to: ignored.appendingPathComponent("cached"))
        try manager.createSymbolicLink(at: profile.appendingPathComponent("Cache"), withDestinationURL: ignored)

        let review = CacheCleanup.review(home: home)
        precondition(Set(review.candidates.map(\.url)) == Set([cache, changed]))
        precondition(review.candidates.allSatisfy { $0.bytes == Int64(bytes.count) })
        precondition(review.skipped.count == 1)
        let stale = review.candidates.first { $0.url == changed }!
        try Data("new cache contents".utf8).write(to: changedFile)
        let fresh = review.candidates.first { $0.url == cache }!
        let store = CleanupHistory(home: home)
        let receipt = try store.move([stale, fresh], reviewedIssues: review.skipped)
        precondition(receipt.entries.filter { $0.bytes > 0 }.count == 1)
        precondition(receipt.entries.count == 3)
        precondition(manager.fileExists(atPath: changedFile.path))
        precondition(!manager.fileExists(atPath: cache.path))

        let reopened = CleanupHistory(home: home)
        let saved = try reopened.history()
        precondition(saved.map(\.id) == [receipt.id])
        let copies = try reopened.recovery()
        precondition(copies.count == 1 && copies[0].bytes == Int64(bytes.count))

        try manager.createDirectory(at: cache, withIntermediateDirectories: false)
        let regenerated = cache.appendingPathComponent("regenerated")
        try bytes.write(to: regenerated)
        do {
            try reopened.restore(copies[0])
            fatalError("Restore overwrote a regenerated cache.")
        } catch {}
        precondition(manager.fileExists(atPath: regenerated.path))
        try manager.removeItem(at: cache)
        try reopened.restore(copies[0])
        let restored = try Data(contentsOf: cache.appendingPathComponent("cached"))
        precondition(restored == bytes)

        let rescanned = CacheCleanup.review(home: home)
        _ = try reopened.move([rescanned.candidates.first { $0.url == cache }!])
        let deletable = try reopened.recovery()
        let claimed = home.appendingPathComponent("Library/Application Support/Diskfolio/CacheRecovery")
            .appendingPathComponent(deletable[0].id.uuidString)
        try manager.moveItem(at: claimed.appendingPathComponent("cache"), to: claimed.appendingPathComponent("deleting"))
        let interrupted = try reopened.recovery()
        precondition(interrupted[0].deleting)
        try reopened.delete(interrupted[0])
        let remaining = try reopened.recovery()
        precondition(remaining.isEmpty)
        let settingsAfter = try Data(contentsOf: settings)
        precondition(settingsAfter == bytes)
        precondition(manager.fileExists(atPath: ignored.appendingPathComponent("cached").path))

        let applications = home.appendingPathComponent("Applications", isDirectory: true)
        try manager.createDirectory(at: applications, withIntermediateDirectories: false)
        let input = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let installed = applications.appendingPathComponent("Fixture.app", isDirectory: true)
        try manager.copyItem(at: input, to: installed)
        let appRecovery = home.appendingPathComponent("Library/Application Support/Diskfolio/Recovery", isDirectory: true)
        let plan = try Cleanup.prepare(installed, groups: [.language], roots: [applications], recovery: appRecovery)
        _ = try Cleanup.apply(plan, keepBackup: true)
        let appCopies = try reopened.recovery()
        precondition(appCopies.count == 1 && appCopies[0].app)
        try reopened.restore(appCopies[0], roots: [applications])
        let restoredApps = try reopened.recovery()
        precondition(restoredApps.isEmpty)
        precondition(manager.fileExists(atPath: installed.appendingPathComponent("Contents/Resources/fr.lproj/Example.txt").path))
        print("Persistent receipts, cache restore conflict, interrupted deletion, and original app restore passed.")
    }
}
