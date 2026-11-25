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

    private let index: BodySearchIndex
    private var indexingTask: Task<Void, Never>?
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
        do {
            try await index.deleteRowIDs(rowIDs)
            indexedBodyCount = await index.totalIndexedCount()
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
        indexingTask?.cancel()
        hasCompletedFullSweep = false
        hasPrunedStale = false
        resumeCursorRowID = nil
        errorMessage = nil
        let ftsIndex = index
        Task { [weak self] in
            do {
                try await ftsIndex.clearAll()
                self?.indexedBodyCount = 0
                self?.errorMessage = nil
                onToast("已清空正文索引，正在后台重建...")
                self?.scheduleIndexing(
                    visiblePriority: visiblePriority,
                    reader: reader,
                    parser: parser,
                    forceFullSweep: true
                )
            } catch {
                self?.errorMessage = error.localizedDescription
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
        indexingTask?.cancel()
        hasCompletedFullSweep = false
        hasPrunedStale = false
        resumeCursorRowID = nil
        errorMessage = nil
        let ftsIndex = index
        Task { [weak self] in
            do {
                try await ftsIndex.clearAll()
                self?.indexedBodyCount = 0
                self?.errorMessage = nil
                onToast("已清空本地正文全文搜索缓存")
            } catch {
                self?.errorMessage = error.localizedDescription
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
        guard let parser else { return }
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
                    var chunkWrote = false
                    for msg in unique {
                        if Task.isCancelled { break }
                        let result = await parser.loadPlainTextForIndexing(for: msg.id, cachedMTime: storedVersions[msg.id])
                        guard case let .parsed(plainText, attachmentNames, mtime) = result else { continue }
                        let indexedBody: String
                        if attachmentNames.isEmpty {
                            indexedBody = plainText
                        } else {
                            indexedBody = "\(plainText)\n[附件] \(attachmentNames.joined(separator: " "))"
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
                            try await ftsIndex.upsertBatchWithMetadata(batch)
                            batch.removeAll(keepingCapacity: true)
                            chunkWrote = true
                            anyChanges = true
                        }
                    }
                    if !batch.isEmpty {
                        try await ftsIndex.upsertBatchWithMetadata(batch)
                        chunkWrote = true
                        anyChanges = true
                    }
                    if chunkWrote {
                        let total = await ftsIndex.totalIndexedCount()
                        await MainActor.run { [weak self] in
                            self?.indexedBodyCount = total
                            self?.errorMessage = nil
                        }
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
