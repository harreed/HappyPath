import Foundation

public enum XcodeContainer: Equatable, Sendable {
    case project(URL)
    case workspace(URL)
}

public struct XcodeBuildRequest: Equatable, Sendable {
    public let container: XcodeContainer
    public let scheme: String
    public let configuration: String
    public let simulatorUDID: String
    public let derivedDataPath: URL

    public init(
        container: XcodeContainer,
        scheme: String,
        configuration: String = "Debug",
        simulatorUDID: String,
        derivedDataPath: URL
    ) {
        self.container = container
        self.scheme = scheme
        self.configuration = configuration
        self.simulatorUDID = simulatorUDID
        self.derivedDataPath = derivedDataPath
    }
}

public enum AppleToolCommands {
    public static let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
    public static let xcodebuild = URL(fileURLWithPath: "/usr/bin/xcodebuild")

    public static func listAvailableDevices() -> ProcessInvocation {
        ProcessInvocation(
            executableURL: xcrun,
            arguments: ["simctl", "list", "devices", "available", "--json"]
        )
    }

    public static func boot(udid: String) -> ProcessInvocation {
        ProcessInvocation(executableURL: xcrun, arguments: ["simctl", "boot", udid])
    }

    public static func waitUntilBooted(udid: String) -> ProcessInvocation {
        ProcessInvocation(executableURL: xcrun, arguments: ["simctl", "bootstatus", udid, "-b"])
    }

    public static func install(app: URL, udid: String) -> ProcessInvocation {
        ProcessInvocation(executableURL: xcrun, arguments: ["simctl", "install", udid, app.path])
    }

    public static func launch(bundleIdentifier: String, udid: String, arguments: [String] = []) -> ProcessInvocation {
        ProcessInvocation(
            executableURL: xcrun,
            arguments: ["simctl", "launch", "--terminate-running-process", udid, bundleIdentifier] + arguments
        )
    }

    public static func terminate(bundleIdentifier: String, udid: String) -> ProcessInvocation {
        ProcessInvocation(executableURL: xcrun, arguments: ["simctl", "terminate", udid, bundleIdentifier])
    }

    public static func screenshot(to output: URL, udid: String) -> ProcessInvocation {
        ProcessInvocation(executableURL: xcrun, arguments: ["simctl", "io", udid, "screenshot", output.path])
    }

    public static func build(_ request: XcodeBuildRequest) -> ProcessInvocation {
        var arguments: [String]
        switch request.container {
        case .project(let url):
            arguments = ["-project", url.path]
        case .workspace(let url):
            arguments = ["-workspace", url.path]
        }
        arguments += [
            "-scheme", request.scheme,
            "-configuration", request.configuration,
            "-destination", "platform=iOS Simulator,id=\(request.simulatorUDID)",
            "-derivedDataPath", request.derivedDataPath.path,
            "build",
        ]
        return ProcessInvocation(executableURL: xcodebuild, arguments: arguments)
    }
}
