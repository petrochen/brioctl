import Carbon.HIToolbox
import XCTest
@testable import BrioctlCore

final class HotkeyTests: XCTestCase {
    func testTheKeys() {
        XCTAssertEqual(HotkeyAction.allCases.map(\.shortcut),
                       ["\u{2303}\u{2325}\u{2318}1", "\u{2303}\u{2325}\u{2318}2", "\u{2303}\u{2325}\u{2318}3",
                        "\u{2303}\u{2325}\u{2318}0", "\u{2303}\u{2325}\u{2318}=", "\u{2303}\u{2325}\u{2318}-"])
        XCTAssertEqual(HotkeyAction.fov90.keyCode, UInt32(kVK_ANSI_1))
        XCTAssertEqual(HotkeyAction.zoomReset.keyCode, UInt32(kVK_ANSI_0))
        XCTAssertEqual(HotkeyAction.zoomIn.keyCode, UInt32(kVK_ANSI_Equal))
        XCTAssertEqual(HotkeyAction.zoomOut.keyCode, UInt32(kVK_ANSI_Minus))
        XCTAssertEqual(HotkeyAction.modifiers, UInt32(controlKey | optionKey | cmdKey))
        XCTAssertEqual(Set(HotkeyAction.allCases.map(\.keyCode)).count, 6)
        XCTAssertEqual(Set(HotkeyAction.allCases.map(\.rawValue)).count, 6)
    }

    private func command(_ action: HotkeyAction, _ state: CameraState) -> [String]? {
        Hotkeys.command(for: action, state: state).map(pairs)
    }

    func testFieldOfView() throws {
        let state = try Fixture.state("state-mxbrio")
        XCTAssertEqual(command(.fov90, state), ["fov=90"])
        XCTAssertEqual(command(.fov78, state), ["fov=78"])
        XCTAssertEqual(command(.fov65, state), ["fov=65"])
    }

    func testOnlyActsIfTheCameraHasTheControl() throws {
        let generic = try Fixture.state("state-generic")
        XCTAssertNil(command(.fov90, generic), "a generic camera has no fov")
        XCTAssertNil(command(.fov65, generic))
        XCTAssertEqual(command(.zoomReset, generic), ["zoom=100"], "it has zoom")

        let noZoom = CameraState(device: generic.device, status: generic.status,
                                 settings: generic.settings.filter { $0.name != "zoom" }, micgain: nil)
        XCTAssertNil(command(.zoomReset, noZoom))
        XCTAssertNil(command(.zoomIn, noZoom))
        XCTAssertNil(command(.zoomOut, noZoom))
    }

    func testAFovThatIsNotOfferedIsNotSent() throws {
        let state = try Fixture.state("state-mxbrio")
        let narrow = Setting(name: "fov", value: .text("90"), group: "Logitech", kind: .choice, choices: ["90", "78"])
        let other = CameraState(device: state.device, status: state.status, settings: [narrow], micgain: nil)
        XCTAssertEqual(command(.fov78, other), ["fov=78"])
        XCTAssertNil(command(.fov65, other))
    }

    func testAReadOnlyControlIsLeftAlone() throws {
        let state = try Fixture.state("state-mxbrio")
        let locked = Setting(name: "fov", value: .text("90"), group: "Logitech", writable: false, kind: .choice,
                             choices: ["90", "78", "65"])
        let other = CameraState(device: state.device, status: state.status, settings: [locked], micgain: nil)
        XCTAssertNil(command(.fov78, other))
    }

    private func zoomState(_ value: Double, min: Double = 100, max: Double = 400, step: Double = 1) -> CameraState {
        let zoom = Setting(name: "zoom", value: .number(value), group: "Framing", kind: .number, min: min, max: max, step: step)
        let base = try! Fixture.state("state-generic")
        return CameraState(device: base.device, status: base.status, settings: [zoom], micgain: nil)
    }

    func testZoomStepsStayInsideTheRange() {
        XCTAssertEqual(command(.zoomIn, zoomState(115)), ["zoom=140"])
        XCTAssertEqual(command(.zoomOut, zoomState(140)), ["zoom=115"])
        XCTAssertEqual(command(.zoomIn, zoomState(390)), ["zoom=400"], "clamped to the maximum")
        XCTAssertNil(command(.zoomIn, zoomState(400)), "already there: nothing to write")
        XCTAssertEqual(command(.zoomOut, zoomState(110)), ["zoom=100"], "clamped to the minimum")
        XCTAssertNil(command(.zoomOut, zoomState(100)))
        XCTAssertEqual(command(.zoomReset, zoomState(250)), ["zoom=100"])
        XCTAssertEqual(command(.zoomIn, zoomState(100, step: 5)), ["zoom=125"])
    }

    func testZoomResetNeedsOneHundredInTheRange() {
        XCTAssertNil(command(.zoomReset, zoomState(200, min: 120)))
    }

    func testRegisteringAndUnregisteringDoesNotCrash() {
        // Carbon accepts the registration without any permission. Another app may own a key: then it is reported.
        let manager = HotkeyManager()
        let failed = manager.register()
        XCTAssertEqual(manager.isRegistered, failed.count < HotkeyAction.allCases.count)
        manager.unregister()
        XCTAssertFalse(manager.isRegistered)
    }
}
