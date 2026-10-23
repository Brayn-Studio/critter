import Foundation

/// One skin the user can pick ("形象" in settings): `name` is its folder name, which is what
/// the `skin` setting stores and `SkinLoader.load` takes.
public struct SkinChoice: Sendable, Equatable, Identifiable {
    public var name: String
    /// The manifest's `title`, or else the folder name with its first letter uppercased
    /// ("mine" → "Mine").
    public var title: String
    public var manifest: SkinManifest

    public var id: String { name }

    public init(name: String, manifest: SkinManifest) {
        self.name = name
        self.title = manifest.title ?? name.prefix(1).uppercased() + name.dropFirst()
        self.manifest = manifest
    }
}

/// Lists the skins on offer, searching the same directories in the same order as
/// `SkinLoader.load`. Does file I/O, so callers run it off the main thread.
public enum SkinLibrary {
    /// The builtin first (under its own name, "sprig"), then every `<dir>/<name>/manifest.json`
    /// that decodes and passes `SkinValidator`, sorted by name; hidden folders and invalid
    /// skins are left out. A name found in several dirs is taken from the first one where
    /// it's valid, as `SkinLoader.load` would, ignoring case: the default macOS volume does,
    /// so `~/.critter/skins/Sprig` is what loading "sprig" finds too. A valid on-disk skin
    /// named like the builtin stands in for it.
    public static func available(searchDirs: [URL]) -> [SkinChoice] {
        var found: [String: SkinChoice] = [:] // by lowercased name
        for dir in searchDirs {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            )) ?? []
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = entry.lastPathComponent
                guard found[name.lowercased()] == nil, let manifest = SkinLoader.validManifest(in: entry) else { continue }
                found[name.lowercased()] = SkinChoice(name: name, manifest: manifest)
            }
        }
        let builtin = SkinLoader.builtin()
        let first = found.removeValue(forKey: builtin.name.lowercased()) ?? SkinChoice(name: builtin.name, manifest: builtin)
        return [first] + found.sorted { $0.key < $1.key }.map(\.value)
    }
}
