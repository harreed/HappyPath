import Foundation
import ProjectDomain
import RunnerCore

public enum DeviceCommandError: LocalizedError, Equatable {
    case invalidLocation
    case companionAction

    public var errorDescription: String? {
        switch self {
        case .invalidLocation: "Latitude must be between -90 and 90 and longitude between -180 and 180."
        case .companionAction: "This action requires the XCTest companion."
        }
    }
}

public enum DeviceCommands {
    public static func invocation(_ action: DeviceAction, udid: String, bundleIdentifier: String) throws -> ProcessInvocation {
        try action.validate()
        let arguments: [String]
        switch action {
        case .openURL(let value):
            arguments = ["openurl", udid, value]
        case .setLocation(let latitude, let longitude):
            arguments = ["location", udid, "set", try coordinate(latitude: latitude, longitude: longitude)]
        case .clearLocation:
            arguments = ["location", udid, "clear"]
        case .permission(let service, let decision):
            arguments = ["privacy", udid, decision.rawValue, service.rawValue, bundleIdentifier]
        case .background:
            throw DeviceCommandError.companionAction
        }
        return ProcessInvocation(executableURL: AppleToolCommands.xcrun, arguments: ["simctl"] + arguments)
    }

    public static func coordinate(latitude: Double, longitude: Double) throws -> String {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw DeviceCommandError.invalidLocation
        }
        return "\(latitude),\(longitude)"
    }
}
