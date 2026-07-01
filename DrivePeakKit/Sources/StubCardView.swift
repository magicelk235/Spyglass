import SwiftUI

public extension Color {
    /// The brand color for a Workspace type.
    init(_ type: WorkspaceType) {
        let c = type.brandColor
        self.init(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: 1)
    }
}

/// The offline "Tier 0" preview card. Always renderable from a parsed stub —
/// no network, no auth. Shows type, title, owner, and a click-to-open link.
///
/// Shared by the Quick Look extension (as the preview) and the host app (as a
/// live sample), so both show an identical card.
public struct StubCardView: View {
    private let stub: Stub
    private var color: Color { Color(stub.type) }

    public init(stub: Stub) {
        self.stub = stub
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            body(in: color)
        }
        .background(.background)
    }

    // Colored banner with the type icon.
    private var header: some View {
        ZStack {
            LinearGradient(
                colors: [color, color.opacity(0.82)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: stub.type.systemImage)
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .frame(height: 150)
    }

    private func body(in color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(stub.title)
                .font(.title2).bold()
                .lineLimit(3)
                .foregroundStyle(.primary)

            Label(stub.type.displayName, systemImage: stub.type.systemImage)
                .font(.subheadline)
                .foregroundStyle(color)

            if let email = stub.ownerEmail {
                Label(email, systemImage: "person.crop.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let url = GoogleURLBuilder.openURL(for: stub) {
                Link(destination: url) {
                    Label("Open in \(stub.type.displayName)", systemImage: "arrow.up.right.square")
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(color, in: .rect(cornerRadius: 8))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Text(url.absoluteString)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#Preview {
    StubCardView(stub: Stub(
        type: .doc,
        title: "Comparative Analysis of Source Reliability",
        docID: "1Ypz5VJ4eL_G2T5CJsXjYOU_4HBuF4J0gn0r-dACtmcc",
        ownerEmail: "demo@example.com"
    ))
    .frame(width: 380, height: 460)
}
