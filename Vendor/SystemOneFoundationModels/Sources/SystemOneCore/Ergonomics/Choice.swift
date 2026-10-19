import Foundation
import FoundationModels

/// A calibrated categorical decision result from a System One model.
public struct Choice<Option: Hashable & Sendable>: Sendable, Equatable {
    /// The selected winning option.
    public let value: Option

    /// Calibrated model confidence in the decision (0.0 to 1.0).
    public let confidence: Double

    /// Calibrated probability distribution across all evaluated options.
    public let distribution: [Option: Double]

    /// The raw `GeneratedContent` received from the Foundation Models runtime.
    public let rawContent: GeneratedContent

    public init(
        value: Option,
        confidence: Double,
        distribution: [Option: Double] = [:],
        rawContent: GeneratedContent
    ) {
        self.value = value
        self.confidence = confidence
        self.distribution = distribution
        self.rawContent = rawContent
    }

    /// Returns the calibrated probability for a specific option, defaulting to 0.0 if not present.
    public func probability(of option: Option) -> Double {
        distribution[option] ?? 0.0
    }
}
