import AppKit
import SwiftUI
import SpyglassKit

enum SettingsTab: String, CaseIterable, Identifiable {
    case plan
    case drive
    case appearance
    case formats
    case updates

    var id: Self { self }

    var title: String {
        switch self {
        case .plan: "Plan"
        case .drive: "Google Drive"
        case .appearance: "Appearance"
        case .formats: "Formats"
        case .updates: "Updates"
        }
    }

    var systemImage: String {
        switch self {
        case .plan: "key"
        case .drive: "icloud"
        case .appearance: "paintbrush"
        case .formats: "doc.text.magnifyingglass"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var selectedTab: SettingsTab? = .plan
    private init() {}
}

/// The preview settings being edited. Every change is written straight to
/// the App Group, where the extension reads it on its next preview.
@MainActor
@Observable
final class PreviewSettingsStore {
    var settings: PreviewSettings {
        didSet { settings.save() }
    }

    init() {
        settings = PreviewSettings.load()
    }
}

struct SettingsView: View {
    @EnvironmentObject private var license: LicenseModel
    @State private var navigation = SettingsNavigation.shared
    @State private var store = PreviewSettingsStore()
    @State private var history: [SettingsTab] = [.plan]
    @State private var historyIndex = 0
    @State private var isHistoryNavigation = false

    /// Google Drive is only listed on plans that include it.
    private var tabs: [SettingsTab] {
        SettingsTab.allCases.filter { $0 != .drive || license.access.allowsDrive }
    }

    private var activeTab: SettingsTab {
        guard let tab = navigation.selectedTab, tabs.contains(tab) else { return .plan }
        return tab
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $navigation.selectedTab) {
                ForEach(tabs) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        .foregroundStyle(.primary)
                        .tag(tab)
                }
                Text(Self.versionString)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fontDesign(.monospaced)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.sidebar)
            .scrollEdgeEffectStyleSoftIfAvailable()
            .navigationTitle("Settings")
            .frame(width: 200)
            .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch activeTab {
                case .plan: PlanSettingsPane()
                case .drive: GoogleDriveSettingsPane()
                case .appearance: AppearanceSettingsPane(store: store)
                case .formats: FormatsSettingsPane(store: store)
                case .updates: UpdatesSettingsPane()
                }
            }
            .navigationTitle(activeTab.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Settings")
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 660, minHeight: 540)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { move(by: -1) } label: { Image(systemName: "chevron.left") }
                    .disabled(historyIndex == 0)
                Button { move(by: 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(historyIndex >= history.count - 1)
            }
        }
        .onChange(of: navigation.selectedTab) { _, tab in
            guard !isHistoryNavigation, let tab, history.last != tab else { return }
            history = Array(history.prefix(historyIndex + 1)) + [tab]
            historyIndex = history.count - 1
        }
    }

    private func move(by step: Int) {
        let target = historyIndex + step
        guard history.indices.contains(target) else { return }
        isHistoryNavigation = true
        historyIndex = target
        navigation.selectedTab = history[target]
        DispatchQueue.main.async { isHistoryNavigation = false }
    }

    private static let versionString: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "Version \(version) (\(build))"
    }()
}

private extension View {
    @ViewBuilder
    func scrollEdgeEffectStyleSoftIfAvailable() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}
