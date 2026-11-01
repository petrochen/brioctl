import XCTest
@testable import BrioctlCore

final class ControlMappingTests: XCTestCase {
    func testKindsBecomeControls() throws {
        let state = try Fixture.state("state-mxbrio")
        func style(_ name: String) -> ControlStyle { ControlMapping.style(for: state.setting(name)!) }
        XCTAssertEqual(style("fov"), .segmented(["90", "78", "65"]))
        XCTAssertEqual(style("priority"), .segmented(["fps", "exposure"]))
        XCTAssertEqual(style("flicker"), .segmented(["50", "60"]))
        XCTAssertEqual(style("showmode"), .toggle)
        XCTAssertEqual(style("mic"), .toggle)
        XCTAssertEqual(style("awb"), .toggle)
        XCTAssertEqual(style("zoom"), .slider(min: 100, max: 400, step: 1))
        XCTAssertEqual(style("warmth"), .slider(min: 0, max: 100, step: 1))
        XCTAssertEqual(style("pan"), .slider(min: -20, max: 20, step: 1))
    }

    func testChoicesAboveFourBecomeAPopup() {
        func choice(_ n: Int) -> Setting {
            Setting(name: "x", value: .text("0"), group: "g", kind: .choice, choices: (0..<n).map(String.init))
        }
        XCTAssertEqual(ControlMapping.style(for: choice(4)), .segmented(["0", "1", "2", "3"]))
        XCTAssertEqual(ControlMapping.style(for: choice(5)), .popup(["0", "1", "2", "3", "4"]))
        XCTAssertEqual(ControlMapping.style(for: choice(0)), .valueOnly)
    }

    func testNumberWithoutARangeHasNoSlider() {
        let flat = Setting(name: "x", value: .number(1), group: "g", kind: .number, min: 5, max: 5, step: 1)
        XCTAssertEqual(ControlMapping.style(for: flat), .valueOnly)
        let noStep = Setting(name: "x", value: .number(1), group: "g", kind: .number, min: 0, max: 10)
        XCTAssertEqual(ControlMapping.style(for: noStep), .slider(min: 0, max: 10, step: 1))
    }

    func testReadOnlySettingsGetAHint() throws {
        let state = try Fixture.state("state-mxbrio")
        XCTAssertEqual(ControlMapping.disabledHint(for: state.setting("exposure")!), "set automatically")
        XCTAssertEqual(ControlMapping.disabledHint(for: state.setting("wb")!), "set automatically")
        XCTAssertNil(ControlMapping.disabledHint(for: state.setting("fov")!))
        let privacy = try Fixture.state("state-generic-extra").setting("privacy")!
        XCTAssertEqual(ControlMapping.disabledHint(for: privacy), "read-only")
    }

    func testCaptionDropsTheListOfChoicesOnly() throws {
        let state = try Fixture.state("state-mxbrio")
        XCTAssertEqual(ControlMapping.caption(for: state.setting("fov")!), "field of view in degrees")
        XCTAssertEqual(ControlMapping.caption(for: state.setting("hdr")!), "HDR (UVC backlight compensation)")
        XCTAssertEqual(ControlMapping.caption(for: state.setting("flicker")!), "anti-flicker, mains frequency in Hz")
        // it says more than on/off: kept whole
        XCTAssertEqual(ControlMapping.caption(for: state.setting("mic")!), "camera microphone: on, off (camera restarts on change)")
        XCTAssertEqual(ControlMapping.caption(for: state.setting("zoom")!), "zoom, 100 = 1x on Logitech cameras")
    }

    func testSliderValuesSnapToTheStep() {
        XCTAssertEqual(ControlMapping.snapped(115.4, min: 100, max: 400, step: 1), 115)
        XCTAssertEqual(ControlMapping.snapped(999, min: 100, max: 400, step: 1), 400)
        XCTAssertEqual(ControlMapping.snapped(-3, min: 0, max: 1, step: 0.01), 0)
        XCTAssertEqual(ControlMapping.snapped(0.2849, min: 0, max: 1, step: 0.01), 0.28, accuracy: 1e-9)
        XCTAssertEqual(ControlMapping.micGainArgument(0.28), "0.28")
        XCTAssertEqual(ControlMapping.argument(forNumber: 115), "115")
    }

