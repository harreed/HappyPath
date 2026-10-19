import Foundation

public struct XcodeContainerInfo: Decodable, Sendable {
    public let schemes: [String]
    public let configurations: [String]?
}
public struct DiscoveredProduct: Identifiable, Sendable, Hashable {
    public var id: String { target + bundleIdentifier + name }
    public let target: String
    public let name: String
    public let bundleIdentifier: String
}
public struct DiscoveredSimulator: Identifiable, Sendable {
    public var id: String { udid }
    public let udid: String
    public let name: String
    public let runtime: String
    public let state: String
}
public struct ProjectDiscovery: Sendable {
    public init() {}
    private func xcode(_ path: String, _ args: [String]) async throws -> Data {
        let result = try await SupervisedProcessExecutor().run(.init(executableURL: AppleToolCommands.xcodebuild, arguments: [path.hasSuffix(".xcworkspace") ? "-workspace" : "-project", path] + args), timeout: 90)
        return Data(result.standardOutput.utf8)
    }
    public func container(path: String) async throws -> XcodeContainerInfo {
        struct Response: Decodable { let project: XcodeContainerInfo?; let workspace: XcodeContainerInfo? }
        let response = try JSONDecoder().decode(Response.self, from: await xcode(path, ["-list", "-json"]))
        guard let info = response.project ?? response.workspace else { throw CocoaError(.fileReadCorruptFile) }; return info
    }
    public func products(path: String, scheme: String, configuration: String) async throws -> [DiscoveredProduct] {
        struct Item: Decodable { let target: String; let buildSettings: [String: String] }
        let items = try JSONDecoder().decode([Item].self, from: await xcode(path, ["-scheme", scheme, "-configuration", configuration, "-sdk", "iphonesimulator", "-showBuildSettings", "-json"]))
        return items.compactMap { item in
            let s = item.buildSettings
            guard s["PRODUCT_TYPE"] == "com.apple.product-type.application", let name = s["FULL_PRODUCT_NAME"], let bundle = s["PRODUCT_BUNDLE_IDENTIFIER"] else { return nil }
            return .init(target: item.target, name: name, bundleIdentifier: bundle)
        }
    }
    public func simulators() async throws -> [DiscoveredSimulator] {
        struct Device: Decodable { let udid: String; let name: String; let state: String; let isAvailable: Bool? }
        struct Response: Decodable { let devices: [String: [Device]] }
        let result = try await SupervisedProcessExecutor().run(AppleToolCommands.listAvailableDevices(), timeout: 20)
        let response = try JSONDecoder().decode(Response.self, from: Data(result.standardOutput.utf8))
        return response.devices.filter { $0.key.contains("iOS") }.flatMap { runtime, devices in devices.filter { $0.isAvailable != false }.map { DiscoveredSimulator(udid: $0.udid, name: $0.name, runtime: runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: ""), state: $0.state) } }.sorted { ($0.runtime, $0.name) < ($1.runtime, $1.name) }
    }
}
