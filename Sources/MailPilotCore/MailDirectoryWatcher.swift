import CoreServices
import Darwin
import Foundation

/// Watches Apple Mail's `MailData` directory via both:
/// 1. Kernel `kqueue` (`O_EVTONLY` vnode sources) on `Envelope Index-wal` and `Envelope Index`
///    for sub-second notification of SQLite WAL writes even while Mail.app holds the fd open.
/// 2. Unfiltered macOS FSEvents on `MailData` so directory-level / sibling file updates never get missed
///    and recreated WAL files are automatically re-attached.
public final class MailDirectoryWatcher: @unchecked Sendable {
    private let directoryURL: URL
    private let queue = DispatchQueue(label: "com.mailpilot.fsevents", qos: .utility)
    private let stateLock = NSLock()
    private var streamRef: FSEventStreamRef?
    private var walSource: DispatchSourceFileSystemObject?
    private var dbSource: DispatchSourceFileSystemObject?
    private var debounceWorkItem: DispatchWorkItem?
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
        let stream = streamRef
        streamRef = nil
        stateLock.unlock()

        workItem?.cancel()
        wal?.cancel()
        db?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func startWatching() {
        attachVnodeWatchers()

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

    private func handleFSEvent() {
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