    func testTheMenuBarSymbolExists() {
        XCTAssertNotNil(NSImage(systemSymbolName: "web.camera", accessibilityDescription: nil))
    }
}

final class CLIArgumentsTests: XCTestCase {
    func testReads() {
        XCTAssertEqual(CLIArguments.list(), ["list", "--json"])
        XCTAssertEqual(CLIArguments.state(camera: nil), ["--json"])
        XCTAssertEqual(CLIArguments.state(camera: "2"), ["--camera", "2", "--json"])
        XCTAssertEqual(CLIArguments.profiles(), ["profiles", "--json"])
        XCTAssertEqual(CLIArguments.version(), ["--version"])
    }

    func testSettingsAreNameValuePairs() {
        XCTAssertEqual(CLIArguments.set(camera: nil, [("fov", "78")]), ["fov", "78"])
        XCTAssertEqual(CLIArguments.set(camera: nil, [("fov", "78"), ("zoom", "115"), ("hdr", "off")]),
                       ["fov", "78", "zoom", "115", "hdr", "off"])
        XCTAssertEqual(CLIArguments.set(camera: "ABC123", [("pan", "-5")]), ["--camera", "ABC123", "pan", "-5"])
        XCTAssertEqual(CLIArguments.set(camera: "", [("fov", "65")]), ["fov", "65"])
    }

    func testSaveAndApply() {
        XCTAssertEqual(CLIArguments.save(camera: nil), ["save"])
        XCTAssertEqual(CLIArguments.save(camera: "3", name: "evening"), ["--camera", "3", "save", "evening"])
        XCTAssertEqual(CLIArguments.apply(camera: nil, name: "warmer"), ["apply", "warmer"])
        XCTAssertEqual(CLIArguments.apply(camera: "2", name: "my file"), ["--camera", "2", "apply", "my file"])
    }

    func testErrorsAreAttributedToSettings() {
        let text = "fov: bad value 55 (field of view in degrees: 90, 78, 65)\nexposure: set automatically right now (x)\nno camera matches 9\n"
        let (per, other) = CLIErrors.attribute(text, names: ["fov", "zoom", "exposure"])
        XCTAssertEqual(per["fov"], "bad value 55 (field of view in degrees: 90, 78, 65)")
        XCTAssertEqual(per["exposure"], "set automatically right now (x)")
        XCTAssertNil(per["zoom"])
        XCTAssertEqual(other, ["no camera matches 9"])
    }

    func testResultMessage() {
        XCTAssertEqual(CLIResult(status: 1, stderr: "boom\n").message, "boom")
        XCTAssertEqual(CLIResult(status: 2, stdout: Data("usage\n".utf8)).message, "usage")
        XCTAssertEqual(CLIResult(status: 3).message, "brioctl exited with status 3")
        XCTAssertEqual(CLIResult(status: -1, failure: "cannot start").message, "cannot start")
        XCTAssertFalse(CLIResult(status: 0, failure: "late").ok)
    }
}

final class URLCommandTests: XCTestCase {
    private func parse(_ s: String) -> Result<URLCommand, URLCommandError> { URLCommands.parse(URL(string: s)!) }

    func testSet() {
        XCTAssertEqual(try? parse("brioctl://set?fov=78&zoom=115").get(), .set([("fov", "78"), ("zoom", "115")]))
        XCTAssertEqual(try? parse("BRIOCTL://SET?pan=-5").get(), .set([("pan", "-5")]))
        XCTAssertEqual(try? parse("brioctl:///set?fov=65").get(), .set([("fov", "65")]))
        // a repeated key: the later value, at the first place
        XCTAssertEqual(try? parse("brioctl://set?fov=90&zoom=100&fov=65").get(), .set([("fov", "65"), ("zoom", "100")]))
        XCTAssertEqual(parse("brioctl://set"), .failure(.nothingToDo))
        XCTAssertEqual(parse("brioctl://set?"), .failure(.nothingToDo))
    }

