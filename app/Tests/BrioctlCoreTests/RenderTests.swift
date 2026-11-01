import AppKit
import SwiftUI
import XCTest
@testable import BrioctlCore

/// Draws the views off screen into PNG files, to look at the layout without clicking anything. Only runs when
/// BRIOCTL_RENDER_DIR names a directory:  BRIOCTL_RENDER_DIR=/tmp/shots swift test --filter RenderTests
@MainActor
final class RenderTests: XCTestCase {
    private func png<V: View>(_ view: V, size: NSSize, dark: Bool, to url: URL) throws {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize
        host.frame = NSRect(origin: .zero, size: NSSize(width: size.width, height: max(fitting.height, 50)))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    func testRenderScreens() async throws {
        guard let out = ProcessInfo.processInfo.environment["BRIOCTL_RENDER_DIR"] else {
            throw XCTSkip("BRIOCTL_RENDER_DIR is not set")
        }
        let dir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fake = try FakeCLI(snapshots: ["mxbrio-1.1.394.snap", "generic-uvc.snap", "brio500-sim.snap"])
        defer { fake.cleanUp() }
        let suite = "com.github.petrochen.brioctl.app.tests.render"
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        let env = AppEnvironment(processEnvironment: fake.environment.merging([
            "BRIOCTL_APP_CLI": fake.executable.path, "BRIOCTL_APP_AGENTS_DIR": fake.home.appendingPathComponent("agents").path,
            "BRIOCTL_APP_DEFAULTS_SUITE": suite]) { $1 }, bundle: Bundle(for: RenderTests.self), home: fake.home)
        let model = AppModel(environment: env, launchctl: RecordingLaunchctl())
        await model.store.refresh()
        model.store.collapsed = []

        for dark in [false, true] {
            let tag = dark ? "dark" : "light"
            try png(RootView(model: model), size: NSSize(width: RootView.width, height: 800), dark: dark,
                    to: dir.appendingPathComponent("main-\(tag).png"))
        }
        await model.store.write([("exposure", "100"), ("fov", "55")])
        try png(RootView(model: model), size: NSSize(width: RootView.width, height: 800), dark: false,
                to: dir.appendingPathComponent("errors-light.png"))
        // every section in full, as the scroll view would show them one after the other
        let state = try XCTUnwrap(model.store.state)
        try png(VStack(alignment: .leading, spacing: 14) {
            ForEach(state.sections) { SettingsSectionView(section: $0, store: model.store) }
            if let gain = state.micgain { MicGainRow(current: gain, store: model.store) }
        }.padding(14).frame(width: RootView.width), size: NSSize(width: RootView.width, height: 800), dark: true,
                to: dir.appendingPathComponent("all-dark.png"))
        try png(ScrollView { SettingsPage(model: model).padding(14) }, size: NSSize(width: RootView.width, height: 480),
                dark: false, to: dir.appendingPathComponent("settings-light.png"))
    }
}
