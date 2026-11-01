import XCTest
@testable import BrioctlCore

final class OrderedJSONTests: XCTestCase {
    func testKeepsTheOrderOfMembers() throws {
        let json = try JSON.parse(#"{"zebra":1,"apple":2,"mango":{"b":true,"a":null},"list":[3,"x",false]}"#)
        XCTAssertEqual(json.members?.map(\.key), ["zebra", "apple", "mango", "list"])
        XCTAssertEqual(json["mango"]?.members?.map(\.key), ["b", "a"])
        XCTAssertEqual(json["zebra"]?.int, 1)
        XCTAssertEqual(json["mango"]?["b"]?.bool, true)
        XCTAssertEqual(json["mango"]?["a"]?.isNull, true)
        XCTAssertEqual(json["list"]?.array?.count, 3)
    }

    func testStringsAndNumbers() throws {
        let json = try JSON.parse(#"{"s":"a\"b\\c\né😀","n":-12.5,"e":1e3,"i":128}"#)
        XCTAssertEqual(json["s"]?.string, "a\"b\\c\n\u{e9}\u{1F600}")
        XCTAssertEqual(json["n"]?.double, -12.5)
        XCTAssertEqual(json["e"]?.double, 1000)
        XCTAssertEqual(json["i"]?.int, 128)
        XCTAssertNil(json["n"]?.int)
        XCTAssertEqual(try JSON.parse("  [ ]\n").array?.count, 0)
        XCTAssertEqual(try JSON.parse("{}").members?.count, 0)
    }

    func testRejectsBrokenInput() {
        for bad in ["", "{", #"{"a":}"#, #"{"a" 1}"#, "[1,]", #""abc"#, "nul", "{} x", #""\ud800""#, #""\q""#]  {
            XCTAssertThrowsError(try JSON.parse(bad), bad)
        }
        XCTAssertThrowsError(try JSON.parse(String(repeating: "[", count: 200)))
    }
}

final class DecodingTests: XCTestCase {
    func testListFromTheFakeCLI() throws {
        let cameras = try Fixture.cameras("list-four-cameras")
        XCTAssertEqual(cameras.map(\.index), [1, 2, 3, 4])
        XCTAssertEqual(cameras[0].displayName, "MX Brio")
        XCTAssertEqual(cameras[0].support, "full")
        XCTAssertEqual(cameras[0].vid, "046d")
        XCTAssertEqual(cameras[0].location, "0x100000")
        XCTAssertEqual(cameras[1].support, "standard")
        XCTAssertNil(cameras[1].model)
        XCTAssertEqual(cameras[2].support, "experimental")
        XCTAssertEqual(try Fixture.cameras("list-one-camera").count, 1)
        XCTAssertEqual(try CameraInfo.decodeList(Data(#"{"cameras":[]}"#.utf8)), [])
        XCTAssertThrowsError(try CameraInfo.decodeList(Data("[]".utf8)))
    }

    func testCameraIDs() throws {
        let four = try Fixture.cameras("list-four-cameras")
        // all four have the serial 000000000000: it names none of them, the index does
        XCTAssertEqual(four[0].cliID(among: four), "1")
        XCTAssertEqual(four[2].cliID(among: four), "3")
        let real = CameraInfo(index: 2, vid: "046d", pid: "0944", name: "MX Brio", model: "MX Brio", support: "full",
                              serial: "ABC123", location: "0x110000")
        XCTAssertEqual(real.cliID(among: [four[0], real]), "ABC123")
        XCTAssertTrue(real.matches(id: "2"))
        XCTAssertTrue(real.matches(id: "abc123"))
        XCTAssertTrue(real.matches(id: "0x110000"))
        XCTAssertFalse(real.matches(id: "3"))
        XCTAssertFalse(real.matches(id: ""))
    }

    func testMXBrioStateKeepsTheOrderOfTheCLI() throws {
        let state = try Fixture.state("state-mxbrio")
        XCTAssertEqual(state.device.model, "MX Brio")
        XCTAssertEqual(state.device.firmware, "1.1.394")
        XCTAssertEqual(state.status.video, VideoStatus(on: true, width: 1920, height: 1080))
        XCTAssertEqual(state.status.deskView, false)
        XCTAssertEqual(state.status.rightSight?.stored, true)
        XCTAssertEqual(state.status.summary, "Video on, 1920\u{00D7}1080")
        XCTAssertEqual(Array(state.settings.map(\.name).prefix(9)),
                       ["fov", "showmode", "hdr", "warmth", "tint", "vibrance", "expcomp", "mic", "zoom"])
        XCTAssertEqual(state.sections.map(\.group), CameraState.groupOrder)
        XCTAssertEqual(state.micgain, 0.2785)

        let fov = try XCTUnwrap(state.setting("fov"))
        XCTAssertEqual(fov.kind, .choice)
        XCTAssertEqual(fov.choices, ["90", "78", "65"])
        XCTAssertEqual(fov.value, .text("78"))
        XCTAssertEqual(fov.defaultValue, .text("90"))
        XCTAssertTrue(fov.writable)
        let zoom = try XCTUnwrap(state.setting("zoom"))
        XCTAssertEqual(zoom.kind, .number)
        XCTAssertEqual(zoom.value, .number(115))
        XCTAssertEqual([zoom.min, zoom.max, zoom.step], [100, 400, 1])
        XCTAssertEqual(state.setting("mic")?.kind, .bool)
        let exposure = try XCTUnwrap(state.setting("exposure"))
        XCTAssertFalse(exposure.writable)
        XCTAssertTrue(exposure.auto)
        XCTAssertEqual(state.setting("priority")?.defaultValue, SettingValue.none)  // "default": null
    }

    func testGenericCameraHasNoLogitechGroupAndNoMicrophone() throws {
        let state = try Fixture.state("state-generic")
        XCTAssertEqual(state.device.support, "standard")
        XCTAssertNil(state.device.model)
        XCTAssertNil(state.status.video)
        XCTAssertNil(state.status.summary)
        XCTAssertNil(state.micgain)
        XCTAssertEqual(state.sections.map(\.group), ["Framing", "Exposure and image"])
        XCTAssertFalse(state.has("fov"))
        XCTAssertFalse(state.has("micgain"))
        XCTAssertTrue(try Fixture.state("state-mxbrio").has("micgain"))
    }

    func testBrio500AndExtraControls() throws {
        let brio = try Fixture.state("state-brio500")
        XCTAssertEqual(brio.device.support, "experimental")
        XCTAssertTrue(brio.has("fov"))
        let extra = try Fixture.state("state-generic-extra")
        for name in ["roll", "iris", "hueauto", "hue", "gamma", "privacy"] { XCTAssertTrue(extra.has(name), name) }
        XCTAssertEqual(extra.setting("hueauto")?.kind, .bool)
        XCTAssertFalse(try XCTUnwrap(extra.setting("privacy")).writable)
    }

    func testProfiles() throws {
        let p = try Fixture.profiles()
        XCTAssertEqual(p.presets.map(\.name), ["neutral", "warmer", "cooler", "bw", "standard", "streaming", "colorboost"])
        XCTAssertEqual(p.presets[0].settings.map(\.name), ["warmth", "saturation"])
        XCTAssertEqual(p.presets[1].summary, "warmth 60")
        XCTAssertEqual(p.saved, ["desk", "settings"])
        XCTAssertEqual(p.dir, "/Users/example/.config/brioctl")
        XCTAssertTrue(p.isKnown("warmer"))
        XCTAssertTrue(p.isKnown("desk"))
        XCTAssertFalse(p.isKnown("../../etc/passwd"))
    }

    func testNamesForSavedFiles() throws {
        let p = try Fixture.profiles()
        XCTAssertNil(p.validateNewName("meeting"))
        XCTAssertNil(p.validateNewName("  evening light 2  "))
        XCTAssertNotNil(p.validateNewName(""))
        XCTAssertNotNil(p.validateNewName("warmer"), "a built-in preset")
        XCTAssertNotNil(p.validateNewName("a/b"), "a slash makes brioctl take it as a path")
        XCTAssertNotNil(p.validateNewName("../x"))
        XCTAssertNotNil(p.validateNewName(".hidden"))
        XCTAssertNotNil(p.validateNewName("-x"))
        XCTAssertNotNil(p.validateNewName(String(repeating: "a", count: 41)))
    }

    func testValuesAreOfTheFormTheCLITakes() {
        XCTAssertEqual(SettingValue.format(115), "115")
        XCTAssertEqual(SettingValue.format(-5), "-5")
        XCTAssertEqual(SettingValue.format(0.5), "0.5")
        XCTAssertEqual(SettingValue.format(0.28), "0.28")
        XCTAssertEqual(SettingValue.number(78).argument, "78")
        XCTAssertEqual(SettingValue.text("on").argument, "on")
        XCTAssertNil(SettingValue.none.argument)
        XCTAssertEqual(SettingValue.text("78").double, 78)
    }

    func testUnreadableValueIsNull() throws {
        let json = #"{"device":{"vid":"046d","pid":"0944"},"status":{},"settings":{"zoom":{"value":null,"default":100,"auto":false,"group":"Framing","writable":false,"kind":"number","min":null,"max":null,"step":null,"help":"zoom"}},"micgain":null}"#
        let state = try CameraState.decode(Data(json.utf8))
        let zoom = try XCTUnwrap(state.setting("zoom"))
        XCTAssertEqual(zoom.value, SettingValue.none)
        XCTAssertNil(zoom.min)
        XCTAssertEqual(ControlMapping.style(for: zoom), .valueOnly)
        XCTAssertEqual(ControlMapping.valueText(for: zoom), "\u{2014}")
        XCTAssertNil(state.micgain)
    }

    func testStatusSummary() throws {
        let json = #"{"video":{"on":false,"width":1920,"height":1080},"led":false,"desk_view":true,"rightsight":{"stored":true,"enabled":true,"speed":"normal","framing":"normal"}}"#
        let status = CameraStatus(json: try JSON.parse(json))
        XCTAssertEqual(status.summary, "Video off \u{00B7} showing the desk \u{00B7} RightSight on")
        XCTAssertEqual(status.rightSight?.stored, true)
    }
}
