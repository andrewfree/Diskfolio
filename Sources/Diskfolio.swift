import AppKit
import SwiftUI

private let ink = Color(red: 0.063, green: 0.082, blue: 0.125)
private let panel = Color(red: 0.098, green: 0.127, blue: 0.180)
private let light = Color(red: 0.91, green: 0.94, blue: 0.99)
private let muted = Color(red: 0.65, green: 0.70, blue: 0.79)
private let rule = Color.white.opacity(0.10)
private let mint = Color(red: 0.53, green: 0.91, blue: 0.73)
private let peach = Color(red: 0.96, green: 0.75, blue: 0.53)

@main
struct Diskfolio: App {
    @StateObject private var model: InventoryModel

    init() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let status = CleanupCommand.run(arguments) { exit(status) }
        if arguments.first == "--scan-json" {
            guard arguments.count == 2 else {
                FileHandle.standardError.write(Data("Usage: Diskfolio --scan-json <folder>\n".utf8))
                exit(64)
            }
            Self.printJSON { try Scanner.scan(URL(fileURLWithPath: arguments[1], isDirectory: true)) }
        }
        let roots = arguments.dropFirst().map { URL(fileURLWithPath: $0, isDirectory: true) }
        if arguments.first == "--inventory-json" {
            Self.printJSON { try AppInventory.scan(roots: roots.isEmpty ? AppInventory.roots : roots, requireRoots: !roots.isEmpty) }
        }
        guard arguments.isEmpty || (arguments.first == "--inventory-roots" && !roots.isEmpty) else {
            FileHandle.standardError.write(Data(("Unrecognized command. Run diskfolio --help.\n").utf8))
            exit(64)
        }
        let launchRoots = roots.isEmpty ? AppInventory.roots : roots
        _model = StateObject(wrappedValue: InventoryModel(roots: launchRoots))
    }

    var body: some Scene {
        Window("Diskfolio", id: "inventory") {
            InventoryView(model: model)
                .frame(minWidth: 560, minHeight: 510)
                .preferredColorScheme(.dark)
                .task { model.start() }
        }
        .defaultSize(width: 690, height: 710)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Rescan Apps", action: model.rescan).keyboardShortcut("r").disabled(model.isWorking || model.showsCleanup)
            }
        }
    }

    static func printJSON<T: Encodable>(_ value: () throws -> T) -> Never {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(value()))
            FileHandle.standardOutput.write(Data([10]))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}

private struct InventoryView: View {
    @ObservedObject var model: InventoryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showAll = false
    @State private var showsCaches = false
    @State private var lastCleanup: CleanupBatchResult?

