import Foundation

public enum CompanionConfigurationError: Error { case missingTestBundle }

/// Rewrites a build-produced xctestrun into a run-local configuration. No source project is mutated.
public enum CompanionTestConfiguration {
    public static func write(source: URL, destination: URL, targetBundleID: String) throws {
        let data = try Data(contentsOf: source)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        var count = 0
        func rewrite(_ value: Any) -> Any {
            if let text = value as? String {
                return text.replacingOccurrences(of: "__TESTROOT__", with: source.deletingLastPathComponent().path)
            }
            if let array = value as? [Any] { return array.map(rewrite) }
            if let dictionary = value as? [String: Any] {
                var result = dictionary.mapValues(rewrite)
                if dictionary["TestBundlePath"] != nil {
                    var environment = result["EnvironmentVariables"] as? [String: Any] ?? [:]
                    environment["COMPANION_SERVICE_ENABLED"] = "1"
                    environment["COMPANION_TARGET_BUNDLE_ID"] = targetBundleID
                    result["EnvironmentVariables"] = environment
                    count += 1
                }
                return result
            }
            return value
        }
        let rewritten = rewrite(plist)
        guard count > 0 else { throw CompanionConfigurationError.missingTestBundle }
        try PropertyListSerialization.data(fromPropertyList: rewritten, format: .xml, options: 0)
            .write(to: destination, options: .atomic)
    }
}
