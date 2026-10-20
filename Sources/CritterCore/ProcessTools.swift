import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Low-level process inspection built on `sysctl`, `proc_pidpath`, and `kill(pid, 0)`.
/// Used to find the real Claude process behind a hook invocation and to tell whether it's
/// still alive.
public enum ProcessTools {
    /// `proc_pidpath`'s buffer size recommendation (`4 * MAXPATHLEN`); the macro itself
    /// isn't importable into Swift, so its value is inlined here.
    private static let maxPathBufferSize = 4096

    private static func kinfoProc(for pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0, size == MemoryLayout<kinfo_proc>.stride else { return nil }
        return info
    }

    public static func parentPid(of pid: Int32) -> Int32? {
        kinfoProc(for: pid)?.kp_eproc.e_ppid
    }

    public static func startTime(of pid: Int32) -> Int64? {
        guard let info = kinfoProc(for: pid) else { return nil }
        return Int64(info.kp_proc.p_starttime.tv_sec)
    }

    public static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: maxPathBufferSize)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// The controlling terminal of `pid`, as `/dev/ttysNNN`, or nil if it has none.
    public static func tty(of pid: Int32) -> String? {
        guard let info = kinfoProc(for: pid) else { return nil }
        let dev = info.kp_eproc.e_tdev
        guard dev != -1, let namePtr = devname(dev, S_IFCHR) else { return nil }
        let name = String(cString: namePtr)
        guard name != "??" else { return nil }
        return "/dev/\(name)"
    }

    /// `pid`'s ancestors via the `ppid` chain, nearest first, not including `pid` itself,
    /// stopping at pid 1 or after `maxDepth` steps.
    public static func ancestors(of pid: Int32, maxDepth: Int) -> [Int32] {
        var result: [Int32] = []
        var current = pid
        var depth = 0
        while depth < maxDepth {
            guard let parent = parentPid(of: current), parent > 0 else { break }
            result.append(parent)
            if parent == 1 { break }
            current = parent
            depth += 1
        }
        return result
    }

    /// Whether `path` looks like a Claude Code CLI binary: its last path component is
    /// literally "claude", or the path runs through a "claude/versions/" install layout.
    public static func isClaudeExecutable(path: String) -> Bool {
        if URL(fileURLWithPath: path).lastPathComponent == "claude" { return true }
        return path.contains("/claude/versions/")
    }

    /// Native process enumeration; avoids repeatedly spawning `ps` or `lsof`.
    public static func allPids() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 128)
        let bytes = Int32(pids.count * MemoryLayout<Int32>.stride)
        let written = proc_listallpids(&pids, bytes)
        return Array(pids.prefix(max(0, min(Int(written), pids.count)))).filter { $0 > 0 }
    }

    /// Paths of regular files a process currently holds open. Inaccessible processes
    /// simply return no paths; callers must not infer a session from historical files.
    public static func openFilePaths(of pid: Int32) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 32)
        let capacity = Int32(fds.count * MemoryLayout<proc_fdinfo>.stride)
        let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, capacity)
        guard written > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(Int(written) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
            var vnode = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, size) == size else { continue }
            let path = withUnsafePointer(to: &vnode.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }
}

/// The process queries the hook needs, behind a protocol so tests can stand in for "a live
/// Critter" or "a Claude parent" without real processes.
public protocol ProcessInspecting: Sendable {
    func isAlive(_ pid: Int32) -> Bool
    func startTime(of pid: Int32) -> Int64?
    func executablePath(of pid: Int32) -> String?
    func ancestors(of pid: Int32, maxDepth: Int) -> [Int32]
}

/// `ProcessInspecting` backed by the real `ProcessTools`.
public struct SystemProcesses: ProcessInspecting {
    public init() {}
    public func isAlive(_ pid: Int32) -> Bool { ProcessTools.isAlive(pid) }
    public func startTime(of pid: Int32) -> Int64? { ProcessTools.startTime(of: pid) }
    public func executablePath(of pid: Int32) -> String? { ProcessTools.executablePath(of: pid) }
    public func ancestors(of pid: Int32, maxDepth: Int) -> [Int32] { ProcessTools.ancestors(of: pid, maxDepth: maxDepth) }
}
