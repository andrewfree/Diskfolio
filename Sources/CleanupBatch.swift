import CryptoKit
import Foundation

struct CleanupBatchIssue: Identifiable, Sendable {
    var id: URL { app }
    let app: URL
    let reason: String
}

struct CleanupBatchPreview: Sendable {
    struct App: Sendable {
        let url: URL
        let bytes: InventorySize
        fileprivate let fingerprint: SHA256.Digest
    }

    var apps: [App] = []
    var issues: [CleanupBatchIssue] = []
    var cancelled = false
    var bytes: InventorySize { apps.reduce(InventorySize()) { $0 + $1.bytes } }
}

struct CleanupBatchResult: Sendable {
    let previewIssues: [CleanupBatchIssue]
    var receipts: [CleanupReceipt] = []
    var issues: [CleanupBatchIssue] = []
    var pending = 0
    var permissionDenied = false
    var cancelled = false
    var bytes: Int64 { receipts.reduce(0) { $0 + $1.bytes } }
    var skipped: Int {
        previewIssues.count + issues.count - receipts.filter { $0.warning != nil }.count
    }
}

enum CleanupBatch {
    typealias Progress = @Sendable (_ done: Int, _ count: Int, _ app: URL) -> Void

    static func preview(
        _ apps: [URL], groups: Set<ResourceGroup>, roots: [URL] = AppInventory.roots,
        recovery: URL? = nil, progress: Progress = { _, _, _ in }
    ) -> CleanupBatchPreview {
        var result = CleanupBatchPreview()
        for (index, url) in apps.enumerated() {
            progress(index, apps.count, url)
            do {
                try Task.checkCancellation()
                let plan = try Cleanup.prepare(url, groups: groups, roots: roots, recovery: recovery)
                defer { Cleanup.discard(plan) }
                try Task.checkCancellation()
                result.apps.append(.init(url: plan.original, bytes: plan.bytes, fingerprint: fingerprint(plan)))
            } catch is CancellationError {
                result.cancelled = true
                break
            } catch {
                result.issues.append(.init(app: url, reason: error.localizedDescription))
            }
        }
        return result
    }

    static func apply(
        _ preview: CleanupBatchPreview, groups: Set<ResourceGroup>, keepBackup: Bool,
        roots: [URL] = AppInventory.roots, recovery: URL? = nil,
        progress: Progress = { _, _, _ in }
    ) -> CleanupBatchResult {
        var result = CleanupBatchResult(previewIssues: preview.issues, pending: preview.apps.count)
        guard !preview.cancelled else {
            result.cancelled = true
            return result
        }
        for (index, reviewed) in preview.apps.enumerated() {
            progress(index, preview.apps.count, reviewed.url)
            do {
                try Task.checkCancellation()
                let plan = try Cleanup.prepare(reviewed.url, groups: groups, roots: roots, recovery: recovery)
                defer { Cleanup.discard(plan) }
                guard plan.bytes == reviewed.bytes, fingerprint(plan) == reviewed.fingerprint else { throw CleanupError.changed }
                let receipt = try Cleanup.apply(plan, keepBackup: keepBackup)
                result.receipts.append(receipt)
                if let warning = receipt.warning {
                    let reason = receipt.backup.map { "\(warning) \($0.path)" } ?? warning
                    result.issues.append(.init(app: reviewed.url, reason: reason))
                }
            } catch is CancellationError {
                result.cancelled = true
                break
            } catch CleanupError.permission {
                result.permissionDenied = true
                result.issues.append(.init(app: reviewed.url, reason: CleanupError.permission.localizedDescription))
            } catch {
                result.issues.append(.init(app: reviewed.url, reason: error.localizedDescription))
            }
            result.pending -= 1
        }
        return result
    }

    private static func fingerprint(_ plan: CleanupPlan) -> SHA256.Digest {
        var hash = SHA256()
        func append(_ value: String) {
            hash.update(data: Data(value.utf8))
            hash.update(data: Data([0]))
        }
        for path in plan.originalState.keys.sorted() {
            guard let file = plan.originalState[path] else { continue }
            append(path)
            let identity = [
                Int64(file.device), Int64(bitPattern: file.inode), Int64(file.mode),
                Int64(file.modified), Int64(file.nanoseconds), Int64(file.changed),
                Int64(file.changeNanoseconds), file.size
            ].map { $0.littleEndian }
            identity.withUnsafeBytes { hash.update(bufferPointer: $0) }
        }
        append("selected resources")
        for path in plan.resourcePaths.sorted() { append(path) }
        return hash.finalize()
    }
}
