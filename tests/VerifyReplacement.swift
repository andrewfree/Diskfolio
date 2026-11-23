import Foundation

@main
struct VerifyReplacement {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fixture = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let mixed = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        let unknown = URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true)
        let recovery = root.appendingPathComponent("Recovery", isDirectory: true)
        let files = FileManager.default

        func copy(_ name: String, source: URL? = nil) throws -> URL {
            let copy = root.appendingPathComponent("\(name).app", isDirectory: true)
            try files.copyItem(at: source ?? fixture, to: copy)
            return copy
        }

        func resource(_ app: URL, _ language: String) -> URL {
            app.appendingPathComponent("Contents/Resources/\(language).lproj/Example.txt")
        }

        let normal = try copy("Normal")
        let plan = try Cleanup.prepare(normal, groups: [.architecture, .language], roots: [root], recovery: recovery)
        precondition(plan.bytes.architecture > 0 && plan.bytes.language == 12)
        precondition(files.fileExists(atPath: resource(plan.staged, "de").path), "Lost the declared development language.")
        precondition(!files.fileExists(atPath: resource(plan.staged, "fr").path))
        let receipt = try Cleanup.apply(plan, keepBackup: true)
        guard let original = receipt.backup else { preconditionFailure("No recovery copy.") }
        precondition(receipt.warning == nil, "\(receipt.warning ?? "")")
        precondition(original.deletingLastPathComponent().deletingLastPathComponent() == recovery)
        precondition(files.fileExists(atPath: resource(original, "fr").path))
        precondition(!files.fileExists(atPath: resource(normal, "fr").path))
        let record = original.deletingLastPathComponent().appendingPathComponent("recovery.json")
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any]
        precondition(metadata?["installedPath"] as? String == normal.path)
        Cleanup.discard(plan)
        precondition(files.fileExists(atPath: resource(original, "fr").path))

        let disposable = try copy("Discard")
        let discard = try Cleanup.prepare(disposable, groups: [.language], roots: [root], recovery: recovery)
        let discarded = try Cleanup.apply(discard, keepBackup: false)
        precondition(discarded.backup == nil && discarded.warning == nil)
        precondition(!files.fileExists(atPath: discard.workspace.path))

        let raced = try copy("Race")
        let race = try Cleanup.prepare(raced, groups: [.language], roots: [root], recovery: recovery)
        let concurrentUpdate = "Contents/Resources/UpdaterMarker.txt"
        let raceReceipt = try Cleanup.apply(race, keepBackup: false) { installed, staged in
            try Data("updated while replacing".utf8).write(to: installed.appendingPathComponent(concurrentUpdate))
            try Cleanup.exchangeBundles(installed, staged)
        }
        guard let saved = raceReceipt.backup else { preconditionFailure("Discarded a concurrently updated original.") }
        precondition(raceReceipt.warning?.contains("changed during replacement") == true && raceReceipt.bytes == 0)
        precondition(files.fileExists(atPath: saved.appendingPathComponent(concurrentUpdate).path))
        Cleanup.discard(race)
        precondition(files.fileExists(atPath: saved.appendingPathComponent(concurrentUpdate).path))

        let crossPlatform = try copy("Mixed", source: mixed)
        do {
            let issued = try Cleanup.prepare(crossPlatform, groups: [.architecture], roots: [root], recovery: recovery)
            Cleanup.discard(issued)
            preconditionFailure("Prepared an app whose arm64 dylib slice targets iOS.")
        } catch CleanupError.noCandidates {
            precondition(files.fileExists(atPath: crossPlatform.appendingPathComponent("Contents/Frameworks/Mixed.dylib").path))
        }

        let unknownLanguage = try copy("Unknown Region", source: unknown)
        do {
            let issued = try Cleanup.prepare(unknownLanguage, groups: [.language], roots: [root], recovery: recovery)
            Cleanup.discard(issued)
            preconditionFailure("Prepared a language removal despite an unknown development region.")
        } catch CleanupError.noCandidates {
            precondition(files.fileExists(atPath: resource(unknownLanguage, "fr").path))
        }

        let running = try copy("Running Helper")
        let helper = running.appendingPathComponent("Contents/MacOS/FixtureHelper")
        try files.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: helper)
        let process = Process()
        process.executableURL = helper
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        do {
            let issued = try Cleanup.prepare(running, groups: [.language], roots: [root], recovery: recovery)
            Cleanup.discard(issued)
            preconditionFailure("Prepared replacement while a helper in the bundle was running.")
        } catch CleanupError.running {}

        let staging = recovery.deletingLastPathComponent().appendingPathComponent("Staging")
        let leftovers = try files.contentsOfDirectory(atPath: staging.path)
        precondition(leftovers.isEmpty)
        print("Verified legacy and unknown development languages, mixed-platform binaries, running helpers, recovery, intentional discard, and a concurrent change during replacement.")
    }
}