    var body: some View {
        VStack(spacing: 0) {
            top
            Divider().overlay(rule)
            if let lastCleanup {
                CleanupResultSummary(result: lastCleanup)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 27)
                    .padding(.vertical, 12)
                    .background(panel)
                Divider().overlay(rule)
            }
            switch model.phase {
            case .idle:
                loading(done: 0, total: 0)
            case let .scanning(done, total):
                loading(done: done, total: total)
            case let .verifying(done, total, app):
                verifying(done: done, total: total, app: app)
            case let .ready(report, preview):
                results(report, preview: preview)
            case let .failed(message):
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 32)).foregroundStyle(peach)
                    Text("Couldn’t inspect apps").font(.system(size: 25, weight: .semibold))
                    Text(message).foregroundStyle(muted).multilineTextAlignment(.center)
                    Button("Try again", action: model.rescan)
                }
                .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: model.isWorking) { if $0 { showAll = false } }
        .sheet(isPresented: $model.showsCleanup) {
            if case let .ready(_, preview) = model.phase {
                CleanupView(preview: preview, groups: model.selection) { result in
                    lastCleanup = result
                    model.showsCleanup = false
                    model.rescan()
                }
            }
        }
        .sheet(isPresented: $showsCaches) { CacheCleanupView() }
        .background(ink)
        .foregroundStyle(light)
        .font(.system(size: 13))
    }

    private var top: some View {
        HStack(spacing: 11) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(mint)
                .frame(width: 32, height: 32)
                .background(mint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            Text("Diskfolio").font(.system(size: 18, weight: .semibold, design: .rounded))
            Spacer()
            Button {
                showsCaches = true
            } label: {
                Label("App Caches", systemImage: "folder")
            }.buttonStyle(.bordered)
            Button {
                model.rescan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }.buttonStyle(.bordered)
            .disabled(model.isWorking || model.showsCleanup)
            Button {
                model.showsCleanup = true
            } label: {
                Label("Free Space", systemImage: "internaldrive")
            }
            .buttonStyle(.borderedProminent)
            .tint(mint)
            .foregroundStyle(ink)
            .disabled(!canClean)
        }
        .padding(.horizontal, 27)
        .frame(height: 60)
    }

    private var canClean: Bool {
        if case let .ready(_, preview) = model.phase {
            return !preview.apps.isEmpty
        }
        return false
    }

    private func loading(done: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Read-only inventory scan")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
            if total > 0 {
                ProgressView(value: Double(done), total: Double(total))
                    .tint(mint)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: done)
                Text("\(done) of \(total) app bundles inspected")
                    .monospacedDigit().foregroundStyle(muted)
            } else {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Finding app bundles").foregroundStyle(muted)
                }
            }
        }
        .frame(maxWidth: 345)
        .padding(33)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func verifying(done: Int, total: Int, app: URL) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text("Checking what can be cleaned")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
            }
            ProgressView(value: Double(done), total: Double(total)) {
                Text(app.lastPathComponent).lineLimit(1)
            } currentValueLabel: {
                Text("\(done) of \(total) apps checked").monospacedDigit().foregroundStyle(muted)
            }
            .tint(mint)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: done)
        }
        .frame(maxWidth: 380)
        .padding(33)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func results(_ report: InventoryReport, preview: CleanupBatchPreview) -> some View {
        let size = preview.bytes
        let apps = model.rankedApps(preview.apps.map { AppResources(url: $0.url, size: $0.bytes) })
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summary(size, ready: apps.count, scanned: report.scanned)
                HStack(alignment: .top, spacing: 10) {
                    category(.architecture, size: size, report: report)
                    category(.language, size: size, report: report)
                }
                if !apps.isEmpty {
                    appList(apps)
                }
                CleanupIssues(issues: preview.issues, title: "skipped")
                VStack(alignment: .leading, spacing: 5) {
                    Text("Sizes are logical bytes. Actual disk space reclaimed depends on APFS and how apps are packaged.")
                    if report.unreadable > 0 {
                        Text("\(report.unreadable.formatted()) unreadable or offline entries were omitted.")
                    }
                }
                .font(.system(size: 11)).foregroundStyle(muted)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(27)
        }
    }

    private func summary(_ size: InventorySize, ready: Int, scanned: Int) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Verified cleanup preview")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(muted)
                .accessibilityAddTraits(.isHeader)
            if ready == 0 {
                Text(model.selection.isEmpty ? "Select a category to check" : "Nothing ready to clean")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
            } else {
                Text(diskSize(size.total))
                    .font(.system(size: 59, weight: .semibold, design: .rounded))
                    .monospacedDigit().tracking(-2)
                    .accessibilityLabel("\(diskSize(size.total)) verified for cleanup")
                    .accessibilityValue("\(size.total.formatted()) logical bytes")
                SizeTrack(size: size, scale: size.total, selection: model.selection, height: 12)
            }
            HStack(alignment: .firstTextBaseline) {
                if ready > 0 {
                    Text("\(ready.formatted()) \(ready == 1 ? "app" : "apps") ready to review")
                    Spacer(minLength: 8)
                }
                Text("\(scanned.formatted()) \(scanned == 1 ? "app" : "apps") inspected")
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(muted)
        }
        .padding(21)
        .background(panel, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(rule).allowsHitTesting(false))
    }

    private func category(_ group: ResourceGroup, size: InventorySize, report: InventoryReport) -> some View {
        let color = group == .architecture ? mint : peach
        let bytes = group.bytes(in: size)
        let detail = group == .architecture
            ? "Keeps \(report.preference.architecture == "arm64" ? "Apple Silicon" : "Intel") code"
            : "Keeps \(report.preference.languages.map(languageName).joined(separator: ", ")), Base, and app fallback languages"
        return VStack(alignment: .leading, spacing: 7) {
            Toggle(isOn: Binding(get: { model.selection.contains(group) }, set: { model.toggle(group, on: $0) })) {
                Label(group.title, systemImage: group.icon)
                    .font(.system(size: 13, weight: .semibold))
            }.toggleStyle(.checkbox).tint(color)
            Text(model.selection.contains(group) ? diskSize(bytes) : "Off")
                .font(.system(size: 23, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(color)
            Text(detail).font(.system(size: 11)).foregroundStyle(muted)
                .lineLimit(2).help(detail)
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 115, alignment: .topLeading)
        .background(panel.opacity(0.73), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(rule).allowsHitTesting(false))
    }

    private func appList(_ ranked: [AppResources]) -> some View {
        let maxBytes = ranked.first?.size.total ?? 0
        let apps = showAll ? ranked[...] : ranked.prefix(5)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("By app").font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if ranked.count > 5 {
                    Button(showAll ? "Show top 5" : "Show all \(ranked.count)", action: { showAll.toggle() })
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            LazyVStack(spacing: 0) {
                ForEach(apps) { app in
                    appRow(app, scale: maxBytes)
                    Divider().overlay(rule).accessibilityHidden(true)
                }
            }
        }
    }

    private func appRow(_ app: AppResources, scale: Int64) -> some View {
        let bytes = model.selectedBytes(in: app.size)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer()
                Text(diskSize(bytes)).monospacedDigit().foregroundStyle(muted)
            }
            SizeTrack(size: app.size, scale: scale, selection: model.selection, height: 5, anchorsLanguages: false)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(app.name), \(diskSize(bytes)) verified")
        .accessibilityValue("\(diskSize(app.size.architecture)) architecture, \(diskSize(app.size.language)) languages")
        .help("\(app.url.path)\n\(diskSize(app.size.architecture)) architecture · \(diskSize(app.size.language)) languages")
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
        }
    }
}

