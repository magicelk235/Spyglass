import SwiftUI
import SpyglassKit

/// Trial status and unlocking for anyone without a plan; the owned plan,
/// with a Drive upgrade for Pro, for everyone else.
struct PlanSettingsPane: View {
    @EnvironmentObject private var license: LicenseModel

    @State private var licenseInput = ""
    @State private var confirmingDeactivate = false
    @State private var week = UsageStats.inApp().week()

    var body: some View {
        Form {
            switch license.access {
            case .pro, .proAndDrive:
                ownedSection
            case .notStarted, .trial, .expired:
                unlockSection
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear {
            // The trial counts down and the week rolls over while the app runs.
            license.refresh()
            week = UsageStats.inApp().week()
        }
    }

    private var ownedSection: some View {
        Section {
            LabeledContent(planName) {
                Button("Deactivate…") { confirmingDeactivate = true }
            }
            .alert("Deactivate Spyglass on this Mac?", isPresented: $confirmingDeactivate) {
                Button("Deactivate", role: .destructive) { license.deactivate() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Rich previews stop until you paste your license key again.")
            }
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
        }
    }

    private var planName: String {
        license.access == .proAndDrive ? "Drive" : "Pro"
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
                Label("Spyglass Drive: $4/month", systemImage: "icloud")
            }
        } header: {
            Text(trialHeadline)
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

    private func activate() {
        let key = licenseInput
        Task {
            await license.activate(key)
            if license.error == nil { licenseInput = "" }
        }
    }
}

/// Google sign-in and Full Disk Access. Only listed on Drive plans.
struct GoogleDriveSettingsPane: View {
    @EnvironmentObject private var auth: GoogleAuth

    @State private var driveBlocked = DriveAccess.isBlocked()

    var body: some View {
        Form {
            Section {
                if driveBlocked {
                    Button {
                        DriveAccess.openSettings()
                    } label: {
                        Label("Open Full Disk Access settings", systemImage: "lock.shield")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else if let email = auth.email {
                    LabeledContent(email) {
                        Button("Sign Out") { auth.signOut() }
                    }
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
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear {
            auth.restore()
            driveBlocked = DriveAccess.isBlocked()
        }
        // Full Disk Access is granted in System Settings; re-check on return.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            driveBlocked = DriveAccess.isBlocked()
        }
    }
}

struct AppearanceSettingsPane: View {
    @Bindable var store: PreviewSettingsStore

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $store.settings.theme) {
                    Text("Match System").tag(PreviewSettings.Theme.system)
                    Text("Light").tag(PreviewSettings.Theme.light)
                    Text("Dark").tag(PreviewSettings.Theme.dark)
                }
                .pickerStyle(.menu)
            } header: {
                Text("Previews")
            } footer: {
                Text("Google Drive previews always match the system.")
            }

            Section("Code") {
                LabeledContent("Font size") {
                    HStack(spacing: 12) {
                        Slider(value: $store.settings.codeFontSize,
                               in: PreviewSettings.fontSizeRange, step: 1)
                            .frame(width: 180)
                        Text("\(Int(store.settings.codeFontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}

struct FormatsSettingsPane: View {
    @Bindable var store: PreviewSettingsStore

    var body: some View {
        Form {
            Section {
                ForEach(FormatGroup.allCases, id: \.self) { group in
                    Toggle(group.displayName, isOn: enabled(group))
                        .toggleStyle(.switch)
                }
            } header: {
                Text("Rich previews")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }

    private func enabled(_ group: FormatGroup) -> Binding<Bool> {
        Binding(
            get: { store.settings.isEnabled(group) },
            set: { on in
                if on { store.settings.disabledGroups.remove(group) }
                else { store.settings.disabledGroups.insert(group) }
            }
        )
    }
}

struct UpdatesSettingsPane: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))
                .toggleStyle(.switch)
                LabeledContent("Version \(Self.version)") {
                    Button("Check Now") { updater.checkForUpdates() }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }

    private static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
}
