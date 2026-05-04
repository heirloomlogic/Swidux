//
//  ParentalChallengeSource.swift
//  SwiduxParentalGate
//

/// A source of math challenges for the parental gate.
public struct ParentalChallengeSource: Sendable {
    /// Produces a fresh challenge each time it is called.
    public var generate: @Sendable () -> MathChallenge

    /// Creates a source from a closure that generates a challenge on demand.
    public init(generate: @escaping @Sendable () -> MathChallenge) {
        self.generate = generate
    }

    /// A standard source producing age-appropriate random challenges.
    public static let standard = ParentalChallengeSource {
        let op = MathChallenge.Op.allCases.randomElement() ?? .plus
        switch op {
        case .plus:
            let left = Int.random(in: 10...20)
            let right = Int.random(in: 10...20)
            return MathChallenge(left: left, right: right, op: .plus)
        case .minus:
            let left = Int.random(in: 20...40)
            let right = Int.random(in: 1...(left - 1))
            return MathChallenge(left: left, right: right, op: .minus)
        case .times:
            let left = Int.random(in: 3...9)
            let right = Int.random(in: 3...9)
            return MathChallenge(left: left, right: right, op: .times)
        }
    }

    /// A source that always returns the given challenge.
    public static func fixed(_ challenge: MathChallenge) -> ParentalChallengeSource {
        ParentalChallengeSource { challenge }
    }
}
