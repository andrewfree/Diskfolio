import SwiftUI

struct CacheCleanupView: View {
    private enum Phase {
        case scanning, ready, moving
    }

    @Environment(\.dismiss) private var dismiss
    @State private var phase = Phase.scanning
    @State private var review = CacheCleanup.Review()
    @State private var selection: Set<URL> = []
    @State private var receipt: CleanupHistory.Receipt?
    @State private var error: String?
    @State private var confirmsMove = false

    private var selected: [CacheCleanup.Candidate] {
        review.candidates.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("App caches")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Move selected caches to Recovery. They still use disk space until you delete the copies.")
                .foregroundStyle(.secondary)

            if let receipt {
                let moved = receipt.entries.filter { $0.bytes > 0 }.count
                Text("\(moved.formatted()) moved to recovery · \(receipt.entries.count - moved) skipped")
                    .font(.headline)
            }

            if let error { Text(error).foregroundStyle(.orange) }

            switch phase {
            case .scanning:
                ProgressView("Checking cache folders").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .moving:
                ProgressView("Rechecking and moving selected caches")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if review.candidates.isEmpty {
                            Text("No supported caches ready to review").foregroundStyle(.secondary)
                        }
                        let groups = Dictionary(grouping: review.candidates, by: \.app)
                        ForEach(groups.keys.sorted(), id: \.self) { app in
                            Text(app).font(.headline).accessibilityAddTraits(.isHeader)
                            if groups[app]?.contains(where: \.running) == true {
                                Text("Quit \(app), then rescan.").foregroundStyle(.secondary)
                            }
                            ForEach(groups[app] ?? []) { candidate in
                                Toggle(isOn: binding(for: candidate.id)) {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(candidate.label)
                                            Text(candidate.url.path)
                                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                        }
                                        Spacer()
                                        Text(diskSize(candidate.bytes)).monospacedDigit()
                                    }
                                }
                                .disabled(candidate.running)
                            }
                            Divider()
                        }
                        let issues = (receipt?.entries.filter { $0.bytes == 0 }.map { $0.name + " · " + $0.detail } ?? []) + review.skipped
                        ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                            Text(issue).foregroundStyle(.secondary)
                        }
                    }
                    .padding(2)
                }
            }

            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(phase == .moving)
                Button("Rescan") {
                    phase = .scanning
                    Task { await scan() }
                }
                .disabled(phase != .ready)
                Spacer()
                Text("\(diskSize(selected.reduce(0) { $0 + $1.bytes })) selected")
                    .foregroundStyle(.secondary)
                Button("Move \(selected.count.formatted()) to Recovery") { confirmsMove = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(phase != .ready || selected.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560, height: 450)
        .task { await scan() }
        .interactiveDismissDisabled(phase == .moving)
        .alert("Move selected caches to Recovery?", isPresented: $confirmsMove) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Recovery") {
                let candidates = selected
                phase = .moving
                Task {
                    error = nil
                    let issues = review.skipped
                    do {
                        receipt = try await Task.detached { try CleanupHistory().move(candidates, reviewedIssues: issues) }.value
                    } catch {
                        self.error = error.localizedDescription
                    }
                    await scan()
                }
            }
        }
    }

    private func binding(for id: URL) -> Binding<Bool> {
        Binding(
            get: { selection.contains(id) },
            set: { if $0 { selection.insert(id) } else { selection.remove(id) } }
        )
    }

    @MainActor
    private func scan() async {
        review = await Task.detached { CacheCleanup.review() }.value
        selection.removeAll()
        phase = .ready
    }
}
