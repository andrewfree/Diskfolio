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
        precondition(CacheCleanup.moveToTrash([stale]).skipped.count == 1)
        precondition(manager.fileExists(atPath: changedFile.path))

        let fresh = review.candidates.first { $0.url == cache }!
        guard let trash = try CacheCleanup.moveToTrash(fresh) else {
            fatalError("The fixture did not receive a Trash destination.")
        }
        precondition(!manager.fileExists(atPath: cache.path))
        try manager.moveItem(at: trash, to: cache)
        let restored = try Data(contentsOf: cache.appendingPathComponent("cached"))
        let settingsAfter = try Data(contentsOf: settings)
        precondition(restored == bytes)
        precondition(settingsAfter == bytes)
        precondition(manager.fileExists(atPath: ignored.appendingPathComponent("cached").path))
        print("Cache selection, stale review, linked path refusal, and Trash round trip passed.")
    }
}
