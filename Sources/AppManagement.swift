import AppKit
import SwiftUI

enum AppManagement {
    private static let settings = [
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles"
    ]

    static func openSettings() -> Bool {
        settings.compactMap(URL.init(string:)).contains { NSWorkspace.shared.open($0) }
    }

    static func dragItem(for app: URL) -> NSItemProvider {
        NSItemProvider(object: app as NSURL)
    }

    @MainActor
    static func makeRoomForSettings() {
        let active = NSApp.keyWindow
        guard let window = active?.sheetParent ?? NSApp.mainWindow ?? active,
              let display = window.screen?.visibleFrame else { return }

        var frame = window.frame
        let gutter: CGFloat = 16
        let available = display.width / 2 - 2 * gutter
        guard available >= window.minSize.width else { return }
        frame.size.width = min(frame.width, available)
        frame.origin.x = display.midX - frame.width - gutter
        frame.origin.y = max(display.minY + gutter, display.midY - frame.height / 2)
        window.setFrame(frame, display: true, animate: false)
    }
}

struct AppManagementHelp: View {
    @State private var status: String?
    private let app = Bundle.main.bundleURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Allow app changes").font(.headline)
            Text("Open App Management, then drag Diskfolio into the app list and turn it on.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 13) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 46, height: 46)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Diskfolio.app").fontWeight(.semibold)
                    Text("Drag into App Management")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.15)))
            .contentShape(Rectangle())
            .onDrag { AppManagement.dragItem(for: app) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Diskfolio app icon")
            .accessibilityHint("Drag into the App Management window.")
            .help("Drag the Diskfolio app into the App Management list.")

            HStack {
                Button("Open App Management", action: openSettings)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([app])
                }
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func openSettings() {
        AppManagement.makeRoomForSettings()
        if !AppManagement.openSettings() {
            status = "Open System Settings → Privacy & Security → App Management."
        }
    }
}
