import Swidux

private let internalDefault = 7

struct InternalDetail: Equatable, Sendable {
    var value = 11
}

/// A public state with defaults and property types that are not public.
@Swidux
public nonisolated struct PublicMixedAccessState: Equatable, Sendable {
    /// A public value whose default is private to this module.
    public var count: Int = internalDefault
    var detail: InternalDetail = .init()
}

/// A package-scoped state with module-private implementation details.
@Swidux
package nonisolated struct PackageMixedAccessState: Equatable, Sendable {
    package var count: Int = internalDefault
    var detail: InternalDetail = .init()
}

/// A public child used to check observer construction from another module.
@Swidux
public nonisolated struct PublicChildState: Equatable, Sendable {
    /// The value carried by the child observer.
    public var value: Int = 0
}

/// A public state whose observer owns another public observer.
@Swidux
public nonisolated struct PublicParentState: Equatable, Sendable {
    /// The sliced child state.
    @Slice public var child: PublicChildState = .init()
}