    func testApplyAndCamera() {
        XCTAssertEqual(try? parse("brioctl://apply?name=warmer").get(), .apply(name: "warmer"))
        XCTAssertEqual(try? parse("brioctl://apply?name=my%20file").get(), .apply(name: "my file"))
        XCTAssertEqual(try? parse("brioctl://camera?id=2").get(), .camera(id: "2"))
        XCTAssertEqual(parse("brioctl://apply"), .failure(.missing("name")))
        XCTAssertEqual(parse("brioctl://apply?name="), .failure(.missing("name")))
        XCTAssertEqual(parse("brioctl://camera?x=1"), .failure(.missing("id")))
    }

    func testOtherURLsAreRefused() {
        XCTAssertEqual(parse("https://example.com/set?fov=78"), .failure(.wrongScheme))
        XCTAssertEqual(parse("brioctl://reset?yes=1"), .failure(.unknownAction("reset")))
        XCTAssertEqual(parse("brioctl://factory-reset"), .failure(.unknownAction("factory-reset")))
        XCTAssertEqual(parse("brioctl://"), .failure(.unknownAction("")))
    }

    func testSetKeepsOnlyWhatTheCameraHas() throws {
        let state = try Fixture.state("state-mxbrio")
        let plan = URLCommands.plan(set: [("fov", "78"), ("bogus", "1"), ("zoom", "115"), ("--camera", "2"), ("micgain", "0.5")],
                                    for: state)
        XCTAssertEqual(pairs(plan.pairs), ["fov=78", "zoom=115", "micgain=0.5"])
        XCTAssertEqual(plan.ignored, ["bogus", "--camera"])

        let generic = try Fixture.state("state-generic")
        let onGeneric = URLCommands.plan(set: [("fov", "78"), ("micgain", "0.5"), ("zoom", "150")], for: generic)
        XCTAssertEqual(pairs(onGeneric.pairs), ["zoom=150"], "no fov and no microphone on this camera")
        XCTAssertEqual(onGeneric.ignored, ["fov", "micgain"])
    }

    func testValuesThatCouldBeOptionsOrPathsAreDropped() throws {
        let state = try Fixture.state("state-mxbrio")
        let plan = URLCommands.plan(set: [("fov", "--camera"), ("zoom", ""), ("warmth", "50 60"), ("tint", "../x"),
                                          ("pan", "-5"), ("vibrance", "128")], for: state)
        XCTAssertEqual(pairs(plan.pairs), ["pan=-5", "vibrance=128"])
        XCTAssertEqual(plan.ignored, ["fov", "zoom", "warmth", "tint"])
    }

    func testApplyOnlyKnownProfiles() throws {
        let profiles = try Fixture.profiles()
        XCTAssertTrue(URLCommands.isKnownProfile("warmer", in: profiles))
        XCTAssertTrue(URLCommands.isKnownProfile("desk", in: profiles))
        XCTAssertFalse(URLCommands.isKnownProfile("/etc/passwd", in: profiles))
        XCTAssertFalse(URLCommands.isKnownProfile("nope", in: profiles))
        XCTAssertFalse(URLCommands.isKnownProfile("warmer", in: nil))
    }

    func testCameraByIndexSerialOrLocation() throws {
        let cameras = try Fixture.cameras("list-four-cameras")
        XCTAssertEqual(URLCommands.camera(matching: "3", in: cameras)?.displayName, "Brio 500")
        XCTAssertEqual(URLCommands.camera(matching: "0x200000", in: cameras)?.index, 2)
        XCTAssertNil(URLCommands.camera(matching: "9", in: cameras))
    }
}
