import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Event-driven (kqueue via `DispatchSource`) watchers used by the app's session monitor. None
// of them poll. Each one delivers its callback on the `queue` it was given, and is safe to
// `start`/`stop`/`watch`/`unwatch` from any thread: its mutable state sits behind a lock,
// which is why the classes are `@unchecked Sendable`.

/// Calls `onChange` (debounced) whenever an entry in a directory is added, removed or
/// renamed -- including the atomic temp-file-then-`rename` writes `StateStore` does.
public final class DirectoryWatcher: @unchecked Sendable {
    private let url: URL
    private let queue: DispatchQueue
    private let debounce: TimeInterval
    private let onChange: @Sendable () -> Void

    private let lock = NSLock()
    private var source: DispatchSourceFileSystemObject?
    private var pending = false

    public init(url: URL, queue: DispatchQueue, debounce: TimeInterval = 0.1, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.queue = queue
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit {
        source?.cancel()
    }

    /// Creates the directory if it doesn't exist yet, then starts watching it.
    public func start() {
        lock.withLock { startLocked() }
    }

    public func stop() {
        let old: DispatchSourceFileSystemObject? = lock.withLock {
            let old = source
            source = nil
            pending = false
            return old
        }
        old?.cancel()
    }

    private func startLocked() {
        guard source == nil else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue
        )
        newSource.setEventHandler { [weak self, weak newSource] in
            guard let self, let newSource else { return }
            self.handle(newSource.data, from: newSource)
        }
        newSource.setCancelHandler { close(fd) }
        source = newSource
        newSource.resume()
    }

    private func handle(_ events: DispatchSource.FileSystemEvent, from firing: DispatchSourceFileSystemObject) {
        if events.contains(.delete) || events.contains(.rename) {
            // The directory itself went away (e.g. `rm -rf ~/.clawd/sessions`): the open fd
            // now points at an orphaned vnode that will never change again. Re-create the
            // directory and watch the new one instead.
            let isCurrent: Bool = lock.withLock {
                guard source === firing else { return false }
                source = nil
                return true
            }
            guard isCurrent else { return }
            firing.cancel()
            lock.withLock { startLocked() }
        }
        scheduleFire()
    }

    /// Coalesces a burst of events into one callback `debounce` seconds after the first.
    private func scheduleFire() {
        let shouldSchedule: Bool = lock.withLock {
            guard source != nil, !pending else { return false }
            pending = true
            return true
        }
        guard shouldSchedule else { return }
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in
            guard let self else { return }
            let active: Bool = self.lock.withLock {
                self.pending = false
                return self.source != nil
            }
            if active { self.onChange() }
        }
    }
}

/// Calls `onExit(pid)` exactly once when a watched process exits -- or right away if it had
/// already exited by the time `watch` was called.
public final class ProcessExitWatcher: @unchecked Sendable {
    private let queue: DispatchQueue
    private let onExit: @Sendable (Int32) -> Void

    private let lock = NSLock()
    private var sources: [Int32: DispatchSourceProcess] = [:]

    public init(queue: DispatchQueue, onExit: @escaping @Sendable (Int32) -> Void) {
        self.queue = queue
        self.onExit = onExit
    }

    deinit {
        for source in sources.values { source.cancel() }
    }

    /// Watching an already-watched pid is a no-op.
    public func watch(pid: Int32) {
        let newSource: DispatchSourceProcess? = lock.withLock {
            guard sources[pid] == nil else { return nil }
            let source = DispatchSource.makeProcessSource(identifier: pid_t(pid), eventMask: .exit, queue: queue)
            sources[pid] = source
            return source
        }
        guard let newSource else { return }
        newSource.setEventHandler { [weak self] in self?.fire(pid) }
        newSource.resume()

        // kqueue can't attach to a process that's already gone, so check explicitly (after
        // arming the source, so an exit in between is caught by one path or the other).
        if !ProcessTools.isAlive(pid) {
            queue.async { [weak self] in self?.fire(pid) }
        }
    }

    public func unwatch(pid: Int32) {
        let old = lock.withLock { sources.removeValue(forKey: pid) }
        old?.cancel()
    }

    public var watchedPids: Set<Int32> {
        lock.withLock { Set(sources.keys) }
    }

    /// Whichever of the kqueue event and the explicit liveness check arrives first wins;
    /// removing the source under the lock guarantees the callback runs only once.
    private func fire(_ pid: Int32) {
        guard let source = lock.withLock({ sources.removeValue(forKey: pid) }) else { return }
        source.cancel()
        onExit(pid)
    }
}

/// Calls `onAppend(tail)` (debounced) whenever a file is written to or grows, handing over
/// the last `maxTailBytes` of it. Used to spot an Esc interrupt at the end of a session's
/// transcript, for which Claude Code fires no hook.
public final class FileAppendWatcher: @unchecked Sendable {
    public static let maxTailBytes = 16 * 1024

    private let url: URL
    private let queue: DispatchQueue
    private let debounce: TimeInterval
    private let onAppend: @Sendable (Data) -> Void

    private let lock = NSLock()
    private var source: DispatchSourceFileSystemObject?
    private var pending = false

    public init(url: URL, queue: DispatchQueue, debounce: TimeInterval = 0.3, onAppend: @escaping @Sendable (Data) -> Void) {
        self.url = url
        self.queue = queue
        self.debounce = debounce
        self.onAppend = onAppend
    }

    deinit {
        source?.cancel()
    }

    /// Returns false (and watches nothing) if the file can't be opened, e.g. it doesn't
    /// exist yet; the caller may simply try again later.
    @discardableResult
    public func start() -> Bool {
        lock.withLock {
            guard source == nil else { return true }
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { return false }
            let newSource = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend], queue: queue
            )
            newSource.setEventHandler { [weak self] in self?.scheduleFire() }
            newSource.setCancelHandler { close(fd) }
            source = newSource
            newSource.resume()
            return true
        }
    }

    public func stop() {
        let old: DispatchSourceFileSystemObject? = lock.withLock {
            let old = source
            source = nil
            pending = false
            return old
        }
        old?.cancel()
    }

    private func scheduleFire() {
        let shouldSchedule: Bool = lock.withLock {
            guard source != nil, !pending else { return false }
            pending = true
            return true
        }
        guard shouldSchedule else { return }
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in
            guard let self else { return }
            let active: Bool = self.lock.withLock {
                self.pending = false
                return self.source != nil
            }
            guard active, let tail = Self.readTail(of: self.url) else { return }
            self.onAppend(tail)
        }
    }

    /// The last `maxBytes` bytes of the file at `url` (all of it if it's smaller).
    public static func readTail(of url: URL, maxBytes: Int = maxTailBytes) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        return try? handle.readToEnd() ?? Data()
    }
}
