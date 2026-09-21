// OwnershipRegistry.swift
//
// The migration half of the problem.
//
// "Two sources of truth" is the standard diagnosis for a UIKit/SwiftUI
// migration bug, and the standard remedy is a convention: a wiki page saying
// which stack owns what. Conventions do not survive twelve engineers and two
// years. This type makes dual ownership *unrepresentable* instead: a domain is
// claimed exactly once, a write from a non-owner is a typed error at the call
// site, and reads are always allowed from either stack.
//
// Reads being unrestricted is the deliberate asymmetry. The goal of a migration
// is that both stacks render the same data; the bug is that both stacks *write*
// it.

/// Maps state domains to the single stack allowed to write them.
public struct OwnershipRegistry: Sendable, Equatable {
    private var owners: [Domain: Stack] = [:]

    public init() {}

    /// Claims `domain` for `stack`.
    ///
    /// Re-claiming a domain for the stack that already owns it is a no-op, so
    /// registration is idempotent and module init order does not matter.
    /// Claiming it for a *different* stack throws.
    public mutating func claim(_ domain: Domain, for stack: Stack) throws {
        if let existing = owners[domain] {
            guard existing == stack else {
                throw CoherenceError.domainAlreadyOwned(domain: domain, owner: existing)
            }
            return
        }
        owners[domain] = stack
    }

    /// The stack that owns `domain`, or `nil` if unclaimed.
    public func owner(of domain: Domain) -> Stack? { owners[domain] }

    /// Throws unless `stack` may write `domain`.
    ///
    /// An unclaimed domain is writable by anyone: the registry constrains
    /// domains a team has deliberately placed under migration control, and does
    /// not force every value in an app through a ceremony.
    public func validateWrite(to domain: Domain, by stack: Stack) throws {
        guard let owner = owners[domain] else { return }
        guard owner == stack else {
            throw CoherenceError.ownershipViolation(domain: domain, owner: owner, attemptedBy: stack)
        }
    }

    /// Moves a domain from one stack to the other.
    ///
    /// This is the mechanism the migration actually runs on, and it is
    /// deliberately separate from `claim`. `claim` throwing on a re-claim is
    /// what makes accidental dual ownership impossible; a migration is not an
    /// accident, so it gets its own verb, and every transfer is recorded.
    ///
    /// Throws if `domain` is unclaimed (there is nothing to transfer) or if
    /// `from` is not its current owner — so a transfer racing another
    /// transfer fails rather than silently winning.
    public mutating func transfer(_ domain: Domain, from: Stack, to: Stack) throws {
        guard let current = owners[domain] else {
            throw CoherenceError.domainNotOwned(domain: domain)
        }
        guard current == from else {
            throw CoherenceError.ownershipViolation(domain: domain, owner: current, attemptedBy: from)
        }
        owners[domain] = to
        history.append(Transfer(domain: domain, from: from, to: to))
    }

    /// One recorded ownership move.
    public struct Transfer: Hashable, Sendable, CustomStringConvertible {
        public let domain: Domain
        public let from: Stack
        public let to: Stack
        public var description: String { "\(domain): \(from) -> \(to)" }
    }

    /// Every transfer, oldest first. A migration you cannot audit afterwards
    /// is a migration nobody can tell you the state of.
    public private(set) var history: [Transfer] = []

    /// Every claimed domain, sorted by name for stable display and diffing.
    public var claims: [(domain: Domain, owner: Stack)] {
        owners
            .map { (domain: $0.key, owner: $0.value) }
            .sorted { $0.domain.name < $1.domain.name }
    }

    public static func == (lhs: OwnershipRegistry, rhs: OwnershipRegistry) -> Bool {
        lhs.owners == rhs.owners && lhs.history == rhs.history
    }
}
