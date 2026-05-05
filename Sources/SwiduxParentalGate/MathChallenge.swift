//
//  MathChallenge.swift
//  SwiduxParentalGate
//

/// A simple arithmetic problem used as a parental gate challenge.
public struct MathChallenge: Sendable, Equatable {
    /// Left-hand operand.
    public let left: Int
    /// Right-hand operand.
    public let right: Int
    /// Arithmetic operator applied to `left` and `right`.
    public let op: Op

    /// Creates a challenge with explicit operands and operator.
    public init(left: Int, right: Int, op: Op) {
        self.left = left
        self.right = right
        self.op = op
    }

    /// The correct answer for this challenge.
    public var expected: Int {
        switch op {
        case .plus: left + right
        case .minus: left - right
        case .times: left * right
        }
    }

    /// Supported operators for parental-gate challenges.
    public enum Op: String, Sendable, CaseIterable {
        case plus, minus, times

        /// A display-friendly symbol for the operation.
        public var symbol: String {
            switch self {
            case .plus: "+"
            case .minus: "\u{2212}"
            case .times: "\u{00D7}"
            }
        }
    }
}
