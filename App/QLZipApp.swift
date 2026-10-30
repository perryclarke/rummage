import SwiftUI

@main
struct QLZipApp: App {
    var body: some Scene {
        Window("QLZip", id: "main") {
            VStack(alignment: .leading, spacing: 12) {
                Text("QLZip is installed")
                    .font(.title2.bold())
                Text("Select a .zip, .tar, .tar.gz, .tar.bz2 or .tar.xz file in Finder and press Space to browse its contents.")
                Text("If Quick Look still shows the built-in preview, open System Settings › General › Login Items & Extensions › Quick Look and make sure QLZip Preview is enabled.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(width: 440)
            .fixedSize()
        }
        .windowResizability(.contentSize)
    }
}
