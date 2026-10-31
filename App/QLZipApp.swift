import AppKit
import SwiftUI

@main
struct QLZipApp: App {
    var body: some Scene {
        Window("QLZip", id: "main") {
            WelcomeView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// The app's only window. QLZip.app exists to carry the Quick Look extension, so this just
/// confirms the install and explains how to use, enable and remove it.
struct WelcomeView: View {
    /// Opens System Settings › General › Login Items & Extensions with the Quick Look list showing.
    private static let quickLookSettings = URL(
        string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.quicklook.preview")!

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            InfoSection("Using QLZip") {
                Step(symbol: "eye", title: "Preview an archive",
                     detail: "Select a .zip, .tar, .tar.gz, .tar.bz2 or .tar.xz file in Finder and press Space.")
                Step(symbol: "list.bullet.indent", title: "Look inside",
                     detail: "Expand folders in the list and click a file to preview it.")
                Step(symbol: "arrow.down.doc", title: "Uncompress only what you need",
                     detail: "Double-click an item, or Control-click a selection, then choose a folder.")
            }

            InfoSection("If Finder shows the standard preview") {
                Step(symbol: "switch.2", title: "Turn on QLZip Preview",
                     detail: "It’s in System Settings › General › Login Items & Extensions › Quick Look.")
                HStack {
                    Spacer()
                    Button("Open Quick Look Settings") { NSWorkspace.shared.open(Self.quickLookSettings) }
                }
            }

            InfoSection("Uninstalling") {
                Step(symbol: "trash", title: "Move QLZip to the Trash",
                     detail: "Finder stops using the extension once macOS notices the app is gone, which can take until Finder relaunches or you log out.")
                Step(symbol: "eye.slash", title: "Or just turn the previews off",
                     detail: "Switch off QLZip Preview in Quick Look settings to go back to the standard preview.")
                HStack {
                    Spacer()
                    Button("Show QLZip in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                }
            }

            footer
        }
        .padding(24)
        .frame(width: 560)
        .fixedSize()
        .background(WindowCenterer())
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text("QLZip is installed")
                    .font(.title2.bold())
                Text("Browse archives in Quick Look without extracting them.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        let info = Bundle.main.infoDictionary ?? [:]
        let parts = [
            (info["CFBundleShortVersionString"] as? String).map { "Version \($0)" },
            info["NSHumanReadableCopyright"] as? String,
        ]
        return Text(parts.compactMap { $0 }.joined(separator: " · "))
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
    }
}

/// A titled group of rows on a rounded background, like a section of System Settings.
private struct InfoSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor)))
        }
    }
}

/// Centers the window each time it opens. Otherwise macOS restores the last position, and a
/// window saved by an older, shorter version of this panel would open running off the screen.
private struct WindowCenterer: NSViewRepresentable {
    final class View: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // SwiftUI sizes the window to the content after this, so center once that's done.
            Task { @MainActor [weak self] in self?.window?.center() }
        }
    }

    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ view: View, context: Context) {}
}

/// A symbol beside a short title and a line or two of explanation.
private struct Step: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.semibold)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
