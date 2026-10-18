import Foundation
import Testing
@testable import CritterCore

private func tmpDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("critter-git-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ text: String, to url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: url, atomically: true, encoding: .utf8)
}

@Test func branchFromNormalRepo() {
    let home = tmpDir()
    let repo = home.appendingPathComponent("repo")
    write("ref: refs/heads/feat/login\n", to: repo.appendingPathComponent(".git/HEAD"))
    try! FileManager.default.createDirectory(at: repo.appendingPathComponent("a/b"), withIntermediateDirectories: true)
    #expect(GitBranch.read(cwd: repo.appendingPathComponent("a/b").path, stopAt: home.path) == "feat/login")
}

@Test func branchDetachedIsShortSha() {
    let home = tmpDir()
    let repo = home.appendingPathComponent("repo")
    write("0123456789abcdef0123456789abcdef01234567\n", to: repo.appendingPathComponent(".git/HEAD"))
    #expect(GitBranch.read(cwd: repo.path, stopAt: home.path) == "0123456")
}

@Test func branchFollowsWorktreeGitFile() {
    let home = tmpDir()
    write("ref: refs/heads/main\n", to: home.appendingPathComponent("main/.git/HEAD"))
    write("ref: refs/heads/wt\n", to: home.appendingPathComponent("main/.git/worktrees/wt/HEAD"))
    write("gitdir: ../main/.git/worktrees/wt\n", to: home.appendingPathComponent("repo-wt/.git"))
    #expect(GitBranch.read(cwd: home.appendingPathComponent("repo-wt").path, stopAt: home.path) == "wt")
}

@Test func branchNilOutsideRepo() {
    let home = tmpDir()
    try! FileManager.default.createDirectory(at: home.appendingPathComponent("plain"), withIntermediateDirectories: true)
    #expect(GitBranch.read(cwd: home.appendingPathComponent("plain").path, stopAt: home.path) == nil)
}

@Test func branchStopsAtHome() {
    let parent = tmpDir()
    write("ref: refs/heads/main\n", to: parent.appendingPathComponent(".git/HEAD"))
    let home = parent.appendingPathComponent("home")
    try! FileManager.default.createDirectory(at: home.appendingPathComponent("proj"), withIntermediateDirectories: true)
    #expect(GitBranch.read(cwd: home.appendingPathComponent("proj").path, stopAt: home.path) == nil)
}

@Test func branchNilForGarbageHead() {
    let home = tmpDir()
    write("hello world\n", to: home.appendingPathComponent("repo/.git/HEAD"))
    #expect(GitBranch.read(cwd: home.appendingPathComponent("repo").path, stopAt: home.path) == nil)
}
