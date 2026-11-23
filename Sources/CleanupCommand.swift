import AppKit
import Foundation

enum CleanupCommand {
    static let usage = """
    Diskfolio

      diskfolio cleanup <app.app | --all> [--architecture-only | --languages-only] [--apply] [--discard-original]
      diskfolio permissions
      diskfolio --inventory-json [app folders...]
      diskfolio --scan-json <folder>
      diskfolio --help

    Cleanup previews a signature-verified copy by default. --apply replaces eligible apps and
    keeps the originals for recovery. --apply --discard-original permanently removes
    the original after replacement. Quote paths with spaces.
    """

    static func run(
        _ arguments: [String], roots: [URL] = AppInventory.roots, recovery: URL? = nil
    ) -> Int32? {
        switch arguments.first {
        case "help", "--help", "-h":
            print(usage)
            return 0
        case "permissions":
            guard arguments.count == 1 else { return usageError("permissions takes no arguments.") }
            guard AppManagement.openSettings() else {
                error("Open System Settings → Privacy & Security → App Management.")
                return 1
            }
            print("Opened App Management in System Settings.")
            return 0
        case "cleanup":
            return cleanup(Array(arguments.dropFirst()), roots: roots, recovery: recovery)
        default:
            return nil
        }
    }

    private static func cleanup(_ arguments: [String], roots: [URL], recovery: URL?) -> Int32 {
        guard let path = arguments.first, path == "--all" || !path.hasPrefix("--") else {
            return usageError("Supply the path to a .app bundle or use --all.")
        }

        let flags = Array(arguments.dropFirst())
        let options = Set(flags)
        let valid: Set<String> = ["--architecture-only", "--languages-only", "--apply", "--discard-original"]
        guard options.isSubset(of: valid), options.count == flags.count else {
            return usageError("Use each documented option at most once.")
        }
        let onlyArchitecture = options.contains("--architecture-only")
        let onlyLanguages = options.contains("--languages-only")
        let apply = options.contains("--apply")
        let discardOriginal = options.contains("--discard-original")
        guard !(onlyArchitecture && onlyLanguages) else {
            return usageError("Choose only one resource filter.")
        }
        guard !discardOriginal || apply else {
            return usageError("--discard-original requires --apply.")
        }

        let groups: Set<ResourceGroup> = onlyArchitecture ? [.architecture] : onlyLanguages ? [.language] : [.architecture, .language]
        if path == "--all" {
            return cleanupAll(groups: groups, apply: apply, discardOriginal: discardOriginal, roots: roots, recovery: recovery)
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        do {
            let plan = try Cleanup.prepare(url, groups: groups, roots: roots, recovery: recovery)
            defer { Cleanup.discard(plan) }

            print(plan.original.path)
            print("  Extra architecture: \(plan.bytes.architecture) bytes")
            print("  Other languages:    \(plan.bytes.language) bytes")
            print("  Total:              \(plan.bytes.total) logical bytes")
            print("The prepared app passed its original signature check.")
            if plan.bytes.architecture > 0 {
                print("Architecture cleanup can remove Intel-mode launch support.")
            }
            guard apply else {
                print("Preview complete. The installed app is untouched.")
                return 0
            }

            let receipt = try Cleanup.apply(plan, keepBackup: !discardOriginal)
            if let warning = receipt.warning {
                error(warning)
                if let backup = receipt.backup { error("Recovery copy: \(backup.path)") }
                return 1
            }
            if let backup = receipt.backup {
                print("App replaced. Original retained at: \(backup.path)")
                print("The recovery copy still uses disk space.")
            } else {
                print("App replaced and original discarded. APFS determines the actual change in free space.")
            }
            return 0
        } catch CleanupError.permission {
            error(CleanupError.permission.localizedDescription)
            error("Run diskfolio permissions to open App Management. If macOS names your terminal in its prompt, enable that terminal.")
            return 1
        } catch let failure {
            error(failure.localizedDescription)
            return 1
        }
    }

    private static func cleanupAll(
        groups: Set<ResourceGroup>, apply: Bool, discardOriginal: Bool, roots: [URL], recovery: URL?
    ) -> Int32 {
        let urls: [URL]
        do {
            let inventory = try AppInventory.scan(roots: roots)
            urls = inventory.apps.filter { app in
                groups.contains { $0.bytes(in: app.size) > 0 }
            }.map(\.url)
        } catch let failure {
            error(failure.localizedDescription)
            return 1
        }

        let preview = CleanupBatch.preview(urls, groups: groups, roots: roots, recovery: recovery) { done, count, app in
            error("Preview \(done + 1)/\(count) · \(app.lastPathComponent)")
        }
        for app in preview.apps { print("\(app.bytes.total) bytes · \(app.url.path)") }
        for issue in preview.issues { error("Skipped \(issue.app.path): \(issue.reason)") }
        print("\(preview.apps.count) apps qualified · \(preview.bytes.total) logical bytes · \(preview.issues.count) skipped")
        guard apply, !preview.apps.isEmpty else { return 0 }
        if preview.bytes.architecture > 0 {
            print("Architecture cleanup can remove Intel-mode launch support.")
        }
        let result = CleanupBatch.apply(
            preview, groups: groups, keepBackup: !discardOriginal, roots: roots, recovery: recovery
        ) { done, count, app in
            error("Replace \(done + 1)/\(count) · \(app.lastPathComponent)")
        }
        for receipt in result.receipts {
            if let backup = receipt.backup { print("Recovery copy: \(backup.path)") }
        }
        if result.receipts.contains(where: { $0.backup != nil }) {
            print("Recovery copies still use disk space.")
        }
        for issue in result.issues { error("\(issue.app.path): \(issue.reason)") }
        if result.permissionDenied { error("Run diskfolio permissions to open App Management.") }
        print("\(result.receipts.count) apps replaced · \(result.bytes) logical bytes · \(result.pending) pending")
        return result.issues.isEmpty && result.pending == 0 ? 0 : 1
    }

    private static func usageError(_ message: String) -> Int32 {
        error(message)
        error(usage)
        return 64
    }

    private static func error(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
