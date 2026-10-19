import Foundation
import CryptoKit
import Darwin
import CoreFoundation

public struct ProjectMigration: Sendable {
    public let sourceVersion: Int
    public let original: Data
    public let converted: Data
    public let project: TestProject
    public var originalSHA256: String { SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined() }
    public var changes: [String] { sourceVersion == 1 ? ["Upgrade project format 1 → 2; preserve identifiers, order, policies and dependency path strings.", "Relative dependency paths resolve against this project folder. Existing companion paths remain external until explicitly relinked.", "Keep exact original bytes in migrations/\(originalSHA256)/project.v1.json. Historical run snapshots remain unchanged."] : [] }
    public static func preview(data: Data) throws -> Self {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let number = object["schemaVersion"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.rounded() == number.doubleValue, let version = object["schemaVersion"] as? Int else { throw ProjectValidationError.invalid("Missing project schema version") }
        guard version == 1 || version == 2 else { throw ProjectValidationError.unsupportedVersion(version) }
        object["schemaVersion"] = 2
        let converted = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let project = try JSONDecoder().decode(TestProject.self, from: converted)
        try project.validate()
        return .init(sourceVersion: version, original: data, converted: converted, project: project)
    }
    /// Fault hook tests interruption before the only authoritative definition replacement.
    public func commit(to directory: URL, beforeCommit: () throws -> Void = {}) throws {
        guard sourceVersion == 1 else { return }
        try PortableFiles.checkTree(directory.appendingPathComponent("project.json"))
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("migrations").path) { try PortableFiles.checkTree(directory.appendingPathComponent("migrations")) }
        let target = directory.appendingPathComponent("project.json")
        guard try Data(contentsOf: target) == original else { throw ProjectValidationError.invalid("Project changed after migration preview. Reopen it.") }
        let backup = directory.appendingPathComponent("migrations/\(originalSHA256)")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let backupFile = backup.appendingPathComponent("project.v1.json")
        if FileManager.default.fileExists(atPath: backupFile.path) {
            guard try Data(contentsOf: backupFile) == original else { throw ProjectValidationError.invalid("Migration backup differs from original") }
        } else { try original.write(to: backupFile, options: .withoutOverwriting) }
        try beforeCommit()
        try PortableFiles.checkTree(directory.appendingPathComponent("project.json"))
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("migrations").path) { try PortableFiles.checkTree(directory.appendingPathComponent("migrations")) }
        guard try Data(contentsOf: target) == original else { throw ProjectValidationError.invalid("Project changed during migration") }
        try converted.write(to: target, options: .atomic)
    }
}

public enum PortableFiles {
    public static func fingerprint(_ base: URL, roots: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in roots {
            let root = base.appendingPathComponent(name)
            try checkTree(root)
            var entries = [root]
            if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]) { for case let item as URL in walker { entries.append(item) } }
            for item in entries {
                let key = String(item.standardizedFileURL.path.dropFirst(base.standardizedFileURL.path.count + 1))
                let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                if values.isDirectory == true { result[key] = "directory" }
                else if values.isRegularFile == true { result[key] = SHA256.hash(data: try Data(contentsOf: item)).map { String(format: "%02x", $0) }.joined() }
                else { throw ProjectValidationError.invalid("Unsupported export input") }
            }
        }
        return result
    }
    public static func checkTree(_ root: URL) throws {
        let fm = FileManager.default
        guard root.standardizedFileURL.path == root.standardizedFileURL.resolvingSymlinksInPath().path else { throw ProjectValidationError.invalid("Symbolic links are not supported in project operations") }
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]) {
            for case let item as URL in walker {
                let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
                guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else { throw ProjectValidationError.invalid("Unsupported link or special file: \(item.lastPathComponent)") }
            }
        }
    }
}

