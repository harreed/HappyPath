import Foundation

/// A calibrated ordinal rubric score result from a System One model.
public struct ScoreResult: Sendable, Equatable {
    /// The probability-weighted continuous mean score (e.g. 2.4 across levels 0...4).
    public let value: Double

    /// The zero-based index of the rubric level with the highest probability.
    public let mostLikelyIndex: Int

    /// The descriptive name of the rubric level with the highest probability.
    public let mostLikelyLevel: String

    /// Calibrated probability distribution across all rubric levels ordered by index.
    public let probabilities: [Double]

    /// Calibrated confidence score (0.0 to 1.0).
    public let confidence: Double

    /// The ordered rubric levels evaluated.
    public let levels: [String]

    public init(
        value: Double,
        mostLikelyIndex: Int,
        mostLikelyLevel: String,
        probabilities: [Double],
        confidence: Double,
        levels: [String]
    ) {
        self.value = value
        self.mostLikelyIndex = mostLikelyIndex
        self.mostLikelyLevel = mostLikelyLevel
        self.probabilities = probabilities
        self.confidence = confidence
        self.levels = levels
    }
}
