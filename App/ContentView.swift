import SwiftUI
import DrivePeakKit

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "eye.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("DrivePeak").font(.largeTitle).bold()
            Text("Quick Look previews for Google Workspace files")
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("Supported types").font(.headline)
                ForEach(WorkspaceType.allCases, id: \.self) { type in
                    Label(".\(type.fileExtension) — \(type.displayName)",
                          systemImage: type.systemImage)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("Press Space on a Google file in Finder to preview it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .padding(32)
        .frame(width: 420)
    }
}
