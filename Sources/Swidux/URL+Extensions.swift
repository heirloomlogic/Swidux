import Foundation

extension URL {
    /// Creates a URL from a compile-time-known string literal.
    ///
    /// Traps if the literal can't be parsed — an invalid static URL is a programmer error.
    nonisolated public init(static string: StaticString) {
        guard let url = URL(string: "\(string)") else {
            preconditionFailure("Invalid static URL: \(string)")
        }
        self = url
    }
}
