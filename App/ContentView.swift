import SwiftUI
import SpyglassKit

/// The menu-bar popover: what the user has (trial, Pro, Pro + Drive), how to
/// unlock more, and the Google Drive setup for Drive plans. System-Settings
/// style grouped Form, one prominent action at a time.
struct ContentView: View {
    @EnvironmentObject private var auth: GoogleAuth
    @EnvironmentObject private var license: LicenseModel

    @State private var licenseInput = ""
    @State private var driveBlocked = DriveAccess.isBlocked()
    @State private var hoveringLicense = false
    @State private var hoveringAccount = false
    @State private var week = UsageStats.inApp().week()

    var body: some View {
        VStack(spacing: 0) {
            hero
            Divider()
            Form {
                planSection
                if license.access.allowsDrive {
                    driveSection
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack(spacing: 12) {
                Spacer()
                Button("Settings…") { SettingsWindowController.show() }
                    .keyboardShortcut(",")
                    .buttonStyle(.bordered)
                Button("Quit Spyglass") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                    .buttonStyle(.bordered)
                    .tint(.red)
                Spacer()
            }
            .padding(.vertical, 10)
        }
        // Drive plans add the Google Drive section; the rest fits in less.
        .frame(width: 460, height: license.access.allowsDrive ? 560 : 440)
        .onAppear {
            // The popover reuses one view, so re-check each time it opens:
            // the trial counts down and Full Disk Access may have changed.
            license.refresh()
            week = UsageStats.inApp().week()
            driveBlocked = DriveAccess.isBlocked()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            driveBlocked = DriveAccess.isBlocked()
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 8) {
            Text("Spyglass").font(.title).bold()
            Text("Select a file in Finder and press Space.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }

    // MARK: - Plan

    @ViewBuilder
    private var planSection: some View {
        switch license.access {
        case .pro, .proAndDrive:
            ownedSection
        case .notStarted, .trial, .expired:
            unlockSection
        }
    }

    private var ownedSection: some View {
        Section {
            LabeledContent {
                Label("Unlocked", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } label: {
                Text(planName)
            }
            .overlay {
                Button("Deactivate") { license.deactivate() }
                    .buttonStyle(.link)
                    .foregroundStyle(.red)
                    .opacity(hoveringLicense ? 1 : 0)
            }
            .onHover { hoveringLicense = $0 }
            if license.access == .pro {
                if week.drive > 0 {
                    Text(week.drive == 1
                         ? "You opened 1 Google Drive file this week."
                         : "You opened \(week.drive) Google Drive files this week.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Link(destination: checkout(.drive, .driveUpgrade)) {
                    Label("Add Google Drive previews: $4/month", systemImage: "icloud")
                }
            }
        } header: {
            Text("Your plan")
        } footer: {
            Text(planFooter)
        }
    }

    private var planName: String {
        switch license.plan {
        case .legacy: return "Pro + Drive (Spyglass 1.0 license)"
        case .drive:  return "Pro + Drive"
        default:      return "Pro"
        }
    }

    private var planFooter: String {
        license.access == .pro
            ? "Every format preview is yours to keep."
            : "Every format preview, plus your Google Drive documents rendered for real."
    }

    private var unlockSection: some View {
        Section {
            HStack(spacing: 8) {
                TextField("License key", text: $licenseInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(activate)
                Button(license.activating ? "Checking…" : "Unlock", action: activate)
                    .buttonStyle(.borderedProminent)
                    .disabled(license.activating || licenseInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error = license.error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            if let summary = week.summary {
                Label(summary, systemImage: "chart.bar")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Link(destination: checkout(.pro, .pro)) {
                Label("Spyglass Pro: $12 once", systemImage: "cart")
            }
            Link(destination: checkout(.drive, .drive)) {
                Label("Pro + Google Drive: $4/month", systemImage: "icloud")
            }
        } header: {
            Text(trialHeadline)
        } footer: {
            Text(unlockFooter)
        }
    }

    /// Opens Gumroad checkout directly, tagged with this week's usage (see
    /// CheckoutLink for exactly what is shared).
    private func checkout(_ plan: LicenseStore.Plan, _ button: CheckoutLink.Button) -> URL {
        CheckoutLink.url(plan: plan, button: button, access: license.access, week: week)
    }

    private var trialHeadline: String {
        switch license.access {
        case .trial(let days): return days == 1 ? "Free trial: last day" : "Free trial: \(days) days left"
        case .expired:         return license.plan == .drive ? "Drive membership ended" : "Free trial ended"
        default:               return "Free trial"
        }
    }

    private var unlockFooter: String {
        switch license.access {
        case .expired:
            return "Previews now show plain text or a file summary. Paste the key from your Gumroad receipt to unlock them again. Google Drive info cards stay free."
        default:
            return "Every format preview works during the trial. Paste the key from your Gumroad receipt to keep them. Google Drive info cards stay free."
        }
    }

    private func activate() {
        let key = licenseInput
        Task {
            await license.activate(key)
            if license.error == nil { licenseInput = "" }
        }
    }

    // MARK: - Google Drive (Drive plans only)

    @ViewBuilder
    private var driveSection: some View {
        Section {
            if driveBlocked {
                Text("Spyglass needs Full Disk Access to read your Google Drive folder.")
                    .font(.callout)
                Button {
                    DriveAccess.openSettings()
                } label: {
                    Label("Open Full Disk Access settings", systemImage: "lock.shield")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else if let email = auth.email {
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
            Text("Google Drive")
        } footer: {
            Text("Spyglass reads your Drive read-only to render Docs, Sheets, Slides and Drawings.")
        }
    }
}
