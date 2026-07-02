import SwiftUI
import DrivePeakKit

struct ContentView: View {
    @EnvironmentObject private var auth: GoogleAuth

    // A live sample so users see exactly what a preview looks like.
    @State private var sampleType: WorkspaceType = .doc

    // Tier 1 license (Gumroad). isPro is read from the shared App Group.
    @State private var isPro = LicenseStore().isPro
    @State private var licenseInput = ""
    @State private var activating = false
    @State private var licenseError: String?

    private var sampleStub: Stub {
        Stub(
            type: sampleType,
            title: "Sample \(sampleType.displayName)",
            docID: "1AbCdEf_ExampleDocId_1234567890",
            ownerEmail: "you@example.com"
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            StubCardView(stub: sampleStub)
                .frame(width: 320)
                .id(sampleType)   // re-render card when type changes
        }
        .frame(width: 660, height: 460)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "eye.circle.fill")
                    .font(.system(size: 32)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text("DrivePeak").font(.title2).bold()
                    Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("Good Quick Look previews for Google Workspace files.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Preview a type").font(.headline)
            ForEach(WorkspaceType.allCases, id: \.self) { type in
                Button {
                    sampleType = type
                } label: {
                    Label(".\(type.fileExtension)  \(type.displayName)",
                          systemImage: type.systemImage)
                        .foregroundStyle(type == sampleType ? Color(type) : .primary)
                        .fontWeight(type == sampleType ? .semibold : .regular)
                }
                .buttonStyle(.plain)
            }

            Divider()

            licenseSection

            // Sign-in only matters once Tier 1 is unlocked.
            if isPro {
                Divider()
                authSection
            }

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Label("Press Space on a Google file in Finder.",
                      systemImage: "space")
                Label("Not working? Reopen this app once to register.",
                      systemImage: "arrow.clockwise")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 340, alignment: .topLeading)
    }

    // MARK: - Tier 1 license

    @ViewBuilder
    private var licenseSection: some View {
        if isPro {
            VStack(alignment: .leading, spacing: 4) {
                Label("Tier 1 unlocked", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green).font(.callout).bold()
                Text("Rendered previews for Docs, Sheets, Slides & Drawings.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Unlock Tier 1").font(.headline)
                Text("Rendered document previews — $9, one-time.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    TextField("License key", text: $licenseInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .onSubmit(activate)
                    Button(activating ? "…" : "Unlock", action: activate)
                        .disabled(activating || licenseInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let err = licenseError {
                    Text(err).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
                Link("Buy a key on Gumroad",
                     destination: URL(string: "https://gumroad.com/l/drivepeak")!)
                    .font(.caption2)
            }
        }
    }

    private func activate() {
        let key = licenseInput
        activating = true
        licenseError = nil
        Task {
            do {
                try await LicenseStore().activate(key: key)
                isPro = true
            } catch {
                licenseError = error.localizedDescription
            }
            activating = false
        }
    }

    // MARK: - Google sign-in (Tier 1 only)

    @ViewBuilder
    private var authSection: some View {
        if let email = auth.email {
            VStack(alignment: .leading, spacing: 4) {
                Label(email, systemImage: "person.crop.circle.fill.badge.checkmark")
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .font(.caption)
                Button("Sign out") { auth.signOut() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    Task { try? await auth.signIn() }
                } label: {
                    Label(auth.isSigningIn ? "Signing in…" : "Sign in with Google",
                          systemImage: "person.badge.key")
                }
                .disabled(auth.isSigningIn)   // no concurrent sign-in flows
                Text("Required for rendered previews.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let err = auth.lastError {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
    }
}

#Preview { ContentView().environmentObject(GoogleAuth()) }
