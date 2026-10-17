import Foundation

/// The part of a `FlockPresentation` that decides which choreography plays: its kind and
/// which sessions are shown, in which order -- not their states.
public struct FlockStructure: Equatable, Sendable {
    public enum Kind: Sendable { case empty, expanded, merged }

    public var kind: Kind
    /// Expanded: the column order. Merged: `[lead]` (the presentation doesn't carry the
    /// full session list). Empty: `[]`.
    public var ids: [String]

    public init(_ p: FlockPresentation) {
        switch p {
        case .empty:
            kind = .empty
            ids = []
        case .expanded(let sessions, _):
            kind = .expanded
            ids = sessions.map(\.id)
        case .merged(let lead, _, _):
            kind = .merged
            ids = [lead.id]
        }
    }
}

/// How the flock should move from one structure to the next (spec §5.3).
public enum FlockTransition: Equatable, Sendable {
    case update
    case expand
    case collapse
    case join(added: [String])
    case leave(removed: [String])
    case leaveThenJoin(removed: [String], added: [String])
    case reorder
    /// The single Critter of one state becomes the single Critter of the other (`""` = the
    /// empty state's placeholder).
    case reuse(from: String, to: String)
    case snap

    public static func between(_ old: FlockStructure, _ new: FlockStructure) -> FlockTransition {
        if old == new { return .update }
        switch (old.kind, new.kind) {
        case (.merged, .merged), (.empty, .empty):
            return .update
        case (.merged, .expanded):
            return .expand
        case (.expanded, .merged):
            return .collapse
        case (.empty, .expanded) where new.ids.count == 1:
            return .reuse(from: "", to: new.ids[0])
        case (.expanded, .empty) where old.ids.count == 1:
            return .reuse(from: old.ids[0], to: "")
        case (.expanded, .expanded):
            let removed = old.ids.filter { !new.ids.contains($0) }
            let added = new.ids.filter { !old.ids.contains($0) }
            switch (removed.isEmpty, added.isEmpty) {
            case (true, true): return .reorder
            case (true, false): return .join(added: added)
            case (false, true): return .leave(removed: removed)
            case (false, false): return .leaveThenJoin(removed: removed, added: added)
            }
        default:
            return .snap
        }
    }
}

/// Runs one choreography at a time; while one is playing only the latest request is kept.
public struct ChoreographyQueue<Item> {
    public private(set) var isBusy = false
    private var pending: Item?

    public init() {}

    /// Idle: becomes busy and returns `item` to run now. Busy: remembers it (replacing any
    /// earlier pending one) and returns nil.
    public mutating func submit(_ item: Item) -> Item? {
        if isBusy {
            pending = item
            return nil
        }
        isBusy = true
        return item
    }

    /// The running choreography ended: returns the pending item to run next (staying busy),
    /// or goes idle.
    public mutating func finish() -> Item? {
        if let next = pending {
            pending = nil
            return next
        }
        isBusy = false
        return nil
    }
}

extension ChoreographyQueue: Sendable where Item: Sendable {}
