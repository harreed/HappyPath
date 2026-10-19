import Foundation
import FoundationModels

// MARK: - LanguageModelSession System One Ergonomic Decision Shortcuts

public extension LanguageModelSession {
    /// Evaluates the probability of truth (0.0 to 1.0) for a statement given context state.
    ///
    /// - Parameters:
    ///   - instructions: The assertion to evaluate.
    ///   - state: The application or contextual state text to evaluate against.
    ///   - criteria: Optional qualifications defining when true vs false.
    /// - Returns: The calibrated probability of truth (0.0 to 1.0).
    func probability(
        of instructions: String,
        state: String,
        criteria: (whenTrue: String, whenFalse: String)? = nil
    ) async throws -> Double {
        let schema = try DynamicDecisionSchema.makeBinarySchema(
            instructions: instructions,
            whenTrue: criteria?.whenTrue,
            whenFalse: criteria?.whenFalse
        )

        let response = try await self.respond(to: state, schema: schema)

        if let prob = response.probability(for: "decision") {
            return prob
        }
        if let prob = response.probability(for: "root") {
            return prob
        }
        if let firstEntry = response.probabilities.first, let trueProb = firstEntry.value["true"] {
            return trueProb
        }
        if let boolVal = try? response.content.value(Bool.self, forProperty: "decision") {
            return boolVal ? 1.0 : 0.0
        }
        if let boolVal = try? response.content.value(Bool.self, forProperty: "root") {
            return boolVal ? 1.0 : 0.0
        }
        if let boolVal = try? response.content.value(Bool.self) {
            return boolVal ? 1.0 : 0.0
        }

        return 0.5
    }

    /// Evaluates a discrete categorical decision among cases of a `Choosable` enum.
    ///
    /// - Parameters:
    ///   - instructions: The classification instruction.
    ///   - type: The `Choosable` enum type.
    ///   - state: The contextual state text to evaluate.
    /// - Returns: A strongly-typed `Choice<Option>` containing the winning option and confidence distribution.
    func choice<Option: Choosable>(
        _ instructions: String,
        from type: Option.Type = Option.self,
        state: String
    ) async throws -> Choice<Option> {
        guard !Option.allCases.isEmpty else {
            throw SystemOneError.invalidSchema("Choosable enum '\(String(describing: type))' has no cases.")
        }

        let options = Option.allCases.map { (name: $0.optionIdentifier, description: $0.optionDescription) }
        let schema = try DynamicDecisionSchema.makeChoiceSchema(instructions: instructions, options: options)
        let response = try await self.respond(to: state, schema: schema)

        let rawString: String
        if let str = try? response.content.value(String.self) {
            rawString = str
        } else if let str = try? response.content.value(String.self, forProperty: "choice") {
            rawString = str
        } else {
            rawString = response.content.jsonString.trimmingCharacters(in: CharacterSet(charactersIn: "\" \t\n\r"))
        }

        let selectedOption = Option.allCases.first(where: { $0.optionIdentifier == rawString })
            ?? Option.allCases.first(where: { "\($0)" == rawString })
            ?? Option.allCases.first!

        let conf = response.confidence(for: "choice")
            ?? response.confidence(for: "root")
            ?? response.confidenceScores.first?.value
            ?? 1.0

        let rawDist = response.probabilities["choice"]
            ?? response.probabilities["root"]
            ?? response.probabilities.first?.value
            ?? [:]

        var distribution: [Option: Double] = [:]
        for opt in Option.allCases {
            if let p = rawDist[opt.optionIdentifier] ?? rawDist["\(opt)"] {
                distribution[opt] = p
            }
        }

        return Choice(
            value: selectedOption,
            confidence: conf,
            distribution: distribution,
            rawContent: response.content
        )
    }

