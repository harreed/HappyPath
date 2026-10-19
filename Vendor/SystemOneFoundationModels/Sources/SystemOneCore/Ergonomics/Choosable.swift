import Foundation

/// A protocol representing a type-safe discrete choice option evaluated by System One decision models.
public protocol Choosable: CaseIterable, Hashable, Sendable {
    /// The unique string identifier for this option matching model choice outputs.
    var optionIdentifier: String { get }

    /// An optional human-readable instruction or description defining when this option applies.
    var optionDescription: String? { get }
}

public extension Choosable where Self: RawRepresentable, RawValue == String {
    var optionIdentifier: String {
        rawValue
    }

    var optionDescription: String? {
        nil
    }
}

public extension Choosable {
    var optionIdentifier: String {
        "\(self)"
    }

    var optionDescription: String? {
        nil
    }
}
