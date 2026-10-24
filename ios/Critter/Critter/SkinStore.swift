import CritterClient
import CritterKit
import Foundation
import Observation

/// Where the phone gets skins (Android `SkinStore`): the bundled ones from the app (`Skins/<name>/manifest.json`, the
/// repository's own folder), and the custom ones the Mac sends when asked (`skin` request), kept in memory and in the
/// App Group's `Skins/<name>.json` (`SharedContainer`), which the next launch starts from and the Live Activity draws
/// from. `library` is built again whenever a manifest arrives or the clock or forced skin changes, so screens that read
/// it redraw with the real skin instead of the sprig they showed meanwhile; it takes over the old library's manifests,
/// so only Critters wearing the new skin change.
@MainActor @Observable
final class SkinStore {
    /// Finds a skin by name for every screen.
    private(set) var library: PhoneSkinLibrary

    /// How much the Mac dims the Critters whose state is dimmed (`prefs.idleDim`): every `CritterSlot`'s
    /// `dimStrength`, and the portraits'. 1, the full tint, until the first snapshot (the Mac's default).
    private(set) var idleDim: Double = 1

    /// The bundled skins only, unaffected by the phone's own choice: for the settings' previews and the gallery.
    @ObservationIgnored let previewLibrary = PhoneSkinLibrary(
        bundled: SkinStore.bundled, pushed: [:], forced: nil, clockSkin: nil, reuse: nil
    )

    @ObservationIgnored private var pushed: [String: Data] = [:]
    @ObservationIgnored private var forced: String?
    @ObservationIgnored private var clockSkin: String?
    /// The names asked for on this connection: each once per connection (`SkinAsking`).
    @ObservationIgnored private var asking = SkinAsking()
    @ObservationIgnored private let directory: URL?

    /// The skins the app ships, as the app's `Skins` folder has them (every folder with a manifest that decodes), in
    /// the settings' order (`PhoneSkinLibrary.ordered`).
    static let bundledNames: [String] = {
        guard let folder = Bundle.main.url(forResource: "Skins", withExtension: nil),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
              )
        else { return [PhoneSkinLibrary.fallback] }
        return PhoneSkinLibrary.ordered(entries.map(\.lastPathComponent).filter { bundled($0) != nil })
    }()

    /// - Parameter directory: where pushed skins are saved; nil keeps them in memory only. The default is the App
    ///   Group's `Skins`.
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
        SharedContainer.skinsFolder
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
        fetchIfNeeded(store: store)
    }

    /// Asks the Mac for each skin the store's snapshot wears that the library does not have (`needsFetch`), once per
    /// connection (`SkinAsking`): a name that fails (refused, not answered, broken) is asked for again only on the
    /// next connection. Call it with every snapshot and whenever `isLive` changes (a connection that ends forgets
    /// what it asked; the next one asks again).
    func fetchIfNeeded(store: BridgeStore) {
        let names = asking.toAsk(SkinAsking.names(in: store.snapshot), live: store.isLive, missing: library.needsFetch)
        for name in names {
            Task { [weak self] in
                guard let data = await store.requestSkin(name) else { return }
                self?.put(name, data: data)
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
