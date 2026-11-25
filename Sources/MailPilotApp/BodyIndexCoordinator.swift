import Combine
import Foundation
#if canImport(MailPilotCore)
import MailPilotCore
#endif

/// Coordinates background full-text `.emlx` body indexing, resumable keyset sweeps,
/// stale-row pruning, and retryable error reporting without invalidating unrelated views.
@MainActor
final class BodyIndexCoordinator: ObservableObject {
    @Published private(set) var indexedBodyCount: Int = 0
    @Published private(set) var errorMessage: String?

    var onIndexedRowIDsUpdated: (([Int64]) -> Void)?
    var onIndexCleared: (() -> Void)?
    var onRowIDsDeleted: (([Int64]) -> Void)?

    private let index: BodySearchIndex
    private var indexingTask: Task<Void, Never>?
    private var isClearingOrRebuilding = false
    private var deletedRowIDsInFlight: Set<Int64> = []
    private var hasCompletedFullSweep = false
    private var hasPrunedStale = false
    private var resumeCursorRowID: Int64?

    init(index: BodySearchIndex = BodySearchIndex()) {
        self.index = index
    }

    var needsFullSweep: Bool {
        !hasCompletedFullSweep
    }

    func searchRowIDs(query: String, limit: Int? = nil) async -> [Int64] {
        await index.searchRowIDs(query: query, limit: limit)
    }

    func fetchRowIDsWithAttachments() async -> Set<Int64> {
        await index.fetchRowIDsWithAttachments()
    }

    func fetchSnippets(for rowIDs: [Int64], maxChars: Int = 600) async -> [Int64: String] {
        await index.fetchSnippets(for: rowIDs, maxChars: maxChars)
    }

    @discardableResult
    func refreshIndexedCount() async -> Int {
        let count = await index.totalIndexedCount()
        if indexedBodyCount != count {
            indexedBodyCount = count
        }
        return count
    }

