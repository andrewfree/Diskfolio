import Foundation
import SwiftUI

enum ResourceGroup: String, CaseIterable, Identifiable {
    case architecture, language

    var id: Self { self }
    var title: String {
        switch self {
        case .architecture: "Extra architecture"
        case .language: "Other languages"
        }
    }

    var icon: String {
        switch self {
        case .architecture: "cpu"
        case .language: "globe"
        }
    }

    func bytes(in size: InventorySize) -> Int64 {
        switch self {
        case .architecture: size.architecture
        case .language: size.language
        }
    }
}

@MainActor
final class InventoryModel: ObservableObject {
    enum Phase {
        case idle
        case scanning(done: Int, total: Int)
        case verifying(done: Int, total: Int, app: URL)
        case ready(InventoryReport, CleanupBatchPreview)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var selection = Set(ResourceGroup.allCases)
    @Published var showsCleanup = false
    private var job: Task<Void, Never>?
    private var jobID = UUID()
    private let roots: [URL]

    init(roots: [URL]) {
        self.roots = roots
    }

    var isWorking: Bool {
        switch phase {
        case .scanning, .verifying: true
        default: false
        }
    }

    func start() {
        if case .idle = phase { rescan() }
    }

    func rescan() {
        guard !isWorking, !showsCleanup else { return }
        job?.cancel()
        let id = UUID()
        let roots = self.roots
        jobID = id
        phase = .scanning(done: 0, total: 0)
        let worker = Task.detached(priority: .userInitiated) { [weak self] in
            try AppInventory.scan(roots: roots, progress: { [weak self] done, total in
                Task { @MainActor in
                    guard let self, self.jobID == id, case let .scanning(previous, _) = self.phase,
                          done >= previous else { return }
                    self.phase = .scanning(done: done, total: total)
                }
            })
        }
        job = Task { [weak self] in
            do {
                let report = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard let self, self.jobID == id, !Task.isCancelled else { return }
                self.verify(report)
            } catch {
                guard let self, self.jobID == id, !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func selectedBytes(in size: InventorySize) -> Int64 {
        selection.reduce(0) { $0 + $1.bytes(in: size) }
    }

    func rankedApps(_ apps: [AppResources]) -> [AppResources] {
        let measured: [(app: AppResources, bytes: Int64)] = apps.map {
            ($0, selectedBytes(in: $0.size))
        }
        let selected = measured.filter { $0.bytes > 0 }
        let ranked = selected.sorted { first, second in
            if first.bytes != second.bytes { return first.bytes > second.bytes }
            return first.app.url.path < second.app.url.path
        }
        return ranked.map { $0.app }
    }

    func toggle(_ group: ResourceGroup, on: Bool) {
        guard case let .ready(report, _) = phase, selection.contains(group) != on else { return }
        if on {
            selection.insert(group)
        } else {
            selection.remove(group)
        }
        verify(report)
    }

    private func verify(_ report: InventoryReport) {
        let urls = rankedApps(report.apps).map(\.url)
        guard let first = urls.first else {
            phase = .ready(report, CleanupBatchPreview())
            return
        }
        let id = UUID()
        let groups = selection
        jobID = id
        phase = .verifying(done: 0, total: urls.count, app: first)
        let worker = Task.detached(priority: .userInitiated) { [weak self] in
            CleanupBatch.preview(urls, groups: groups) { [weak self] done, total, app in
                Task { @MainActor in
                    guard let self, self.jobID == id, case let .verifying(previous, _, _) = self.phase,
                          done >= previous else { return }
                    self.phase = .verifying(done: done, total: total, app: app)
                }
            }
        }
        job = Task { [weak self] in
            let preview = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, self.jobID == id, !Task.isCancelled else { return }
            self.phase = .ready(report, preview)
        }
    }
}

func diskSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func languageName(_ tag: String) -> String {
    Locale.current.localizedString(forIdentifier: tag) ?? tag
}
