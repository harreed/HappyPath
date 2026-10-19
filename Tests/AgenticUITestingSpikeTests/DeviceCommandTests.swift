import XCTest
import ProjectDomain
import RunnerCore
@testable import SimulatorControl

final class DeviceCommandTests: XCTestCase {
    func testDeepLinkUsesDiscreteArguments() throws {
        let invocation = try DeviceCommands.invocation(.openURL("myapp://item/42?name=hello world"),
                                                       udid: "DEVICE", bundleIdentifier: "com.example.app")
        XCTAssertEqual(invocation.arguments, ["simctl", "openurl", "DEVICE", "myapp://item/42?name=hello world"])
    }

    func testLocationAndPermissionCommands() throws {
        XCTAssertEqual(try DeviceCommands.invocation(.setLocation(latitude: 51.5074, longitude: -0.1278),
                                                     udid: "DEVICE", bundleIdentifier: "com.example.app").arguments,
                       ["simctl", "location", "DEVICE", "set", "51.5074,-0.1278"])
        XCTAssertEqual(try DeviceCommands.invocation(.clearLocation, udid: "DEVICE", bundleIdentifier: "com.example.app").arguments,
                       ["simctl", "location", "DEVICE", "clear"])
        XCTAssertEqual(try DeviceCommands.invocation(.permission(service: .photos, decision: .grant),
                                                     udid: "DEVICE", bundleIdentifier: "com.example.app").arguments,
                       ["simctl", "privacy", "DEVICE", "grant", "photos", "com.example.app"])
    }

    func testInvalidInputsFailBeforeDispatch() {
        XCTAssertThrowsError(try DeviceCommands.invocation(.openURL("relative/path"), udid: "DEVICE", bundleIdentifier: "app"))
        XCTAssertThrowsError(try DeviceCommands.invocation(.setLocation(latitude: .nan, longitude: 0), udid: "DEVICE", bundleIdentifier: "app"))
        XCTAssertThrowsError(try DeviceCommands.invocation(.setLocation(latitude: 91, longitude: 0), udid: "DEVICE", bundleIdentifier: "app"))
        XCTAssertThrowsError(try DeviceAction.background(seconds: 21).validate())
        XCTAssertThrowsError(try DeviceCommands.invocation(.background(seconds: 1), udid: "DEVICE", bundleIdentifier: "app"))
    }

    func testOldStartingStateDefaultsLocationToUnchanged() throws {
        let data = Data(#"{"appData":"preserve","permissions":"preserve","appearance":"unchanged","keychain":"preserve"}"#.utf8)
        let state = try JSONDecoder().decode(TestStartingState.self, from: data)
        XCTAssertEqual(state.location, .unchanged)
        XCTAssertTrue(state.isDefault)
    }

    func testBackgroundCompanionRequestRequiresBoundedDuration() throws {
        var request = CompanionRequest(sessionID: UUID(), operation: .background, bundleID: "com.example.app")
        request.timeout = 2
        XCTAssertNoThrow(try request.validate())
        request.timeout = 21
        XCTAssertThrowsError(try request.validate())
    }
}
