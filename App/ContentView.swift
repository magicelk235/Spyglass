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
                .frame(width: 300)
                .id(sampleType)   // re-render card when type changes
        }
        .frame(width: 640, height: 440)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            header
            typePicker
            licenseSection
            if isPro { authSection }
            Spacer()
            footer
        }
        .padding(28)
        .frame(width: 340, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "mountain.2.fill")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("DrivePeak").font(.title2).bold()
                Text("Previews for Google Workspace files")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // Compact menu picker replaces the six-button list — one row, not six.
    private var typePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview").font(.subheadline).foregroundStyle(.secondary)
            Picker("", selection: $sampleType) {
                ForEach(WorkspaceType.allCases, id: \.self) { type in
                    Label(type.displayName, systemImage: type.systemImage).tag(type)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    // MARK: - Tier 1 license

    @ViewBuilder
    private var licenseSection: some View {
        if isPro {
            Label("Tier 1 unlocked", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green).font(.subheadline).bold()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unlock Tier 1").font(.subheadline).bold()
                    Text("Rendered previews · $9 once")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                Link("Buy a key", destination: URL(string: "https://gumroad.com/l/drivepeak")!)
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
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.fill.badge.checkmark")
                    .foregroundStyle(.green)
                Text(email).lineLimit(1).font(.caption)
                Spacer()
                Button("Sign out") { auth.signOut() }
                    .buttonStyle(.link).font(.caption)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    Task { try? await auth.signIn() }
                } label: {
                    Label(auth.isSigningIn ? "Signing in…" : "Sign in with Google",
                          systemImage: "person.badge.key")
                }
                .disabled(auth.isSigningIn)
                if let err = auth.lastError {
                    Text(err).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
        }
    }

    private var footer: some View {
        Label("Press Space on a Google file in Finder.", systemImage: "space")
            .font(.caption).foregroundStyle(.secondary)
    }
}

#Preview { ContentView().environmentObject(GoogleAuth()) }
