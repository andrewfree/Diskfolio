import SwiftUI

struct CacheCleanupView: View {
    private enum Phase {
        case scanning, ready, moving
    }

    @Environment(\.dismiss) private var dismiss
    @State private var phase = Phase.scanning
    @State private var review = CacheCleanup.Review()
    @State private var selection: Set<URL> = []
    @State private var receipt: CacheCleanup.Receipt?
    @State private var confirmsMove = false

    private var selected: [CacheCleanup.Candidate] {
        review.candidates.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("App caches")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Quit the apps whose caches you select. Files moved to the Trash still use disk space until you empty it.")
                .foregroundStyle(.secondary)

            if let receipt {
                Text("\(receipt.moved.formatted()) moved to Trash · \(receipt.skipped.count.formatted()) skipped")
                    .font(.headline)
            }

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
                        ForEach(review.candidates) { candidate in
                            Toggle(isOn: binding(for: candidate.id)) {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(candidate.app + " · " + candidate.label)
                                        Text(candidate.url.path(percentEncoded: false))
                                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                    Spacer()
                                    Text(diskSize(candidate.bytes)).monospacedDigit()
                                }
                            }
                            Divider()
                        }
                        ForEach(Array(((receipt?.skipped ?? []) + review.skipped).enumerated()), id: \.offset) { _, issue in
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
                Button("Move \(selected.count.formatted()) to Trash") { confirmsMove = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(phase != .ready || selected.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560, height: 450)
        .task { await scan() }
        .interactiveDismissDisabled(phase == .moving)
        .alert("Move selected caches to the Trash?", isPresented: $confirmsMove) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash") {
                let candidates = selected
                phase = .moving
                Task {
                    receipt = await Task.detached { CacheCleanup.moveToTrash(candidates) }.value
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