public enum ProjectRunExport: Sendable { case none, selected(Set<String>), all }
public extension ProjectBundleStore {
    func export(from source: URL, to destination: URL, runs: ProjectRunExport, beforeCommit: () throws -> Void = {}) throws {
        let fm = FileManager.default
        try PortableFiles.checkTree(source.appendingPathComponent("project.json"))
        guard !fm.fileExists(atPath: destination.path), destination.deletingLastPathComponent().standardizedFileURL.path == destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path,
              !destination.standardizedFileURL.path.hasPrefix(source.standardizedFileURL.path + "/") else { throw ProjectValidationError.invalid("Choose a new destination outside the source project, without symbolic links") }
        _ = try load(from: source)
        let runRoot = source.appendingPathComponent("runs")
        let available = Set((try? fm.contentsOfDirectory(atPath: runRoot.path)) ?? [])
        let chosen: Set<String>
        switch runs { case .none: chosen = []; case .all: chosen = available; case .selected(let names): chosen = names }
        guard chosen.isSubset(of: available), chosen.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }) else { throw ProjectValidationError.invalid("Selected run no longer exists") }
        let definitionNames = ["project.json", "resources.json", "references", "migrations"]
        let copiedDefinitions = definitionNames.filter { fm.fileExists(atPath: source.appendingPathComponent($0).path) }
        let roots = copiedDefinitions + chosen.sorted().map { "runs/" + $0 }
        let before = try PortableFiles.fingerprint(source, roots: roots)
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".project-export-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        for name in copiedDefinitions {
            try fm.copyItem(at: source.appendingPathComponent(name), to: stage.appendingPathComponent(name))
        }
        try fm.createDirectory(at: stage.appendingPathComponent("runs"), withIntermediateDirectories: false)
        for name in chosen.sorted() { try fm.copyItem(at: runRoot.appendingPathComponent(name), to: stage.appendingPathComponent("runs/" + name)) }
        try beforeCommit()
        guard copiedDefinitions == definitionNames.filter({ fm.fileExists(atPath: source.appendingPathComponent($0).path) }), Set(try fm.contentsOfDirectory(atPath: stage.path)) == Set(copiedDefinitions + ["runs"]), before == (try PortableFiles.fingerprint(source, roots: roots)), before == (try PortableFiles.fingerprint(stage, roots: roots)) else { throw ProjectValidationError.invalid("Project or selected run changed during export; retry after writes finish") }
        try PortableFiles.checkTree(stage)
        guard renamex_np(stage.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw ProjectValidationError.invalid("Destination appeared or export could not commit; source is unchanged") }
    }
}

public struct ProjectDependencies: Sendable {
    public let base: URL
    public let bundledCompanion: URL?
    public init(base: URL, bundledCompanion: URL? = Bundle.main.resourceURL?.appendingPathComponent("Companion/Fixtures/OnboardingFixture/OnboardingFixture.xcodeproj")) { self.base = base; self.bundledCompanion = bundledCompanion }
    public func resolve(_ path: String) -> URL { path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path).standardizedFileURL }
    public func companion(_ configuration: CompanionConfiguration) throws -> URL {
        if configuration.resourceLocation == .bundledCompanion {
            guard let bundledCompanion, FileManager.default.fileExists(atPath: bundledCompanion.path) else { throw ProjectValidationError.invalid("Current app installation has no packaged companion") }
            return bundledCompanion
        }
        return resolve(configuration.projectPath)
    }
    public func validate(_ project: TestProject) throws {
        try project.validate()
        let app = resolve(project.app.projectPath)
        guard ["xcodeproj", "xcworkspace"].contains(app.pathExtension), FileManager.default.fileExists(atPath: app.path) else { throw ProjectValidationError.invalid("Xcode dependency is unavailable. Relink it in Project Dependencies.") }
        guard let config = project.app.companion else { throw ProjectValidationError.invalid("Choose an automation companion in Project Dependencies") }
        let companion = try companion(config)
        guard ["xcodeproj", "xcworkspace"].contains(companion.pathExtension), FileManager.default.fileExists(atPath: companion.path) else { throw ProjectValidationError.invalid("Companion dependency is unavailable. Relink it in Project Dependencies.") }
    }
}
