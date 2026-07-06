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
    @State private var hoveringLicense = false
    @State private var hoveringAccount = false

    var body: some View {
        VStack(spacing: 0) {
            if driveBlocked {
                // Full Disk Access is mandatory to read Drive — until it's
                // granted nothing else in the app works, so the popover shows
                // only this gate (no hero, no Form).
                fdaGate
            } else {
                hero
                Divider()
                Form {
                    statusSection
                    if isPro { accountSection }
                }
                .formStyle(.grouped)
            }
            Divider()
            HStack {
                Spacer()
                Button("Quit Spyglass") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                    .buttonStyle(.bordered)
                    .tint(.red)
                Spacer()
            }
            .padding(.vertical, 10)
        }
        .frame(width: 460, height: 520)
        .onAppear {
            // The popover reuses one persistent view, so @State init runs only
            // once at launch. Re-check every time the popover opens, otherwise
            // toggling Full Disk Access while the app is running is never seen.
            driveBlocked = DriveAccess.isBlocked()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Also re-check when returning from System Settings.
            driveBlocked = DriveAccess.isBlocked()
        }
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
                .overlay {
                    Button("Deactivate") {
                        LicenseStore().clear()
                        isPro = false
                    }
                    .buttonStyle(.link)
                    .foregroundStyle(.red)
                    .opacity(hoveringLicense ? 1 : 0)
                }
                .onHover { hoveringLicense = $0 }
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

    private var fdaGate: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Full Disk Access needed")
                .font(.title2).bold()
            Text("Grant Full Disk Access so Spyglass can read your Drive and render previews.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
            Button {
                DriveAccess.openSettings()
            } label: {
                Label("Open Full Disk Access settings", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: 340)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Account (Tier 1 only)

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if let email = auth.email {
                LabeledContent("Google") {
                    Text(email).lineLimit(1).truncationMode(.middle)
                }
                .overlay {
                    Button("Sign out") { auth.signOut() }
                        .buttonStyle(.link)
                        .foregroundStyle(.red)
                        .opacity(hoveringAccount ? 1 : 0)
                }
                .onHover { hoveringAccount = $0 }
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
