import Foundation

/// Reads the current branch straight from `.git` files, without spawning `git`.
public enum GitBranch {
    /// The branch checked out at `cwd`: walks up from `cwd` looking for `.git` and stops before
    /// `home` (a repo at `~` is usually a dotfiles repo, and its branch says nothing about the
    /// directories below it) or at the filesystem root. A detached HEAD gives the first 7 hex
    /// digits; anything unrecognisable gives nil.
    public static func read(cwd: String, stopAt home: String) -> String? {
        headFile(cwd: cwd, stopAt: home).flatMap(branch(head:))
    }

    /// The `HEAD` file `read` takes the branch from, found the same way; nil outside a repo.
    /// Its modification time changes whenever the branch does, so callers can cache on it.
    public static func headFile(cwd: String, stopAt home: String) -> URL? {
        let stop = URL(fileURLWithPath: home).standardizedFileURL.path
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL
        while dir.path != stop {
            let dotGit = dir.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                let gitDir = isDirectory.boolValue ? dotGit : followGitFile(dotGit, base: dir)
                return gitDir?.appendingPathComponent("HEAD")
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
        return nil
    }

    /// A worktree's `.git` is a file reading `gitdir: <path>`; a relative path is relative to the
    /// directory holding that file.
    private static func followGitFile(_ file: URL, base: URL) -> URL? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first,
              line.hasPrefix("gitdir:") else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
    }

    private static func branch(head file: URL) -> String? {
        guard let head = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let text = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let refPrefix = "ref: refs/heads/"
        if text.hasPrefix(refPrefix) {
            let name = String(text.dropFirst(refPrefix.count))
            return name.isEmpty ? nil : name
        }
        if text.count == 40, text.allSatisfy({ $0.isHexDigit }) { return String(text.prefix(7)) }
        return nil
    }
}
