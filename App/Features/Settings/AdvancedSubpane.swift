import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AdvancedSubpane: View {
    @ObservedObject private var settings = ClipboardSettings.shared
    @State private var selection: IgnoredApp.ID?
    @State private var extensionSelection: PasswordManagerExtension.ID?
    @State private var showAddExtension = false
    @State private var draftExtName = ""
    @State private var draftExtID = ""

    var body: some View {
        Section {
            Picker(selection: $settings.maxClipSize) {
                ForEach(MaxClipSize.allCases) { size in
                    Text(size.label).tag(size)
                }
            } label: {
                Text("Max clip size")
                Text("Copied text over this limit is ignored, so one huge copy can't bloat "
                     + "the clipboard history.")
            }
            .pickerStyle(.menu)

            Toggle(isOn: $settings.plainTextPreview) {
                Text("Show preview in plain text")
                Text("Render rich-text clips as plain text in the preview pane. Pasting still "
                     + "uses the original formatting.")
            }

            Toggle(isOn: $settings.ignoreConcealedItems) {
                Text("Ignore items marked as concealed/sensitive")
                Text("Skips clipboard contents that apps like 1Password mark as concealed "
                     + "(passwords, secrets), plus copies coming from the password-manager "
                     + "browser extensions listed below, so they are never stored in history.")
            }
        } header: {
            Text("Advanced")
        }

        Section {
            Table(settings.ignoredApps, selection: $selection) {
                TableColumn("") { app in
                    Image(nsImage: AppIconCache.shared.icon(forBundleID: app.bundleID))
                        .resizable()
                        .frame(width: 18, height: 18)
                }
                .width(28)
                TableColumn("Application", value: \.displayName)
                TableColumn("Bundle ID", value: \.bundleID)
            }
            .frame(height: 180)

            HStack {
                Button("Add ignored app", systemImage: "plus", action: addApp)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Add an app to ignore")
                Button("Remove ignored app", systemImage: "minus", action: removeSelected)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Remove the selected app")
                    .disabled(selection == nil)
                Spacer()
                Button("Reset", action: settings.resetIgnoredApps)
            }
        } header: {
            Text("Ignored apps")
        } footer: {
            SettingsFootnote("Apps in this list will not have their clipboard contents captured.")
        }

        Section {
            Table(settings.passwordManagerExtensions, selection: $extensionSelection) {
                TableColumn("Name", value: \.displayName)
                TableColumn("Extension ID", value: \.extensionID)
            }
            .frame(height: 150)

            HStack {
                Button("Add extension", systemImage: "plus") {
                    draftExtName = ""
                    draftExtID = ""
                    showAddExtension = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Add a password-manager extension")
                Button("Remove extension", systemImage: "minus", action: removeSelectedExtension)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Remove the selected extension")
                    .disabled(extensionSelection == nil)
                Spacer()
                Button("Reset", action: settings.resetPasswordManagerExtensions)
            }
        } header: {
            Text("Password manager extensions")
        } footer: {
            SettingsFootnote("Copies made from these browser-extension popups are treated as "
                             + "sensitive (matched by Chromium source URL). Requires “Ignore items "
                             + "marked as concealed/sensitive” above.")
        }
        .disabled(!settings.ignoreConcealedItems)
        .sheet(isPresented: $showAddExtension) {
            addExtensionSheet
        }
    }

    private var addExtensionSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Password Manager Extension")
                .font(.headline)
            Text("Enter the extension's display name and its Chromium extension ID (the 32-character ID in its chrome-extension:// URL).")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Name", text: $draftExtName)
            TextField("Extension ID", text: $draftExtID)
                .font(.system(.body, design: .monospaced))
            HStack {
                Spacer()
                Button("Cancel") { showAddExtension = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: addExtension)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draftExtName.trimmingCharacters(in: .whitespaces).isEmpty
                              || draftExtID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func addExtension() {
        let id = draftExtID.trimmingCharacters(in: .whitespaces)
        let name = draftExtName.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !name.isEmpty else { return }
        var list = settings.passwordManagerExtensions
        guard !list.contains(where: { $0.extensionID == id }) else {
            showAddExtension = false
            return
        }
        list.append(PasswordManagerExtension(extensionID: id, displayName: name))
        settings.passwordManagerExtensions = list
        showAddExtension = false
    }

    private func removeSelectedExtension() {
        guard let id = extensionSelection else { return }
        settings.passwordManagerExtensions.removeAll { $0.id == id }
        extensionSelection = nil
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else { return }
        let name = (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        var apps = settings.ignoredApps
        guard !apps.contains(where: { $0.bundleID == bundleID }) else { return }
        apps.append(IgnoredApp(bundleID: bundleID, displayName: name))
        settings.ignoredApps = apps
    }

    private func removeSelected() {
        guard let id = selection else { return }
        settings.ignoredApps.removeAll { $0.id == id }
        selection = nil
    }
}
