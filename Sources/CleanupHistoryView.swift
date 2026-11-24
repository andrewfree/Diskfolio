import SwiftUI

struct CleanupHistoryView: View {
    private enum Tab: String, CaseIterable { case recovery = "Recovery", history = "History" }

    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.recovery
    @State private var copies: [CleanupHistory.Copy] = []
    @State private var receipts: [CleanupHistory.Receipt] = []
    @State private var selection: Set<UUID> = []
    @State private var message: String?
    @State private var loading = true
    @State private var confirmsDelete = false
    private let store = CleanupHistory()

    private var selected: [CleanupHistory.Copy] { copies.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cleanup History & Recovery").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            if let message { Text(message).foregroundStyle(.secondary).textSelection(.enabled) }
            if loading {
                ProgressView("Reading cleanup records").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tab == .recovery {
                recovery
            } else {
                history
            }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(loading)
                Spacer()
                if tab == .recovery {
                    Button("Restore Selected") { perform(delete: false) }
                        .disabled(loading || selected.isEmpty || selected.contains(where: \.deleting))
                    Button("Delete Selected…", role: .destructive) { confirmsDelete = true }
                        .disabled(loading || selected.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 590, height: 455)
        .task { await load() }
        .interactiveDismissDisabled(loading)
        .alert("Permanently delete selected recovery copies?", isPresented: $confirmsDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Permanently", role: .destructive) { perform(delete: true) }
        } message: {
            Text("Diskfolio will delete \(selected.count.formatted()) selected copies. You won’t be able to restore them.")
        }
    }

    private var recovery: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(diskSize(copies.compactMap(\.bytes).reduce(0, +))) held in cache recovery")
                .font(.headline)
            if copies.isEmpty { Text("No copies to recover.").foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(copies) { copy in
                        Toggle(isOn: Binding(
                            get: { selection.contains(copy.id) },
                            set: { if $0 { selection.insert(copy.id) } else { selection.remove(copy.id) } }
                        )) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(copy.name)
                                    Text(copy.deleting ? "Deletion incomplete. Select to retry." : copy.source.path)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(copy.bytes.map(diskSize) ?? "Original app").monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var history: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if receipts.isEmpty { Text("No cleanup runs yet.").foregroundStyle(.secondary) }
                ForEach(receipts) { receipt in
                    DisclosureGroup {
                        ForEach(Array(receipt.entries.enumerated()), id: \.offset) { _, item in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.name)
                                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if item.bytes > 0 { Text(diskSize(item.bytes)).monospacedDigit() }
                                if let id = item.recoveryID, copies.contains(where: { $0.id == id }) {
                                    Button("Show in Recovery") {
                                        selection = [id]
                                        tab = .recovery
                                    }
                                }
                            }.padding(.vertical, 4)
                        }
                    } label: {
                        LabeledContent(receipt.title, value: receipt.date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
        }.frame(maxHeight: .infinity, alignment: .top)
    }

    @MainActor
    private func load() async {
        do {
            let store = self.store
            let (copies, receipts) = try await Task.detached { try (store.recovery(), store.history()) }.value
            self.copies = copies
            self.receipts = receipts
        } catch {
            message = error.localizedDescription
        }
        selection.removeAll()
        loading = false
    }

    private func perform(delete: Bool) {
        let selected = self.selected
        let store = self.store
        loading = true
        Task {
            message = await Task.detached {
                let before = store.freeSpace()
                let entries = selected.map { copy in
                    do {
                        if delete { try store.delete(copy) } else { try store.restore(copy) }
                        return CleanupHistory.Entry(name: copy.name, bytes: copy.bytes ?? 0,
                                                    detail: delete ? "Permanently deleted" : "Restored")
                    } catch {
                        return CleanupHistory.Entry(name: copy.name, bytes: 0, detail: error.localizedDescription)
                    }
                }
                let completed = Set(["Restored", "Permanently deleted"])
                let done = entries.filter { completed.contains($0.detail) }.count
                var summary = "\(done.formatted()) \(delete ? "deleted" : "restored") · \(entries.count - done) skipped"
                if delete, let before, let after = store.freeSpace() {
                    let change = after - before
                    summary += " · Volume free space \(change >= 0 ? "+" : "−")\(diskSize(abs(change)))"
                }
                do {
                    try store.save(.init(title: summary, entries: entries))
                } catch {
                    summary += " · Couldn’t save history: \(error.localizedDescription)"
                }
                let issues = entries.filter { !completed.contains($0.detail) }.map { $0.name + " · " + $0.detail }
                return ([summary] + issues).joined(separator: "\n")
            }.value
            await load()
        }
    }
}
