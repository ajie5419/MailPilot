import CoreServices
import Darwin
import Foundation

/// Watches Apple Mail's `MailData` directory via three complementary mechanisms:
/// 1. Kernel `kqueue` (`O_EVTONLY` vnode sources) on `Envelope Index-wal` and `Envelope Index`
///    for sub-second notification of SQLite WAL writes even while Mail.app holds the fd open.
/// 2. Unfiltered macOS FSEvents on `MailData` so directory-level / sibling file updates never get missed
///    and recreated WAL files are automatically re-attached.
/// 3. Lightweight `stat()` signature polling (every 8s, 0 SQLite queries when unchanged) on
///    `Envelope Index`, `Envelope Index-wal`, and `Envelope Index-shm` as a safety net against
///    `mmap`-only writes or App Nap FSEvent coalescing.
public final class MailDirectoryWatcher: @unchecked Sendable {
    private struct FileSignature: Equatable {
        let inode: UInt64
        let size: Int64
        let mtimeSec: Int
        let mtimeNsec: Int
    }

    private struct DirectorySnapshot: Equatable {
        let db: FileSignature?
        let wal: FileSignature?
        let shm: FileSignature?
    }

    private let directoryURL: URL
    private let queue = DispatchQueue(label: "com.mailpilot.fsevents", qos: .utility)
    private let stateLock = NSLock()
    private var streamRef: FSEventStreamRef?
    private var walSource: DispatchSourceFileSystemObject?
    private var dbSource: DispatchSourceFileSystemObject?
    private var fallbackTimer: DispatchSourceTimer?
    private var debounceWorkItem: DispatchWorkItem?
    private var lastSnapshot: DirectorySnapshot?
    private var isStopped = false
    private let onChange: @Sendable () -> Void

    public init(directoryURL: URL, onChange: @escaping @Sendable () -> Void) {
        self.directoryURL = directoryURL
        self.onChange = onChange
        startWatching()
    }

    deinit {
        stop()
    }

    public func stop() {
        stateLock.lock()
        isStopped = true
        let workItem = debounceWorkItem
        debounceWorkItem = nil
        let wal = walSource
        walSource = nil
        let db = dbSource
        dbSource = nil
        let timer = fallbackTimer
        fallbackTimer = nil
        let stream = streamRef
        streamRef = nil
        stateLock.unlock()

        workItem?.cancel()
        wal?.cancel()
        db?.cancel()
        timer?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func startWatching() {
        let initialSnapshot = captureSnapshot()
        stateLock.lock()
        lastSnapshot = initialSnapshot
        stateLock.unlock()

        attachVnodeWatchers()
        startFallbackStatTimer()

        let pathsToWatch = [directoryURL.path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<MailDirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.handleFSEvent()
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,
            flags
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)

        stateLock.lock()
        if isStopped {
            stateLock.unlock()
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.streamRef = stream
        stateLock.unlock()
    }

    private func startFallbackStatTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(8), repeating: .seconds(8), leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            self?.checkSnapshotFallback()
        }

        stateLock.lock()
        if isStopped {
            stateLock.unlock()
            timer.cancel()
            return
        }
        fallbackTimer = timer
        stateLock.unlock()

        timer.resume()
    }

    private func checkSnapshotFallback() {
        let current = captureSnapshot()
        stateLock.lock()
        let stopped = isStopped
        let previous = lastSnapshot
        let walInodeChanged = current.wal?.inode != previous?.wal?.inode
        let dbInodeChanged = current.db?.inode != previous?.db?.inode
        let changed = (previous != nil && current != previous)
        if !stopped {
            lastSnapshot = current
        }
        stateLock.unlock()

        guard !stopped else { return }
        if walInodeChanged {
            reattachVnodeWatcher(fileName: "Envelope Index-wal", isWal: true)
        } else {
            attachVnodeWatchersIfNeeded()
        }
        if dbInodeChanged {
            reattachVnodeWatcher(fileName: "Envelope Index", isWal: false)
        }
        if changed {
            scheduleNotify()
        }
    }

    private func captureSnapshot() -> DirectorySnapshot {
        DirectorySnapshot(
            db: statSignature(fileName: "Envelope Index"),
            wal: statSignature(fileName: "Envelope Index-wal"),
            shm: statSignature(fileName: "Envelope Index-shm")
        )
    }

    private func statSignature(fileName: String) -> FileSignature? {
        let path = directoryURL.appendingPathComponent(fileName).path
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileSignature(
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            mtimeSec: info.st_mtimespec.tv_sec,
            mtimeNsec: info.st_mtimespec.tv_nsec
        )
    }

    private func handleFSEvent() {
        // Keep snapshot updated so fallback poll does not re-fire redundantly for events already handled.
        let current = captureSnapshot()
        stateLock.lock()
        if !isStopped {
            lastSnapshot = current
        }
        stateLock.unlock()

        // If Mail.app just created/recreated `Envelope Index-wal`, ensure our kqueue vnode watcher is attached.
        attachVnodeWatchersIfNeeded()
        scheduleNotify()
    }

    private func attachVnodeWatchersIfNeeded() {
        stateLock.lock()
        let stopped = isStopped
        let needsWal = walSource == nil
        let needsDb = dbSource == nil
        stateLock.unlock()
        guard !stopped else { return }

        if needsWal {
            attachVnodeWatcher(fileName: "Envelope Index-wal", isWal: true)
        }
        if needsDb {
            attachVnodeWatcher(fileName: "Envelope Index", isWal: false)
        }
    }

    private func attachVnodeWatchers() {
        attachVnodeWatcher(fileName: "Envelope Index-wal", isWal: true)
        attachVnodeWatcher(fileName: "Envelope Index", isWal: false)
    }

    private func attachVnodeWatcher(fileName: String, isWal: Bool) {
        let filePath = directoryURL.appendingPathComponent(fileName).path
        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            let current = self.captureSnapshot()
            self.stateLock.lock()
            if !self.isStopped {
                self.lastSnapshot = current
            }
            self.stateLock.unlock()

            self.scheduleNotify()
            if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
                self.reattachVnodeWatcher(fileName: fileName, isWal: isWal)
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        stateLock.lock()
        if isStopped {
            stateLock.unlock()
            source.cancel()
            return
        }
        let previous: DispatchSourceFileSystemObject?
        if isWal {
            previous = walSource
            walSource = source
        } else {
            previous = dbSource
            dbSource = source
        }
        stateLock.unlock()

        previous?.cancel()
        source.resume()
    }

    private func reattachVnodeWatcher(fileName: String, isWal: Bool) {
        stateLock.lock()
        let old: DispatchSourceFileSystemObject?
        if isWal {
            old = walSource
            walSource = nil
        } else {
            old = dbSource
            dbSource = nil
        }
        let stopped = isStopped
        stateLock.unlock()

        old?.cancel()
        guard !stopped else { return }

        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.attachVnodeWatcher(fileName: fileName, isWal: isWal)
        }
    }

    private func scheduleNotify() {
        stateLock.lock()
        guard !isStopped else {
            stateLock.unlock()
            return
        }
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        debounceWorkItem = item
        stateLock.unlock()

        queue.asyncAfter(deadline: .now() + 0.35, execute: item)
    }
}