    /// Evaluates a discrete categorical decision among dynamic string options.
    ///
    /// - Parameters:
    ///   - instructions: The classification instruction.
    ///   - options: Array of candidate string options.
    ///   - state: The contextual state text to evaluate.
    /// - Returns: A `Choice<String>` containing the chosen option string and confidence distribution.
    func choice(
        _ instructions: String,
        options: [String],
        state: String
    ) async throws -> Choice<String> {
        guard !options.isEmpty else {
            throw SystemOneError.invalidSchema("Choice requires at least one candidate option.")
        }

        let schemaOptions = options.map { (name: $0, description: nil as String?) }
        let schema = try DynamicDecisionSchema.makeChoiceSchema(instructions: instructions, options: schemaOptions)
        let response = try await self.respond(to: state, schema: schema)

        let rawString: String
        if let str = try? response.content.value(String.self) {
            rawString = str
        } else if let str = try? response.content.value(String.self, forProperty: "choice") {
            rawString = str
        } else {
            rawString = response.content.jsonString.trimmingCharacters(in: CharacterSet(charactersIn: "\" \t\n\r"))
        }

        let selectedOption = options.first(where: { $0 == rawString }) ?? options.first ?? rawString

        let conf = response.confidence(for: "choice")
            ?? response.confidence(for: "root")
            ?? response.confidenceScores.first?.value
            ?? 1.0

        let rawDist = response.probabilities["choice"]
            ?? response.probabilities["root"]
            ?? response.probabilities.first?.value
            ?? [:]

        return Choice(
            value: selectedOption,
            confidence: conf,
            distribution: rawDist,
            rawContent: response.content
        )
    }

    /// Evaluates an ordinal rubric score across ordered levels.
    ///
    /// - Parameters:
    ///   - instructions: The rubric scoring instructions.
    ///   - levels: An array of descriptive level labels (e.g. `["Low", "Medium", "High", "Critical"]`).
    ///   - state: The contextual state text to evaluate.
    /// - Returns: A `ScoreResult` containing weighted mean value, winning level, and probabilities.
    func score(
        _ instructions: String,
        levels: [String],
        state: String
    ) async throws -> ScoreResult {
        guard !levels.isEmpty else {
            throw SystemOneError.invalidSchema("Score requires at least one rubric level.")
        }

        let schema = try DynamicDecisionSchema.makeScoreSchema(instructions: instructions, levels: levels)
        let response = try await self.respond(to: state, schema: schema)

        let scoreVal = response.scoreValue(for: "score")
            ?? response.scoreValue(for: "root")
            ?? response.scoreValues.first?.value

        let value: Double
        let conf: Double
        var probs: [Double]

        if let scoreVal {
            value = scoreVal.value
            conf = scoreVal.confidence
            probs = (0..<levels.count).map { scoreVal.probabilities[$0] ?? 0.0 }
        } else {
            if let num = try? response.content.value(Double.self) {
                value = num
            } else if let num = try? response.content.value(Int.self) {
                value = Double(num)
            } else if let num = try? response.content.value(Double.self, forProperty: "score") {
                value = num
            } else if let num = try? response.content.value(Int.self, forProperty: "score") {
                value = Double(num)
            } else {
                value = 0.0
            }
            conf = response.confidence(for: "score") ?? response.confidenceScores.first?.value ?? 1.0
            probs = Array(repeating: 0.0, count: levels.count)
        }

        let mostLikelyIndex: Int
        if let maxProbIndex = probs.indices.max(by: { probs[$0] < probs[$1] }), probs[maxProbIndex] > 0.0 {
            mostLikelyIndex = maxProbIndex
        } else {
            let rounded = Int(round(value))
            mostLikelyIndex = min(max(rounded, 0), max(0, levels.count - 1))
        }

        if probs.allSatisfy({ $0 == 0.0 }) && probs.indices.contains(mostLikelyIndex) {
            probs[mostLikelyIndex] = 1.0
        }

        let mostLikelyLevel = levels.indices.contains(mostLikelyIndex) ? levels[mostLikelyIndex] : (levels.first ?? "")

        return ScoreResult(
            value: value,
            mostLikelyIndex: mostLikelyIndex,
            mostLikelyLevel: mostLikelyLevel,
            probabilities: probs,
            confidence: conf,
            levels: levels
        )
    }
}
