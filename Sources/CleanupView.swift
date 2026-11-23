import AppKit
import SwiftUI

struct CleanupView: View {
    let preview: CleanupBatchPreview
    let groups: Set<ResourceGroup>
    let finished: (CleanupBatchResult) -> Void

    private enum Phase {
        case choose
        case review(CleanupBatchPreview)
        case applying
        case done(CleanupBatchResult)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .choose
    @State private var selected: URL? = nil
    @State private var keepOriginal = true
    @State private var progress = (done: 0, count: 0, name: "")
    @State private var stop: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Free Space").font(.system(size: 26, weight: .semibold))
            switch phase {
            case .choose:
                Text("Review all eligible apps in one batch, or choose a single app.")
                Picker("Apps", selection: $selected) {
                    Text("All apps").tag(URL?.none)
                    ForEach(preview.apps, id: \.url) { app in
                        Text("\(app.url.deletingPathExtension().lastPathComponent) · \(diskSize(app.bytes.total))")
                            .tag(Optional(app.url))
                    }
                }
                if selected == nil {
                    Text("\(preview.apps.count.formatted()) \(preview.apps.count == 1 ? "app" : "apps") ready to review")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case let .review(preview):
                if preview.apps.isEmpty {
                    Text("No apps qualified for cleanup.").font(.headline)
                } else {
                    Text("\(preview.apps.count) \(preview.apps.count == 1 ? "app" : "apps") ready to replace").font(.headline)
                    Text("\(diskSize(preview.bytes.total)) less logical file content in the verified copies.")
                    DisclosureGroup("Apps to replace") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(preview.apps, id: \.url) { app in
                                    Text("\(app.url.lastPathComponent) · \(diskSize(app.bytes.total))")
                                        .help(app.url.path)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 120)
                    }
                    if preview.bytes.architecture > 0 {
                        Text("Architecture cleanup can remove Intel-mode launch support.").foregroundStyle(.secondary)
                    }
                    Toggle("Keep originals for recovery", isOn: $keepOriginal)
                    Text(keepOriginal
                         ? "Keeping originals retains their data and can use additional disk space."
                         : "Diskfolio will permanently discard each original after replacing it.")
                        .foregroundStyle(.secondary)
                }
                CleanupIssues(issues: preview.issues, title: "skipped")
            case .applying:
                progressView("Cleaning apps", detail: "Verifying and replacing each approved app.")
            case let .done(result):
                CleanupResultSummary(result: result)
                CleanupIssues(issues: result.previewIssues + result.issues, title: "to review")
                if let backup = result.receipts.compactMap(\.backup).first {
                    Button("Reveal recovery copies") {
                        NSWorkspace.shared.open(backup.deletingLastPathComponent().deletingLastPathComponent())
                    }
                } else if !result.receipts.isEmpty {
                    Text("APFS determines the actual change in free space.").foregroundStyle(.secondary)
                }
            }

            Divider()
            if showPermission { AppManagementHelp() }
            HStack {
                Spacer()
                switch phase {
                case .choose:
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Review Cleanup", action: review).keyboardShortcut(.defaultAction)
                case let .review(preview):
                    Button("Back") { phase = .choose }
                    Button(keepOriginal ? "Replace & Keep Originals" : "Replace & Discard Originals",
                           role: keepOriginal ? nil : .destructive) {
                        apply(preview)
                    }.disabled(preview.apps.isEmpty)
                case let .done(result):
                    Button("Done") { finished(result) }.keyboardShortcut(.defaultAction)
                case .applying:
                    Button("Stop") {
                        stop?()
                        stop = nil
                    }.disabled(stop == nil)
                }
            }
        }
        .padding(25)
        .frame(width: 530, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(isWorking)
        .onDisappear { stop?() }
    }

    private var isWorking: Bool {
        switch phase {
        case .applying: true
        default: false
        }
    }

    private var showPermission: Bool {
        switch phase {
        case .choose: true
        case let .done(result): result.permissionDenied
        default: false
        }
    }

    private func progressView(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text(stop == nil ? "Stopping cleanup" : title).font(.headline)
            }
            Text(detail).foregroundStyle(.secondary)
            ProgressView(
                value: Double(progress.done), total: Double(max(progress.count, 1))
            ) {
                Text(progress.name).lineLimit(1)
            } currentValueLabel: {
                Text("\(progress.done) of \(progress.count) processed").monospacedDigit()
            }
        }
    }

    private func review() {
        if let selected {
            phase = .review(CleanupBatchPreview(apps: preview.apps.filter { $0.url == selected }))
        } else {
            phase = .review(preview)
        }
    }

    private func apply(_ preview: CleanupBatchPreview) {
        let groups = self.groups
        let keepBackup = keepOriginal
        phase = .applying
        progress = (0, preview.apps.count, preview.apps.first?.url.lastPathComponent ?? "")
        let worker = Task.detached(priority: .userInitiated) {
            CleanupBatch.apply(preview, groups: groups, keepBackup: keepBackup, progress: updateProgress)
        }
        stop = { worker.cancel() }
        Task {
            let result = await worker.value
            stop = nil
            phase = .done(result)
        }
    }

    @Sendable private nonisolated func updateProgress(_ done: Int, _ count: Int, _ app: URL) {
        Task { @MainActor in
            guard isWorking, done >= progress.done else { return }
            progress = (done, count, app.lastPathComponent)
        }
    }
}

struct CleanupIssues: View {
    let issues: [CleanupBatchIssue]
    let title: String

    var body: some View {
        if !issues.isEmpty {
            DisclosureGroup("\(issues.count) \(title)") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(issues) { issue in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(issue.app.lastPathComponent).font(.subheadline.weight(.semibold))
                                Text(issue.reason).font(.caption).foregroundStyle(.secondary)
                            }.help(issue.app.path)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 145)
            }
        }
    }
}

struct CleanupResultSummary: View {
    let result: CleanupBatchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(result.cancelled ? "Cleanup stopped" : "Cleanup complete")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("\(result.receipts.count) cleaned · \(result.skipped) skipped"
                 + (result.pending > 0 ? " · \(result.pending) pending" : ""))
                .monospacedDigit()
            if !result.receipts.isEmpty {
                Text("\(diskSize(result.bytes)) of app content removed")
                    .foregroundStyle(.secondary)
            }
            if result.receipts.contains(where: { $0.backup != nil }) {
                Text("Recovery copies still use disk space.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
