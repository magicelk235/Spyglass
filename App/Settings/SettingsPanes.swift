import SwiftUI
import SpyglassKit

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
                Text("Applies to code, Markdown, tables, and the other format previews. Google Drive previews always match the system.")
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
            } footer: {
                Text("A switched-off format shows as plain text, or as a file summary if it isn't text.")
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
