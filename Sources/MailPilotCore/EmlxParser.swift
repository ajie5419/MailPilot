import Darwin
import Foundation

/// Lightweight result returned by `EmlxParser.loadPlainTextForIndexing` so background FTS indexing
/// skips disk reads & MIME decoding entirely when an `.emlx` file's mtime is unchanged.
public enum IndexingBodyResult: Sendable {
    case unchanged
    case unavailable
    case parsed(plainText: String, attachmentNames: [String], fileMTime: Double)
}

/// Parses Apple Mail `.emlx` files into readable plain text and extracts verification codes.
public actor EmlxParser {
    private static let maxPathCacheEntries = 512
    private static let maxMissingCacheEntries = 2048

    private let mailRootURL: URL
    private var pathCache: [Int64: String] = [:]
    private var dataRootPaths: [String] = []
    private var missingCache: [Int64: Date] = [:]
    private var lastDataRootScanAt: Date = .distantPast
    private var fallbackFlatCache: [Int64: String] = [:]
    private var hasRunFlatFallback = false

    public init(mailRootURL: URL) {
        self.mailRootURL = mailRootURL
    }

    public func loadBody(for rowID: Int64) -> ParsedMailBody {
        guard let filePath = locateEmlxPath(rowID: rowID) else {
            return ParsedMailBody(
                plainText: "（该邮件正文尚未缓存在本地 .emlx 中，可点击右上角「在 Mail 中打开」触发系统加载。）",
                loadStatus: .missing
            )
        }

        let fileURL = URL(fileURLWithPath: filePath)
        return autoreleasepool {
            guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
                return ParsedMailBody(
                    plainText: "（无法读取本地邮件文件：\(fileURL.lastPathComponent)）",
                    sourcePath: filePath,
                    loadStatus: .failed
                )
            }

            let mtimeSeconds = Self.fileModificationTimestamp(atPath: filePath)
            let mtimeDate = mtimeSeconds.map { Date(timeIntervalSince1970: $0) }
            var parsed = Self.parseEmlxData(data, sourcePath: filePath, sourceModifiedAt: mtimeDate)
            let externalAttachments = Self.scanExternalAttachments(for: rowID, nearEmlxURL: fileURL)
            if !externalAttachments.isEmpty {
                var merged = externalAttachments
                let existingNames = Set(externalAttachments.map { $0.filename.lowercased() })
                for inlineAtt in parsed.attachments where !existingNames.contains(inlineAtt.filename.lowercased()) {
                    merged.append(inlineAtt)
                }
                parsed = ParsedMailBody(
                    plainText: parsed.plainText,
                    rawHTML: parsed.rawHTML,
                    verificationCode: parsed.verificationCode,
                    sourcePath: parsed.sourcePath,
                    sourceModifiedAt: mtimeDate,
                    attachments: merged,
                    loadStatus: .ready
                )
            }
            return parsed
        }
    }

    /// Low-memory fast path for background FTS5 indexing:
    /// 1. Checks POSIX `stat()` mtime BEFORE opening or reading the `.emlx` file.
    /// 2. If unchanged vs `cachedMTime`, returns `.unchanged` with zero disk/MIME work.
    /// 3. Otherwise maps the file with `.mappedIfSafe` and scans raw byte ranges for plain text only
    ///    (never faults or decodes multi-MB attachment payloads).
    public func loadPlainTextForIndexing(for rowID: Int64, cachedMTime: Double?) -> IndexingBodyResult {
        guard let filePath = locateEmlxPath(rowID: rowID) else {
            return .unavailable
        }
        let mtime = Self.fileModificationTimestamp(atPath: filePath) ?? 0
        if let cachedMTime, abs(cachedMTime - mtime) < 0.5 {
            return .unchanged
        }
        return autoreleasepool {
            let fileURL = URL(fileURLWithPath: filePath)
            guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
                return .unavailable
            }
            let (plainText, inlineNames) = Self.parseForIndexing(data)
            let externalNames = Self.scanExternalAttachments(for: rowID, nearEmlxURL: fileURL).map(\.filename)
            var mergedNames = inlineNames
            var seenLower = Set(inlineNames.map { $0.lowercased() })
            for name in externalNames where seenLower.insert(name.lowercased()).inserted {
                mergedNames.append(name)
            }
            return .parsed(plainText: plainText, attachmentNames: mergedNames, fileMTime: mtime)
        }
    }

    /// Lazily decodes a MIME attachment's exact byte range from its `.emlx` file only when the user opens or saves it.
    public static func decodeAttachmentData(_ attachment: MailAttachment) -> Data? {
        if let inline = attachment.inlineData {
            return inline
        }
        guard let path = attachment.sourceEmlxPath,
              let byteRange = attachment.sourceByteRange,
              !byteRange.isEmpty else {
            return nil
        }
        return autoreleasepool {
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: UInt64(byteRange.lowerBound))
                guard let rawSlice = try handle.read(upToCount: byteRange.count), !rawSlice.isEmpty else {
                    return nil
                }
                return decodeBinaryDataBytes(rawSlice, encoding: attachment.sourceTransferEncoding ?? "")
            } catch {
                return nil
            }
        }
    }

    public func invalidateCache() {
        pathCache.removeAll()
        missingCache.removeAll()
        fallbackFlatCache.removeAll()
        dataRootPaths.removeAll()
        lastDataRootScanAt = .distantPast
        hasRunFlatFallback = false
    }

    private func cachePath(_ path: String, for rowID: Int64) {
        if pathCache.count >= Self.maxPathCacheEntries {
            pathCache.removeAll(keepingCapacity: true)
        }
        pathCache[rowID] = path
        missingCache.removeValue(forKey: rowID)
    }

    private func recordMissing(rowID: Int64) {
        if missingCache.count >= Self.maxMissingCacheEntries {
            missingCache.removeAll(keepingCapacity: true)
        }
        missingCache[rowID] = Date()
    }

    private func locateEmlxPath(rowID: Int64) -> String? {
        if let cached = pathCache[rowID], access(cached, F_OK) == 0 {
            missingCache.removeValue(forKey: rowID)
            return cached
        }
        pathCache.removeValue(forKey: rowID)

        // Short-lived negative cache prevents repeated scans when messages are not yet downloaded locally.
        if let missedAt = missingCache[rowID], Date().timeIntervalSince(missedAt) < 15 {
            if let fastHit = fastBucketLookup(rowID: rowID) {
                cachePath(fastHit, for: rowID)
                return fastHit
            }
            return nil
        }

        if dataRootPaths.isEmpty {
            discoverDataRoots()
        }

        // Fast O(1) bucket lookup using Apple Mail's reversed-digit Data/ directory layout (< 0.2ms, zero URL allocation).
        if let direct = fastBucketLookup(rowID: rowID) {
            cachePath(direct, for: rowID)
            return direct
        }

        // Refresh Data/ roots at most once every 30s in case a new mailbox folder was created after launch.
        if Date().timeIntervalSince(lastDataRootScanAt) > 30 {
            discoverDataRoots()
            if let direct = fastBucketLookup(rowID: rowID) {
                cachePath(direct, for: rowID)
                return direct
            }
        }

        // Fallback only when no standard Apple Mail `Data/` roots exist (e.g. flat test fixtures).
        if dataRootPaths.isEmpty {
            if !hasRunFlatFallback {
                scanFlatFallback()
            }
            if let found = fallbackFlatCache[rowID], access(found, F_OK) == 0 {
                cachePath(found, for: rowID)
                return found
            }
        }

        recordMissing(rowID: rowID)
        return nil
    }

    private static func fileModificationTimestamp(atPath path: String) -> Double? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000.0
    }

    /// Computes Apple Mail's relative bucket path inside a mailbox `Data/` folder for a given ROWID.
    /// Example: `123456` -> `3/2/1/Messages/123456.emlx`; `42` -> `Messages/42.emlx`.
    public static func bucketRelativePaths(for rowID: Int64) -> [String] {
        let prefixInt = rowID / 1000
        let subdir: String
        if prefixInt > 0 {
            subdir = String(prefixInt).reversed().map(String.init).joined(separator: "/") + "/Messages"
        } else {
            subdir = "Messages"
        }
        return [
            "\(subdir)/\(rowID).emlx",
            "\(subdir)/\(rowID).partial.emlx"
        ]
    }

    private func fastBucketLookup(rowID: Int64) -> String? {
        let relPaths = Self.bucketRelativePaths(for: rowID)
        for root in dataRootPaths {
            for rel in relPaths {
                let candidate = "\(root)/\(rel)"
                if access(candidate, F_OK) == 0 {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Discovers mailbox `Data/` directories WITHOUT descending into them (`skipDescendants()`),
    /// avoiding enumerating or retaining thousands of `.emlx` `URL` + `_FileCache` objects in memory.
    private func discoverDataRoots() {
        let roots: [String] = autoreleasepool {
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: mailRootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }
            var discovered: Set<String> = []
            for case let fileURL as URL in enumerator {
                let name = fileURL.lastPathComponent
                if name == "Data" {
                    discovered.insert(fileURL.path)
                    enumerator.skipDescendants()
                } else if name == "MailData" || name == "Attachments" {
                    enumerator.skipDescendants()
                }
            }
            return Array(discovered)
        }
        dataRootPaths = roots
        lastDataRootScanAt = Date()
    }

    private func scanFlatFallback() {
        let found: [Int64: String] = autoreleasepool {
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: mailRootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                return [:]
            }
            var fresh: [Int64: String] = [:]
            for case let fileURL as URL in enumerator {
                let name = fileURL.lastPathComponent
                guard name.hasSuffix(".emlx") else { continue }
                let prefix = name.split(separator: ".").first.map(String.init) ?? ""
                if let id = Int64(prefix), fresh[id] == nil || !name.contains(".partial.") {
                    fresh[id] = fileURL.path
                }
            }
            return fresh
        }
        fallbackFlatCache = found
        hasRunFlatFallback = true
    }

    // MARK: - Precompiled Regular Expressions

    private static let headerBodySplitRegex = try? NSRegularExpression(pattern: #"\r?\n[ \t]*\r?\n"#)
    private static let cidRefRegex = try? NSRegularExpression(pattern: #"(?i)cid:([^"'\s>]+)"#)
    private static let rfc2047Regex = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([BbQq])\?([^?]+)\?="#)
    private static let numericEntityRegex = try? NSRegularExpression(pattern: #"&#(?:x([0-9A-Fa-f]+)|(\d+));"#)
    private static let htmlTagRegex = try? NSRegularExpression(pattern: "<[^>]+>")
    private static let htmlBlockRegexes: [(regex: NSRegularExpression, replacement: String)] = {
        let defs: [(String, String)] = [
            ("(?is)<style[^>]*>.*?</style>", ""),
            ("(?is)<script[^>]*>.*?</script>", ""),
            ("(?i)<br\\s*/?>", "\n"),
            ("(?i)</p>", "\n"),
            ("(?i)</div>", "\n"),
            ("(?i)</tr>", "\n"),
            ("(?i)</li>", "\n")
        ]
        return defs.compactMap { pattern, rep in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, rep) }
        }
    }()
    private static let verificationCodeRegexes: [NSRegularExpression] = [
        #"(?:验证码|校验码|动态码|安全码|登录码)[^\dA-Za-z]{0,12}(\d{4,8})\b"#,
        #"(?i)(?:verification code|security code|sign-in code|login code|one-time password|OTP|passcode)[^\d]{0,20}(\d{4,8})\b"#,
        #"(?i)\bcode\s*(?:is|:)\s*(\d{4,8})\b"#,
        #"(?<![0-9A-Za-z.])(\d{4,8})(?![0-9A-Za-z.])[ \t]{0,4}(?:是您的|为您的|是你的|为你的|是本次|为本次|是|为)[^\r\n。！？!?;；\d]{0,10}(?:验证码|校验码|动态码|安全码|登录码)"#,
        #"(?i)(?<![0-9A-Za-z.])(\d{4,8})(?![0-9A-Za-z.])[ \t]{1,4}is[ \t]{1,4}your[ \t]{1,4}(?:[A-Za-z0-9-]{1,24}[ \t]{1,4}){0,2}(?:(?:verification|security|sign-in|signin|login|log-in|one-time|confirmation|authentication|auth|2fa|mfa)[ \t]{1,4}code|passcode|one-time[ \t]{1,4}password|OTP)\b"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }
    private static let parameterRegexes: [String: NSRegularExpression] = {
        let names = ["boundary", "charset", "filename\\*", "filename", "name\\*", "name"]
        var map: [String: NSRegularExpression] = [:]
        for name in names {
            let pattern = "(?i)\(name)\\s*=\\s*(?:\"([^\"]+)\"|'([^']+)'|([^;\\s]+))"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                map[name] = regex
            }
        }
        return map
    }()

    // MARK: - Pure Parsing Helpers (Testable)

    /// Plain-text-only extraction for FTS5 indexing: skips attachment decoding, `cid:` base64 embedding,
    /// Plain-text-only extraction for FTS5 indexing: scans raw byte ranges directly without converting
    /// multi-MB `.emlx` payloads into `String` and returns as soon as the plain-text part is found.
    public static func parsePlainTextOnly(_ data: Data) -> String {
        parseForIndexing(data).plainText
    }

    /// Low-memory indexing extraction: extracts plain text plus MIME attachment filenames
    /// without decoding multi-MB attachment payloads.
    public static func parseForIndexing(_ data: Data) -> (plainText: String, attachmentNames: [String]) {
        let messageRange = stripEmlxHeaderRange(in: data)
        let (headers, bodyRange) = splitHeadersAndBodyBytes(in: data, range: messageRange)
        let contentType = headers["content-type"] ?? "text/plain"
        let transferEncoding = headers["content-transfer-encoding"] ?? ""
        let disposition = headers["content-disposition"] ?? ""

        var unusedAttachments: [MailAttachment] = []
        var unusedCIDs: [String: String] = [:]
        var attachmentNames: [String] = []
        let extracted = extractReadableBodyBytes(
            in: data,
            bodyRange: bodyRange,
            contentType: contentType,
            transferEncoding: transferEncoding,
            contentDisposition: disposition,
            contentID: headers["content-id"],
            sourcePath: nil,
            attachments: &unusedAttachments,
            cidImages: &unusedCIDs,
            plainTextOnly: true,
            collectedAttachmentNames: &attachmentNames
        )
        let plainText = extracted.plain.trimmingCharacters(in: .whitespacesAndNewlines)
        return (plainText.isEmpty ? "（无纯文本正文）" : plainText, attachmentNames)
    }

    public static func parseEmlxData(_ data: Data, sourcePath: String? = nil, sourceModifiedAt: Date? = nil) -> ParsedMailBody {
        let messageRange = stripEmlxHeaderRange(in: data)
        let (headers, bodyRange) = splitHeadersAndBodyBytes(in: data, range: messageRange)
        let contentType = headers["content-type"] ?? "text/plain"
        let transferEncoding = headers["content-transfer-encoding"] ?? ""
        let disposition = headers["content-disposition"] ?? ""

        var attachments: [MailAttachment] = []
        var cidImages: [String: String] = [:]
        var unusedNames: [String] = []
        let extracted = extractReadableBodyBytes(
            in: data,
            bodyRange: bodyRange,
            contentType: contentType,
            transferEncoding: transferEncoding,
            contentDisposition: disposition,
            contentID: headers["content-id"],
            sourcePath: sourcePath,
            attachments: &attachments,
            cidImages: &cidImages,
            plainTextOnly: false,
            collectedAttachmentNames: &unusedNames
        )

        let resolvedHTML = extracted.html.map { Self.inlineCIDImages(in: $0, cidMap: cidImages) }
        let plainText = extracted.plain.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalPlain = plainText.isEmpty ? "（无纯文本正文）" : plainText
        let code = extractVerificationCode(from: finalPlain)

        return ParsedMailBody(
            plainText: finalPlain,
            rawHTML: resolvedHTML,
            verificationCode: code,
            sourcePath: sourcePath,
            sourceModifiedAt: sourceModifiedAt,
            attachments: attachments,
            loadStatus: .ready
        )
    }

    /// `.emlx` starts with an ASCII byte count line followed by the RFC822 message and a trailing XML plist.
    static func stripEmlxHeaderRange(in data: Data) -> Range<Int> {
        let start = data.startIndex
        let end = data.endIndex
        let searchEnd = min(end, start + 64)
        guard let newlineIndex = data[start..<searchEnd].firstIndex(of: 0x0A) else {
            return start..<end
        }
        let firstLine = String(data: data[start..<newlineIndex], encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let declaredLength = Int(firstLine), declaredLength > 0 else {
            return start..<end
        }
        let bodyStart = newlineIndex + 1
        let bodyEnd = min(end, bodyStart + declaredLength)
        guard bodyStart < bodyEnd else { return start..<end }
        return bodyStart..<bodyEnd
    }

    static func stripEmlxHeader(from data: Data) -> Data {
        let range = stripEmlxHeaderRange(in: data)
        if range.lowerBound == data.startIndex && range.upperBound == data.endIndex {
            return data
        }
        return data.subdata(in: range)
    }

    /// Locates the RFC 822 header/body blank line directly on raw bytes without copying the body payload.
    private static func splitHeadersAndBodyBytes(in data: Data, range: Range<Int>) -> ([String: String], Range<Int>) {
        let base = data.startIndex
        let relStart = range.lowerBound - base
        let relEnd = range.upperBound - base
        guard relStart < relEnd else { return ([:], range) }

        var splitHeaderEndRel: Int?
        var splitBodyStartRel: Int?

        data.withUnsafeBytes { rawBuf in
            guard let ptr = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return }
            var i = relStart
            while i < relEnd {
                if ptr[i] == 0x0A { // '\n'
                    let lineEnd = (i > relStart && ptr[i - 1] == 0x0D) ? i - 1 : i
                    // Blank line immediately at start of range (no headers)
                    if lineEnd == relStart {
                        splitHeaderEndRel = relStart
                        splitBodyStartRel = i + 1
                        break
                    }
                    var j = i + 1
                    while j < relEnd && (ptr[j] == 0x20 || ptr[j] == 0x09) {
                        j += 1
                    }
                    if j < relEnd && ptr[j] == 0x0D && j + 1 < relEnd && ptr[j + 1] == 0x0A {
                        splitHeaderEndRel = lineEnd
                        splitBodyStartRel = j + 2
                        break
                    } else if j < relEnd && ptr[j] == 0x0A {
                        splitHeaderEndRel = lineEnd
                        splitBodyStartRel = j + 1
                        break
                    }
                }
                i += 1
            }
        }

        guard let headerEndRel = splitHeaderEndRel, let bodyStartRel = splitBodyStartRel else {
            return ([:], range)
        }
        let headerRange = (base + relStart)..<(base + headerEndRel)
        let bodyRange = (base + bodyStartRel)..<range.upperBound
        let headerBlock = (String(data: data[headerRange], encoding: .isoLatin1) ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")

        var headers: [String: String] = [:]
        var currentKey: String?
        for line in headerBlock.components(separatedBy: "\n") {
            if let first = line.first, first == " " || first == "\t", let key = currentKey {
                headers[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
                currentKey = key
            }
        }
        return (headers, bodyRange)
    }

    /// Strips ONLY the RFC 2046 §5.1.1 boundary-owned leading newline (after `--boundary`)
    /// and the single trailing CRLF/LF immediately preceding the next `--boundary` on raw byte ranges.
    private static func stripMultipartBoundaryDelimitersBytes(in data: Data, range: Range<Int>) -> Range<Int> {
        let base = data.startIndex
        var relStart = range.lowerBound - base
        var relEnd = range.upperBound - base
        guard relStart < relEnd else { return range.lowerBound..<range.lowerBound }

        data.withUnsafeBytes { rawBuf in
            guard let ptr = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return }
            // Strip optional transport padding (spaces/tabs) on the boundary line up to and including the first newline.
            var k = relStart
            while k < relEnd && (ptr[k] == 0x20 || ptr[k] == 0x09) {
                k += 1
            }
            if k < relEnd {
                if ptr[k] == 0x0D {
                    relStart = (k + 1 < relEnd && ptr[k + 1] == 0x0A) ? k + 2 : k + 1
                } else if ptr[k] == 0x0A {
                    relStart = k + 1
                }
            }
            // Strip exactly ONE trailing CRLF or LF/CR belonging to the following delimiter line.
            if relEnd > relStart {
                let last = ptr[relEnd - 1]
                if last == 0x0A {
                    relEnd -= 1
                    if relEnd > relStart && ptr[relEnd - 1] == 0x0D {
                        relEnd -= 1
                    }
                } else if last == 0x0D {
                    relEnd -= 1
                }
            }
        }
        return (base + relStart)..<(base + relEnd)
    }

    private static func extractReadableBodyBytes(
        in data: Data,
        bodyRange: Range<Int>,
        contentType: String,
        transferEncoding: String,
        contentDisposition: String,
        contentID: String?,
        sourcePath: String?,
        attachments: inout [MailAttachment],
        cidImages: inout [String: String],
        plainTextOnly: Bool = false,
        collectedAttachmentNames: inout [String]
    ) -> (plain: String, html: String?) {
        let lowerCT = contentType.lowercased()
        let lowerDisp = contentDisposition.lowercased()

        if lowerCT.contains("multipart/"), let boundary = extractParameter(named: "boundary", from: contentType) {
            let delimiterBytes = Data(("--" + boundary).utf8)
            guard !delimiterBytes.isEmpty else { return ("", nil) }
            let isAlternative = lowerCT.contains("multipart/alternative")

            var foundPlain: String?
            var foundHTML: String?
            var cursor = data.range(of: delimiterBytes, in: bodyRange)?.upperBound

            while let partStart = cursor {
                if Task.isCancelled { break }
                // Closing boundary `--boundary--`
                if partStart + 2 <= bodyRange.upperBound,
                   data[partStart] == 0x2D,
                   data[partStart + 1] == 0x2D {
                    break
                }

                let nextDelim = data.range(of: delimiterBytes, in: partStart..<bodyRange.upperBound)
                let rawPartRange = partStart..<(nextDelim?.lowerBound ?? bodyRange.upperBound)
                cursor = nextDelim?.upperBound

                let cleanRange = stripMultipartBoundaryDelimitersBytes(in: data, range: rawPartRange)
                if cleanRange.isEmpty { continue }

                let (partHeaders, partBodyRange) = splitHeadersAndBodyBytes(in: data, range: cleanRange)
                let partCT = partHeaders["content-type"] ?? "text/plain"
                let partTE = partHeaders["content-transfer-encoding"] ?? ""
                let partDisp = partHeaders["content-disposition"] ?? ""
                let sub = extractReadableBodyBytes(
                    in: data,
                    bodyRange: partBodyRange,
                    contentType: partCT,
                    transferEncoding: partTE,
                    contentDisposition: partDisp,
                    contentID: partHeaders["content-id"],
                    sourcePath: sourcePath,
                    attachments: &attachments,
                    cidImages: &cidImages,
                    plainTextOnly: plainTextOnly,
                    collectedAttachmentNames: &collectedAttachmentNames
                )

                if foundPlain == nil, !sub.plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !partCT.lowercased().contains("text/html") {
                    foundPlain = sub.plain
                    // Inside multipart/alternative there are no attachments; stop immediately.
                    if plainTextOnly && isAlternative {
                        return (sub.plain, nil)
                    }
                }
                if foundHTML == nil, let h = sub.html {
                    foundHTML = h
                }
            }

            if let plain = foundPlain {
                return (plain, plainTextOnly ? nil : foundHTML)
            }
            if let html = foundHTML {
                return (stripHTML(html), plainTextOnly ? nil : html)
            }
            return ("", nil)
        }

        // Capture inline `cid:` images (common in Outlook / corporate / 163 emails) for HTML embedding.
        if lowerCT.contains("image/"),
           let rawCID = contentID?.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n")),
           !rawCID.isEmpty {
            if plainTextOnly {
                if lowerDisp.contains("attachment"),
                   let rawName = extractFilename(fromDisposition: contentDisposition, contentType: contentType) {
                    collectedAttachmentNames.append(decodeMIMEFilename(rawName))
                }
                return ("", nil)
            }
            let mime = contentType.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "image/png"
            let rawBytes = decodeBinaryDataBytes(data[bodyRange], encoding: transferEncoding)
            if !rawBytes.isEmpty {
                let dataURI = "data:\(mime);base64,\(rawBytes.base64EncodedString())"
                cidImages[rawCID.lowercased()] = dataURI
                if !lowerDisp.contains("attachment") {
                    return ("", nil)
                }
            }
        }

        // Detect MIME attachments (explicit `attachment` disposition or named non-body parts)
        let rawFilename = extractFilename(fromDisposition: contentDisposition, contentType: contentType)
        let isExplicitAttachment = lowerDisp.contains("attachment")
        let isNonBodyPart = !lowerCT.contains("text/plain") && !lowerCT.contains("text/html") && !lowerCT.isEmpty
        if isExplicitAttachment || (rawFilename != nil && isNonBodyPart) {
            if plainTextOnly {
                if let rawFilename {
                    collectedAttachmentNames.append(decodeMIMEFilename(rawFilename))
                }
                return ("", nil)
            }
            guard !bodyRange.isEmpty else { return ("", nil) }
            let decodedName = decodeMIMEFilename(rawFilename ?? "attachment")
            let mime = contentType.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "application/octet-stream"

            if let sourcePath {
                // Lazy attachment descriptor: keep exact byte range in `.emlx` and decode only when opened/saved.
                let estimatedSize = estimateDecodedSize(in: data, range: bodyRange, encoding: transferEncoding)
                if estimatedSize > 0 {
                    attachments.append(
                        MailAttachment(
                            id: "inline-\(attachments.count)-\(decodedName)",
                            filename: decodedName,
                            mimeType: mime,
                            sizeBytes: estimatedSize,
                            localFileURL: nil,
                            inlineData: nil,
                            sourceEmlxPath: sourcePath,
                            sourceByteRange: bodyRange,
                            sourceTransferEncoding: transferEncoding
                        )
                    )
                }
            } else {
                let rawBytes = decodeBinaryDataBytes(data[bodyRange], encoding: transferEncoding)
                if !rawBytes.isEmpty {
                    attachments.append(
                        MailAttachment(
                            id: "inline-\(attachments.count)-\(decodedName)",
                            filename: decodedName,
                            mimeType: mime,
                            sizeBytes: rawBytes.count,
                            localFileURL: nil,
                            inlineData: rawBytes
                        )
                    )
                }
            }
            return ("", nil)
        }

        if !lowerCT.contains("text/html") && !lowerCT.contains("text/plain") && !lowerCT.isEmpty {
            return ("", nil)
        }

        let charset = extractParameter(named: "charset", from: contentType) ?? "utf-8"
        let decoded = decodeTransferEncodingBytes(data[bodyRange], encoding: transferEncoding, charset: charset)

        if lowerCT.contains("text/html") {
            return (stripHTML(decoded), decoded)
        }
        return (decoded, nil)
    }

    private static func estimateDecodedSize(in data: Data, range: Range<Int>, encoding: String) -> Int {
        let lower = encoding.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !range.isEmpty else { return 0 }
        if lower == "base64" {
            if range.count <= 4096 {
                return decodeBinaryDataBytes(data[range], encoding: "base64").count
            }
            // Account for typical 76-char RFC 2045 line wrapping (~78 bytes/line with CRLF).
            return max(1, (range.count * 76 / 78) * 3 / 4)
        }
        return range.count
    }

    /// Replaces `<img src="cid:...">` references in HTML with inline `data:image/...;base64,...` URIs.
    static func inlineCIDImages(in html: String, cidMap: [String: String]) -> String {
        guard !cidMap.isEmpty, let regex = cidRefRegex else { return html }
        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        guard !matches.isEmpty else { return html }

        let mutable = NSMutableString(string: html)
        for match in matches.reversed() {
            let rawRef = nsHTML.substring(with: match.range(at: 1))
            let decodedRef = (rawRef.removingPercentEncoding ?? rawRef).lowercased()
            if let dataURI = cidMap[decodedRef] {
                mutable.replaceCharacters(in: match.range, with: dataURI)
            }
        }
        return mutable as String
    }

    private static func scanExternalAttachments(for rowID: Int64, nearEmlxURL: URL) -> [MailAttachment] {
        let fm = FileManager.default
        var candidateDirs: [URL] = []

        // Apple Mail stores externalized attachments in `<mailbox>/Data/.../Attachments/<rowID>/`
        // Walk up to 5 ancestor directories looking for an `Attachments/<rowID>` folder.
        var cursor = nearEmlxURL.deletingLastPathComponent()
        for _ in 0..<5 {
            let attDir = cursor
                .appendingPathComponent("Attachments", isDirectory: true)
                .appendingPathComponent("\(rowID)", isDirectory: true)
            if fm.fileExists(atPath: attDir.path) {
                candidateDirs.append(attDir)
                break
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }

        var results: [MailAttachment] = []
        for dir in candidateDirs {
            guard let enumerator = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true else { continue }
                let size = values.fileSize ?? 0
                results.append(
                    MailAttachment(
                        id: "ext-\(fileURL.path)",
                        filename: fileURL.lastPathComponent,
                        mimeType: "application/octet-stream",
                        sizeBytes: size,
                        localFileURL: fileURL,
                        inlineData: nil
                    )
                )
            }
        }
        return results
    }

    private static func extractFilename(fromDisposition disposition: String, contentType: String) -> String? {
        if let fStar = extractParameter(named: "filename\\*", from: disposition) { return fStar }
        if let f = extractParameter(named: "filename", from: disposition) { return f }
        if let nStar = extractParameter(named: "name\\*", from: contentType) { return nStar }
        if let n = extractParameter(named: "name", from: contentType) { return n }
        return nil
    }

    private static func decodeBinaryDataBytes(_ slice: Data, encoding: String) -> Data {
        let lower = encoding.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower == "base64" {
            if let raw = Data(base64Encoded: slice, options: .ignoreUnknownCharacters) {
                return raw
            }
        } else if lower == "quoted-printable" {
            return decodeQuotedPrintableBytes(slice)
        }
        return Data(slice)
    }

    /// Decodes RFC 2231 (`utf-8''...`), RFC 2047 (`=?UTF-8?B?...?=` / `=?UTF-8?Q?...?=`),
    /// and raw UTF-8/GB18030 attachment filenames preserved inside the ISO-Latin-1 container.
    public static func decodeMIMEFilename(_ raw: String) -> String {
        var result = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))

        // RFC 2231: charset'lang'percent-encoded
        if let rfc2231Range = result.range(of: #"^[A-Za-z0-9_\-]+'[A-Za-z0-9_\-]*'"#, options: .regularExpression) {
            let encodedPart = String(result[rfc2231Range.upperBound...])
            if let decoded = encodedPart.removingPercentEncoding {
                return decoded
            }
        }

        // RFC 2047: =?charset?B|Q?payload?=
        if let regex = rfc2047Regex {
            let nsString = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))
            if !matches.isEmpty {
                let mutable = NSMutableString(string: result)
                for match in matches.reversed() {
                    let charset = nsString.substring(with: match.range(at: 1))
                    let encType = nsString.substring(with: match.range(at: 2)).uppercased()
                    let payload = nsString.substring(with: match.range(at: 3))
                    let strEncoding = resolveStringEncoding(charset)

                    var decodedChunk: String?
                    if encType == "B", let rawData = Data(base64Encoded: payload) {
                        decodedChunk = String(data: rawData, encoding: strEncoding) ?? String(data: rawData, encoding: .utf8)
                    } else if encType == "Q" {
                        let qpData = decodeQuotedPrintable(payload.replacingOccurrences(of: "_", with: " "))
                        decodedChunk = String(data: qpData, encoding: strEncoding) ?? String(data: qpData, encoding: .utf8)
                    }
                    if let decodedChunk {
                        mutable.replaceCharacters(in: match.range, with: decodedChunk)
                    }
                }
                result = mutable as String
                return result
            }
        }

        // Raw non-ASCII filename inside the lossless ISO-Latin-1 container: restore UTF-8 (or GB18030) bytes.
        if result.unicodeScalars.contains(where: { $0.value >= 0x80 && $0.value <= 0xFF }),
           let rawBytes = result.data(using: .isoLatin1) {
            if let utf8Name = String(data: rawBytes, encoding: .utf8) {
                return utf8Name
            }
            if let gbName = String(data: rawBytes, encoding: resolveStringEncoding("gb18030")) {
                return gbName
            }
        }
        return result
    }

    private static func extractParameter(named name: String, from header: String) -> String? {
        let regex: NSRegularExpression
        if let cached = parameterRegexes[name] {
            regex = cached
        } else {
            let pattern = "(?i)\(name)\\s*=\\s*(?:\"([^\"]+)\"|'([^']+)'|([^;\\s]+))"
            guard let compiled = try? NSRegularExpression(pattern: pattern) else { return nil }
            regex = compiled
        }
        let range = NSRange(header.startIndex..<header.endIndex, in: header)
        guard let match = regex.firstMatch(in: header, range: range) else { return nil }
        for group in 1...3 {
            if let r = Range(match.range(at: group), in: header) {
                return String(header[r])
            }
        }
        return nil
    }

    private static func decodeTransferEncodingBytes(_ slice: Data, encoding: String, charset: String) -> String {
        let lower = encoding.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let stringEncoding = resolveStringEncoding(charset)

        if lower == "base64" {
            if let raw = Data(base64Encoded: slice, options: .ignoreUnknownCharacters) {
                return String(data: raw, encoding: stringEncoding)
                    ?? String(data: raw, encoding: .utf8)
                    ?? String(data: slice, encoding: .isoLatin1)
                    ?? ""
            }
        } else if lower == "quoted-printable" {
            let decodedData = decodeQuotedPrintableBytes(slice)
            return String(data: decodedData, encoding: stringEncoding)
                ?? String(data: decodedData, encoding: .utf8)
                ?? String(data: slice, encoding: .isoLatin1)
                ?? ""
        } else {
            // 8bit / 7bit / binary: decode raw bytes directly using declared charset.
            if let decoded = String(data: slice, encoding: stringEncoding) {
                return decoded
            }
            if let utf8 = String(data: slice, encoding: .utf8) {
                return utf8
            }
        }
        return String(data: slice, encoding: .isoLatin1) ?? ""
    }

    private static func decodeQuotedPrintable(_ input: String) -> Data {
        decodeQuotedPrintableBytes(input.data(using: .isoLatin1) ?? Data(input.utf8))
    }

    private static func decodeQuotedPrintableBytes(_ slice: Data) -> Data {
        // Operate directly on lossless raw bytes so RFC 2045 CRLF (`=\r\n`), LF (`=\n`), CR (`=\r`),
        // and optional transport-padded (`=[ \t]*\r?\n`) soft line breaks are unfolded cleanly.
        var bytes: [UInt8] = []
        bytes.reserveCapacity(slice.count)

        func hexNibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: return byte - 0x30
            case 0x41...0x46: return byte - 0x41 + 10
            case 0x61...0x66: return byte - 0x61 + 10
            default: return nil
            }
        }

        slice.withUnsafeBytes { rawBuf in
            guard let ptr = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = rawBuf.count
            var i = 0
            while i < count {
                if ptr[i] == 0x3D { // '='
                    // RFC 2045 §6.7 soft line break: '=' + optional linear whitespace + CRLF/LF/CR
                    var j = i + 1
                    while j < count && (ptr[j] == 0x20 || ptr[j] == 0x09) {
                        j += 1
                    }
                    if j < count {
                        if ptr[j] == 0x0D {
                            i = (j + 1 < count && ptr[j + 1] == 0x0A) ? j + 2 : j + 1
                            continue
                        } else if ptr[j] == 0x0A {
                            i = j + 1
                            continue
                        }
                    }
                    if i + 2 < count,
                       let hi = hexNibble(ptr[i + 1]),
                       let lo = hexNibble(ptr[i + 2]) {
                        bytes.append((hi << 4) | lo)
                        i += 3
                        continue
                    }
                }
                bytes.append(ptr[i])
                i += 1
            }
        }
        return Data(bytes)
    }

    private static func resolveStringEncoding(_ charset: String) -> String.Encoding {
        switch charset.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "utf-8", "utf8":
            return .utf8
        case "iso-8859-1", "latin1":
            return .isoLatin1
        case "gbk", "gb2312", "gb18030":
            let cfEnc = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
            return String.Encoding(rawValue: cfEnc)
        default:
            return .utf8
        }
    }

    static func stripHTML(_ html: String) -> String {
        var text = html
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for (regex, replacement) in htmlBlockRegexes {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
        }
        if let tagRegex = htmlTagRegex {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = tagRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }
        text = decodeHTMLEntities(text)

        // Strip invisible spacing / zero-width characters commonly used in marketing HTML emails.
        let invisibleScalars: Set<Unicode.Scalar> = [
            "\u{200A}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{00AD}", "\u{034F}"
        ]
        text = String(text.unicodeScalars.filter { !invisibleScalars.contains($0) })

        let lines = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var collapsed: [String] = []
        var emptyRun = 0
        for line in lines {
            if line.isEmpty {
                emptyRun += 1
                if emptyRun <= 1 { collapsed.append("") }
            } else {
                emptyRun = 0
                collapsed.append(line)
            }
        }
        return collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeHTMLEntities(_ input: String) -> String {
        let result = input
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&zwnj;", with: "")
            .replacingOccurrences(of: "&zwj;", with: "")

        // Decode numeric entities: decimal `&#24744;` and hex `&#x60A8;`.
        guard let regex = numericEntityRegex else {
            return result
        }
        let nsString = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return result }

        let mutable = NSMutableString(string: result)
        for match in matches.reversed() {
            var codePoint: UInt32?
            if match.range(at: 1).location != NSNotFound {
                let hex = nsString.substring(with: match.range(at: 1))
                codePoint = UInt32(hex, radix: 16)
            } else if match.range(at: 2).location != NSNotFound {
                let dec = nsString.substring(with: match.range(at: 2))
                codePoint = UInt32(dec, radix: 10)
            }
            if let cp = codePoint, let scalar = Unicode.Scalar(cp) {
                mutable.replaceCharacters(in: match.range, with: String(scalar))
            }
        }
        return mutable as String
    }

    /// Detects 4-8 digit sign-in / OTP verification codes in Chinese and English emails.
    public static func extractVerificationCode(from text: String) -> String? {
        for regex in verificationCodeRegexes {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, range: range),
               let codeRange = Range(match.range(at: 1), in: text) {
                return String(text[codeRange])
            }
        }
        return nil
    }
}