private struct SizeTrack: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false
    let size: InventorySize
    let scale: Int64
    let selection: Set<ResourceGroup>
    let height: CGFloat
    var anchorsLanguages = true

    var body: some View {
        GeometryReader { geometry in
            let factor = scale > 0 ? geometry.size.width / CGFloat(scale) : 0
            let architectureWidth = CGFloat(size.architecture) * factor
            let languageWidth = CGFloat(size.language) * factor
            ZStack(alignment: .leading) {
                Rectangle().fill(rule)
                Rectangle()
                    .fill(mint)
                    .frame(width: (drawn || reduceMotion) && selection.contains(.architecture) ? architectureWidth : 0)
                Rectangle()
                    .fill(peach)
                    .frame(width: (drawn || reduceMotion) && selection.contains(.language) ? languageWidth : 0)
                    .offset(x: anchorsLanguages || selection.contains(.architecture) ? architectureWidth : 0)
            }
            .clipShape(Capsule())
            .animation(reduceMotion ? nil : .timingCurve(0.22, 0.68, 0.26, 1, duration: 0.36), value: selection)
        }
        .frame(height: height)
        .onAppear {
            withAnimation(reduceMotion ? nil : .timingCurve(0.22, 0.68, 0.26, 1, duration: 0.42)) {
                drawn = true
            }
        }
        .accessibilityHidden(true)
    }
}