    func deleteRowIDs(_ rowIDs: [Int64]) async {
        guard !rowIDs.isEmpty else { return }
        for id in rowIDs {
            deletedRowIDsInFlight.insert(id)
        }
        do {
            try await index.deleteRowIDs(rowIDs)
            indexedBodyCount = await index.totalIndexedCount()
            onRowIDsDeleted?(rowIDs)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rebuild(
        visiblePriority: [MailMessageSummary],
        reader: EnvelopeIndexReader?,
        parser: EmlxParser?,
        onToast: @escaping (String) -> Void
    ) {
        guard !isClearingOrRebuilding else { return }
        isClearingOrRebuilding = true
        let previousTask = indexingTask
        indexingTask?.cancel()
        indexingTask = nil
        hasCompletedFullSweep = false
        hasPrunedStale = false
        resumeCursorRowID = nil
        errorMessage = nil
        let ftsIndex = index
        Task { [weak self] in
            await previousTask?.value
            guard let self else { return }
            do {
                try await ftsIndex.clearAll()
                self.deletedRowIDsInFlight.removeAll()
                self.indexedBodyCount = 0
                self.errorMessage = nil
                self.onIndexCleared?()
                onToast("已清空正文索引，正在后台重建...")
                self.isClearingOrRebuilding = false
                self.scheduleIndexing(
                    visiblePriority: visiblePriority,
                    reader: reader,
                    parser: parser,
                    forceFullSweep: true
                )
            } catch {
                self.isClearingOrRebuilding = false
                self.errorMessage = error.localizedDescription
                onToast("清空正文索引失败：\(error.localizedDescription)")
            }
        }
    }

    func retry(
        visiblePriority: [MailMessageSummary],
        reader: EnvelopeIndexReader?,
        parser: EmlxParser?,
        onToast: @escaping (String) -> Void
    ) {
        guard !isClearingOrRebuilding else { return }
        errorMessage = nil
        onToast("正在重试本地正文索引...")
        scheduleIndexing(
            visiblePriority: visiblePriority,
            reader: reader,
            parser: parser,
            forceFullSweep: false
        )
    }

    func clear(onToast: @escaping (String) -> Void) {
        guard !isClearingOrRebuilding else { return }
        isClearingOrRebuilding = true
        let previousTask = indexingTask
        indexingTask?.cancel()
        indexingTask = nil
        hasCompletedFullSweep = false
        hasPrunedStale = false
        resumeCursorRowID = nil
        errorMessage = nil
        let ftsIndex = index
        Task { [weak self] in
            await previousTask?.value
            guard let self else { return }
            defer { self.isClearingOrRebuilding = false }
            do {
                try await ftsIndex.clearAll()
                self.deletedRowIDsInFlight.removeAll()
                self.indexedBodyCount = 0
                self.errorMessage = nil
                self.onIndexCleared?()
                onToast("已清空本地正文全文搜索缓存")
            } catch {
                self.errorMessage = error.localizedDescription
                onToast("清空本地正文缓存失败：\(error.localizedDescription)")
            }
        }
    }

    /// Indexes `.emlx` plain-text bodies into local FTS5 cache with low peak memory & resumable progress:
    /// 1. Uses `loadPlainTextForIndexing(for:cachedMTime:)` to check `stat()` mtime BEFORE reading `.emlx` files
    /// 2. Always checks visible `visiblePriority` incrementally
    /// 3. Pages historical emails with O(log N) `ROWID < cursor` keyset pagination (resuming from saved cursor if interrupted)
    func scheduleIndexing(
        visiblePriority: [MailMessageSummary],
        reader: EnvelopeIndexReader?,
        parser: EmlxParser?,
        forceFullSweep: Bool = false
    ) {
        guard !isClearingOrRebuilding, let parser else { return }
        deletedRowIDsInFlight.removeAll()
        let ftsIndex = index
        let shouldRunFullSweep = forceFullSweep || !hasCompletedFullSweep
        let shouldPruneStale = shouldRunFullSweep && !hasPrunedStale
        let initialCursor = forceFullSweep ? nil : resumeCursorRowID
        indexingTask?.cancel()
        indexingTask = Task.detached(priority: .background) { [weak self] in
            var processedIDs: Set<Int64> = []
            var anyChanges = false

            do {
                // 1. Prune deleted / removed messages from local FTS5 cache once per session sweep
                if shouldPruneStale, let reader {
                    let allCached = await ftsIndex.allIndexedRowIDs()
                    if !Task.isCancelled, !allCached.isEmpty, let liveIDs = try? reader.existingRowIDs(in: allCached) {
                        let staleIDs = allCached.filter { !liveIDs.contains($0) }
                        if !Task.isCancelled, !staleIDs.isEmpty {
                            try await ftsIndex.deleteRowIDs(staleIDs)
                            anyChanges = true
                            await MainActor.run { [weak self] in
                                self?.onRowIDsDeleted?(staleIDs)
                            }
                        }
                    }
                    if !Task.isCancelled {
                        await MainActor.run { [weak self] in
                            self?.hasPrunedStale = true
                        }
                    }
                }

                func indexChunk(_ chunk: [MailMessageSummary]) async throws {
                    let unique = chunk.filter { processedIDs.insert($0.id).inserted }
                    guard !unique.isEmpty else { return }
                    let storedVersions = await ftsIndex.indexedVersions(in: unique.map(\.id))
                    var batch: [(rowID: Int64, subject: String, sender: String, body: String, fileMTime: Double, hasAttachments: Bool)] = []
                    func flushBatch() async throws {
                        guard !batch.isEmpty else { return }
                        let deletedSnapshot = await MainActor.run { [weak self] () -> Set<Int64> in
                            self?.deletedRowIDsInFlight ?? []
                        }
                        let liveBatch = deletedSnapshot.isEmpty
                            ? batch
                            : batch.filter { !deletedSnapshot.contains($0.rowID) }
                        batch.removeAll(keepingCapacity: true)
                        guard !Task.isCancelled, !liveBatch.isEmpty else { return }
                        try await ftsIndex.upsertBatchWithMetadata(liveBatch)
                        var committedIDs = liveBatch.map(\.rowID)
                        let postUpsertDeleted = await MainActor.run { [weak self] () -> Set<Int64> in
                            self?.deletedRowIDsInFlight ?? []
                        }
                        let racedDeleted = committedIDs.filter { postUpsertDeleted.contains($0) }
                        if !racedDeleted.isEmpty {
                            try? await ftsIndex.deleteRowIDs(racedDeleted)
                            let racedSet = Set(racedDeleted)
                            committedIDs.removeAll { racedSet.contains($0) }
                        }
                        let finalCommittedIDs = committedIDs
                        anyChanges = true
                        let total = await ftsIndex.totalIndexedCount()
                        await MainActor.run { [weak self] in
                            self?.indexedBodyCount = total
                            self?.errorMessage = nil
                            if !finalCommittedIDs.isEmpty {
                                self?.onIndexedRowIDsUpdated?(finalCommittedIDs)
                            }
                        }
                    }

                    for msg in unique {
                        if Task.isCancelled { break }
                        let result = await parser.loadPlainTextForIndexing(for: msg.id, cachedMTime: storedVersions[msg.id])
                        guard case let .parsed(plainText, attachmentNames, mtime) = result else { continue }
                        if Task.isCancelled { break }
                        let indexedBody: String
                        if attachmentNames.isEmpty {
                            indexedBody = plainText
                        } else {
                            indexedBody = "\(plainText)\n\u{001E}[附件] \(attachmentNames.joined(separator: " "))"
                        }
                        batch.append((
                            rowID: msg.id,
                            subject: msg.subject,
                            sender: "\(msg.senderName) \(msg.senderAddress)",
                            body: indexedBody,
                            fileMTime: mtime,
                            hasAttachments: !attachmentNames.isEmpty
                        ))
                        if batch.count >= 25 {
                            try await flushBatch()
                        }
                    }
                    if !Task.isCancelled && !batch.isEmpty {
                        try await flushBatch()
                    }
                }

                // 2. Prioritize currently visible messages first
                try await indexChunk(visiblePriority)

                // 3. Page through historical emails using O(log N) ROWID keyset pagination, saving resume progress per page
                if shouldRunFullSweep, let reader {
                    let pageSize = 200
                    var cursorRowID: Int64? = initialCursor
                    while !Task.isCancelled {
                        guard let page = try? reader.fetchIndexableMessages(beforeRowID: cursorRowID, limit: pageSize),
                              !page.isEmpty else {
                            break
                        }
                        try await indexChunk(page)
                        if Task.isCancelled { break }
                        if let lastID = page.last?.id {
                            cursorRowID = lastID
                            await MainActor.run { [weak self] in
                                self?.resumeCursorRowID = lastID
                            }
                        }
                        if page.count < pageSize {
                            break
                        }
                        await Task.yield()
                    }
                    if !Task.isCancelled {
                        let total = anyChanges ? await ftsIndex.totalIndexedCount() : nil
                        await ftsIndex.releaseMemory()
                        await MainActor.run { [weak self] in
                            self?.hasCompletedFullSweep = true
                            self?.resumeCursorRowID = nil
                            self?.errorMessage = nil
                            if let total {
                                self?.indexedBodyCount = total
                            }
                        }
                    }
                } else if anyChanges {
                    await ftsIndex.releaseMemory()
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { [weak self] in
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
