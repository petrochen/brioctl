import AppKit
import SwiftUI

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The content of the menu bar window.
public struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: CameraStore
    @State private var showSettings = false
    @State private var saving = false
    @State private var newName = ""
    @State private var contentHeight: CGFloat = 200

    public static let width: CGFloat = 380
    static let maxBodyHeight: CGFloat = 520

    public init(model: AppModel) {
        self.model = model
        store = model.store
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showSettings {
                ScrollView { SettingsPage(model: model).padding(14) }
                    .frame(height: 430)
            } else {
                mainBody
            }
            Divider()
            footer
        }
        .frame(width: Self.width)
        .onAppear { model.menuOpened() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.menuOpened()
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if showSettings {
                    Button { showSettings = false } label: { Label("Back", systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                    Text("Settings").font(.headline)
                } else if store.cameras.count > 1 {
                    Picker("Camera", selection: cameraBinding) {
                        ForEach(store.cameras) { Text(label(for: $0)).tag($0.index) }
                    }
                    .labelsHidden()
                    .fixedSize()
                } else {
                    Text(store.state?.device.displayName ?? store.selectedCamera?.displayName ?? "brioctl")
                        .font(.headline)
                }
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small) }
                if !showSettings {
                    Button { Task { await store.refresh(clearErrors: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Read the camera again")
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless)
                        .help("Settings")
                }
            }
            if !showSettings, let sub = subtitle {
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
            if !showSettings, let summary = store.state?.status.summary {
                Text(summary).font(.caption)
                    .foregroundStyle(store.state?.status.deskView == true ? Color.orange : Color.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var subtitle: String? {
        guard let device = store.state?.device else { return nil }
        var parts: [String] = []
        if let fw = device.firmware { parts.append("firmware \(fw)") }
        if device.support != "full" { parts.append("\(device.support) support") }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    private func label(for camera: CameraInfo) -> String {
        camera.support == "full" ? camera.displayName : "\(camera.displayName) (\(camera.support))"
    }

    private var cameraBinding: Binding<Int> {
        Binding(
            get: { store.selectedCamera?.index ?? 0 },
            set: { index in
                if let camera = store.cameras.first(where: { $0.index == index }) {
                    Task { await store.selectCamera(camera) }
                }
            })
    }

    // MARK: body

    private var mainBody: some View {
        VStack(spacing: 0) {
            if let banner = store.banner {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(banner).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(Color.red.opacity(0.12))
            }
            ScrollView {
                content
                    .padding(14)
                    .background(GeometryReader { Color.clear.preference(key: ContentHeightKey.self, value: $0.size.height) })
            }
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            .frame(height: min(max(contentHeight, 60), Self.maxBodyHeight))
        }
    }

    @ViewBuilder private var content: some View {
        if model.cliMissing {
            placeholder("The brioctl program inside the app was not found.", symbol: "exclamationmark.triangle")
        } else if let state = store.state {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(state.sections) { section in
                    SettingsSectionView(section: section, store: store)
                }
                if let gain = state.micgain {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Microphone").font(.subheadline).foregroundStyle(.secondary)
                        MicGainRow(current: gain, store: store)
                    }
                }
                if let notice = store.notice {
                    Label(notice, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if store.isLoading {
            placeholder("Reading the camera\u{2026}", symbol: nil)
        } else if store.cameras.isEmpty {
            placeholder("No UVC camera found.", symbol: "video.slash")
        } else {
            placeholder("The camera did not answer.", symbol: "video.slash")
        }
    }

    private func placeholder(_ text: String, symbol: String?) -> some View {
        VStack(spacing: 8) {
            if let symbol { Image(systemName: symbol).font(.title) }
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }

    // MARK: footer

    @ViewBuilder private var footer: some View {
        if saving {
            HStack(spacing: 6) {
                TextField("Name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save", action: save).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { saving = false }
            }
            .padding(10)
        } else {
            HStack {
                presetsMenu
                Button("Save current as\u{2026}") {
                    newName = ""
                    saving = true
                }
                .disabled(store.state == nil)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .padding(10)
        }
    }

    private func save() {
        let name = newName
        if store.profiles?.saved.contains(name.trimmingCharacters(in: .whitespaces)) == true,
           !store.confirm("Replace \u{201C}\(name)\u{201D}?", "The saved settings with this name are overwritten.", "Replace") {
            return
        }
        saving = false
        Task { await store.saveCurrent(as: name) }
    }

    private var presetsMenu: some View {
        Menu {
            if let profiles = store.profiles {
                Section("Presets") {
                    ForEach(profiles.presets) { preset in
                        Button("\(preset.name)  \u{2014}  \(preset.summary)") { Task { await store.apply(profile: preset.name) } }
                            .disabled(!canApply(preset))
                    }
                }
                if !profiles.saved.isEmpty {
                    Section("Saved") {
                        ForEach(profiles.saved, id: \.self) { name in
                            Button(name) { Task { await store.apply(profile: name) } }
                        }
                    }
                }
            }
        } label: {
            Label("Presets", systemImage: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(store.state == nil)
    }

    /// A preset can be applied when the camera has every setting in it and can write it now.
    private func canApply(_ preset: Preset) -> Bool {
        guard let state = store.state else { return false }
        return preset.settings.allSatisfy { state.setting($0.name)?.writable == true }
    }
}

struct SettingsSectionView: View {
    let section: SettingsSection
    @ObservedObject var store: CameraStore

    private var isCollapsed: Bool { store.collapsed.contains(section.group) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if isCollapsed { store.collapsed.remove(section.group) } else { store.collapsed.insert(section.group) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down").font(.caption2).frame(width: 10)
                    Text(section.group).font(.subheadline)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !isCollapsed {
                ForEach(section.settings) { SettingRow(setting: $0, store: store) }
            }
        }
    }
}
