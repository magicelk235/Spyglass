import SwiftUI
import SpyglassKit

/// Single centered column, System-Settings-style grouped Form. Follows the
/// macOS HIG: hero content centered and near the top, controls grouped with
/// native material and negative space, minimal settings.
struct ContentView: View {
    @EnvironmentObject private var auth: GoogleAuth

    @State private var isPro = LicenseStore().isPro
    @State private var licenseInput = ""
    @State private var activating = false
    @State private var licenseError: String?
    @State private var driveBlocked = DriveAccess.isBlocked()

    var body: some View {
        VStack(spacing: 0) {
            hero
            Divider()
            Form {
                statusSection
                if isPro && driveBlocked { fullDiskSection }
                if isPro { accountSection }
            }
            .formStyle(.grouped)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                // Re-check when the user comes back from System Settings.
                driveBlocked = DriveAccess.isBlocked()
            }
            // Invisible: keeps Cmd-Q working without showing a Quit button.
            Button("Quit Spyglass") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .frame(width: 460, height: 520)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 10) {
            Text("Spyglass").font(.title).bold()
            Text("Real Quick Look previews for Google Workspace files")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .padding(.bottom, 22)
    }

    // MARK: - Status / license

    @ViewBuilder
    private var statusSection: some View {
        if isPro {
            Section {
                LabeledContent {
                    Label("Unlocked", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green).labelStyle(.titleAndIcon)
                } label: {
                    Text("Tier 1")
                }
            } header: {
                Text("Rendered previews")
            } footer: {
                Text("Docs, Sheets, Slides and Drawings render their real first page. Forms and Sites show the info card.")
            }
        } else {
            Section {
                HStack(spacing: 8) {
                    TextField("License key", text: $licenseInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(activate)
                    Button(activating ? "Checking…" : "Unlock", action: activate)
                        .buttonStyle(.borderedProminent)
                        .disabled(activating || licenseInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let err = licenseError {
                    Text(err).font(.callout).foregroundStyle(.red)
                }
                Link(destination: URL(string: "https://magicelk235.gumroad.com/l/Spyglass")!) {
                    Label("Buy a key — $9, one-time", systemImage: "cart")
                }
            } header: {
                Text("Unlock Tier 1")
            } footer: {
                Text("Tier 0 info cards work now for all six types, no sign-in. Tier 1 adds real rendered previews.")
            }
        }
    }

    // MARK: - Full Disk Access

    private var fullDiskSection: some View {
        Section {
            Button {
                DriveAccess.openSettings()
            } label: {
                Label("Open Full Disk Access settings", systemImage: "lock.open")
            }
        } header: {
            Text("Action needed")
        } footer: {
            Text("Spyglass needs Full Disk Access to read your Google Drive and render previews. Turn it on for Spyglass, then relaunch.")
        }
    }

    // MARK: - Account (Tier 1 only)

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if let email = auth.email {
                LabeledContent("Google") {
                    HStack(spacing: 8) {
                        Text(email).lineLimit(1).truncationMode(.middle)
                        Button("Sign out") { auth.signOut() }.buttonStyle(.link)
                    }
                }
            } else {
                // Single most important action for an unlocked-but-unconnected
                // user: give it primary weight (one prominent CTA per screen).
                Button {
                    Task { try? await auth.signIn() }
                } label: {
                    Label(auth.isSigningIn ? "Signing in…" : "Sign in with Google",
                          systemImage: "person.badge.key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(auth.isSigningIn)
                if let err = auth.lastError {
                    Text(err).font(.callout).foregroundStyle(.red)
                }
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Sign-in lets Spyglass fetch and render your documents.")
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
}

#Preview { ContentView().environmentObject(GoogleAuth()) }
