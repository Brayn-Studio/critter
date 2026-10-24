import CritterKit
import Foundation

/// Finds a skin by name for the phone (Android `SkinLibrary`): a manifest the Mac pushed wins (as
/// `~/.critter/skins` does on the desktop), then the bundled ones. An unknown, undecodable or invalid skin falls
/// back to sprig, so a broken manifest or a name this phone does not have never crashes.
///
/// A library is built again whenever a skin arrives from the Mac (or the clock or forced skin changes); what it
/// read or decoded before is taken over from `reuse`, so a manifest whose source has not changed is the very value
/// it was (sharing its storage, which keeps comparing two of them cheap) and is not decoded again.
///
/// Not thread-safe: the manifests are looked up and cached on first use, from one actor (the main one).
public final class PhoneSkinLibrary {
    /// The skin shown for anything that cannot be found.
    public static let fallback = "sprig"

    /// The builtin sprig, for the phone that has not even its bundled one (never happens in a good build).
    private static let builtinSprig = SkinLoader.builtin()

    /// One decoded source: the pushed data it came from (nil for a bundled one) and the manifest (nil: absent or
    /// invalid).
    private struct Decoded {
        var data: Data?
        var manifest: SkinManifest?
    }

    private let bundled: (String) -> SkinManifest?
    private let pushed: [String: Data]
    private let forced: String?
    private let clockSkin: String?

    private var cache: [String: SkinManifest] = [:]
    /// By source, `pushed/<name>` or `bundled/<name>`; a copy of `reuse`'s, so no chain of old libraries is kept.
    private var decoded: [String: Decoded]

    /// The skin whose tick the clock runs at; nil when every lookup gives one skin anyway (forced) or no rule.
    private lazy var clockManifest: SkinManifest? = {
        guard forced == nil, let clockSkin else { return nil }
        return find(clockSkin) ?? fallbackManifest()
    }()

    /// How many sources this library read or decoded itself rather than taking them over from `reuse`.
    private(set) var loads = 0

    /// - Parameters:
    ///   - bundled: the skin the app ships under a name (already decoded and valid), nil if it has none.
    ///   - pushed: manifests pushed by the Mac, as JSON by skin name.
    ///   - forced: when set, every lookup answers with this skin whatever name is asked for (the phone's own skin
    ///     choice, spec §8.8); an invalid forced skin falls back to sprig like any other.
    ///   - clockSkin: the Mac's selected skin (`prefs.skin`). As on the desktop, a row of Critters runs on one clock
    ///     at that skin's `tickMs`, and only skins with the same tick join it: a skin on another tick is drawn as
    ///     the clock skin instead, never at the wrong speed. Nil: no such rule (one skin per view).
    ///   - reuse: the library this one replaces. Bundled skins are taken over unread (they do not change while
    ///     the app runs); a pushed one when its data is the same.
    public init(
        bundled: @escaping (String) -> SkinManifest?, pushed: [String: Data], forced: String?, clockSkin: String?,
        reuse: PhoneSkinLibrary?
    ) {
        self.bundled = bundled
        self.pushed = pushed
        self.forced = forced
        self.clockSkin = clockSkin
        decoded = reuse?.decoded ?? [:]
    }

    public func manifest(_ name: String) -> SkinManifest {
        let wanted = forced ?? name
        if let hit = cache[wanted] { return hit }
        let found = find(wanted) ?? fallbackManifest()
        let result: SkinManifest
        if let clock = clockManifest, clock.tickMs != found.tickMs {
            result = clock
        } else {
            result = found
        }
        cache[wanted] = result
        return result
    }

    /// Whether the Mac should be asked for skin `name`: it is neither bundled nor already received (a broken
    /// manifest counts as received: asking again would bring the same thing), and the name is one that can be
    /// looked up at all.
    public func needsFetch(_ name: String) -> Bool {
        Self.isPlain(name) && pushed[name] == nil && bundledManifest(name) == nil
    }

    private func find(_ name: String) -> SkinManifest? {
        guard Self.isPlain(name) else { return nil }
        return pushedManifest(name) ?? bundledManifest(name)
    }

    private func pushedManifest(_ name: String) -> SkinManifest? {
        guard let data = pushed[name] else { return nil }
        let key = "pushed/\(name)"
        if let old = decoded[key], old.data == data { return old.manifest }
        loads += 1
        let entry = Decoded(data: data, manifest: SkinLoader.decode(data))
        decoded[key] = entry
        return entry.manifest
    }

    private func bundledManifest(_ name: String) -> SkinManifest? {
        guard Self.isPlain(name) else { return nil }
        let key = "bundled/\(name)"
        if let old = decoded[key] { return old.manifest }
        loads += 1
        let entry = Decoded(data: nil, manifest: bundled(name))
        decoded[key] = entry
        return entry.manifest
    }

    private func fallbackManifest() -> SkinManifest {
        find(Self.fallback) ?? Self.builtinSprig
    }

    /// The name becomes part of a path, so it must not climb out of the skins folder.
    private static func isPlain(_ name: String) -> Bool {
        !name.isEmpty && !name.contains { $0 == "/" || $0 == "\\" || $0 == "." }
    }
}
