import CritterClient
import CritterKit
import Foundation
import Observation

/// Where the phone gets skins (Android `SkinStore`): the bundled ones from the app (`Skins/<name>/manifest.json`, the
/// repository's own folder), and the custom ones the Mac sends when asked (`skin` request), kept in memory and in
/// Application Support's `Skins/<name>.json`, which the next launch starts from. `library` is built again whenever a
/// manifest arrives or the clock or forced skin changes, so screens that read it redraw with the real skin instead
/// of the sprig they showed meanwhile; it takes over the old library's manifests, so only Critters wearing the new
/// skin change.
@MainActor @Observable
final class SkinStore {
    /// Finds a skin by name for every screen.
    private(set) var library: PhoneSkinLibrary

    /// How much the Mac dims idle and done Critters (`prefs.idleDim`): every `CritterSlot`'s `dimStrength`.
    private(set) var idleDim: Double = 0.5

    /// The bundled skins only, unaffected by the phone's own choice: for the settings' previews and the gallery.
    @ObservationIgnored let previewLibrary = PhoneSkinLibrary(
        bundled: SkinStore.bundled, pushed: [:], forced: nil, clockSkin: nil, reuse: nil
    )

    @ObservationIgnored private var pushed: [String: Data] = [:]
    @ObservationIgnored private var forced: String?
    @ObservationIgnored private var clockSkin: String?
    /// Names asked for and not answered yet: one request per name at a time.
    @ObservationIgnored private var fetching: Set<String> = []
    @ObservationIgnored private let directory: URL?

    /// The skins the app ships, in the order the settings show them (sprig first: the default).
    static let bundledNames = ["sprig", "mochi", "peep", "bristle", "bonnet", "frill", "spout"]

    /// - Parameter directory: where pushed skins are saved; nil keeps them in memory only. The default is
    ///   Application Support's `Skins`.
    init(directory: URL? = SkinStore.defaultDirectory) {
        self.directory = directory
        if let directory, let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) {
            for file in files where file.pathExtension == "json" {
                let name = file.deletingPathExtension().lastPathComponent
                guard PhoneSkinLibrary.isPlain(name), let data = try? Data(contentsOf: file),
                      SkinLoader.decode(data) != nil
                else { continue }
                pushed[name] = data
            }
        }
        library = PhoneSkinLibrary(bundled: Self.bundled, pushed: pushed, forced: nil, clockSkin: nil, reuse: nil)
    }

    nonisolated static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Skins", isDirectory: true)
    }

    /// The bundled manifest of skin `name` (`Skins/<name>/manifest.json` in the app), nil if the app has none or it
    /// does not decode.
    nonisolated static func bundled(_ name: String) -> SkinManifest? {
        guard PhoneSkinLibrary.isPlain(name),
              let url = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "Skins/\(name)"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return SkinLoader.decode(data)
    }

    /// The phone's own skin choice: nil follows the Mac, a name shows that skin for every session.
    func setForced(_ name: String?) {
        guard name != forced else { return }
        forced = name
        rebuild()
    }

    /// What a snapshot says about skins: the Mac's selected skin runs the clock (`prefs.skin`, rebuilt only when it
    /// changes), its idle dimming is every slot's, and the sessions' skins this phone does not have are asked for.
    func update(from snapshot: SnapshotBody, store: BridgeStore) {
        if idleDim != snapshot.prefs.idleDim { idleDim = snapshot.prefs.idleDim }
        if clockSkin != snapshot.prefs.skin {
            clockSkin = snapshot.prefs.skin
            rebuild()
        }
        fetchIfNeeded(names: snapshot.sessions.map(\.skin) + [snapshot.prefs.skin], store: store)
    }

    /// Asks the Mac for each of `names` the library does not have (`needsFetch`), one request per name at a time. A
    /// name that fails (offline, refused, broken) is asked for again with the next snapshot.
    func fetchIfNeeded(names: [String], store: BridgeStore) {
        for name in Set(names) where !fetching.contains(name) && library.needsFetch(name) {
            fetching.insert(name)
            Task { [weak self] in
                let data = await store.requestSkin(name)
                guard let self else { return }
                fetching.remove(name)
                if let data { put(name, data: data) }
            }
        }
    }

    /// Remembers a manifest the Mac sent, in memory and on disk; ignored (false) if the name could climb out of the
    /// folder or the manifest is not a valid skin.
    @discardableResult
    func put(_ name: String, data: Data) -> Bool {
        guard PhoneSkinLibrary.isPlain(name), SkinLoader.decode(data) != nil else { return false }
        pushed[name] = data
        if let directory {
            // Kept in memory only if this fails: asked for again after a restart.
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent("\(name).json"), options: .atomic)
        }
        rebuild()
        return true
    }

    private func rebuild() {
        library = PhoneSkinLibrary(
            bundled: Self.bundled, pushed: pushed, forced: forced, clockSkin: clockSkin, reuse: library
        )
    }
}
