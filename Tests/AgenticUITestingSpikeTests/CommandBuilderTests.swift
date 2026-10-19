import XCTest
@testable import SimulatorControl

final class CommandBuilderTests: XCTestCase {
    func testWorkspaceBuildUsesDiscreteArguments() {
        let request = XcodeBuildRequest(
            container: .workspace(URL(fileURLWithPath: "/tmp/My App.xcworkspace")),
            scheme: "Demo; touch /tmp/nope",
            simulatorUDID: "TEST-UDID",
            derivedDataPath: URL(fileURLWithPath: "/tmp/Derived Data")
        )

        let invocation = AppleToolCommands.build(request)

        XCTAssertEqual(invocation.executableURL.path, "/usr/bin/xcodebuild")
        XCTAssertEqual(invocation.arguments, [
            "-workspace", "/tmp/My App.xcworkspace",
            "-scheme", "Demo; touch /tmp/nope",
            "-configuration", "Debug",
            "-destination", "platform=iOS Simulator,id=TEST-UDID",
            "-derivedDataPath", "/tmp/Derived Data",
            "build",
        ])
    }

    func testLaunchArgumentsRemainUninterpolated() {
        let invocation = AppleToolCommands.launch(
            bundleIdentifier: "com.example.demo",
            udid: "TEST-UDID",
            arguments: ["--example", "$(touch /tmp/nope)"]
        )

        XCTAssertEqual(invocation.executableURL.path, "/usr/bin/xcrun")
        XCTAssertEqual(invocation.arguments.last, "$(touch /tmp/nope)")
        XCTAssertEqual(invocation.arguments.count, 7)
    }

    #if !os(macOS)
    func testMacControllerFailsClosedOnUnsupportedPlatform() throws {
        XCTAssertThrowsError(try MacSimulatorController().availableDevices()) { error in
            guard case SimulatorControllerError.unsupportedPlatform = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
    #endif
}
