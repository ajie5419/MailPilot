import Foundation

/// Parses Apple Mail `.emlx` files into readable plain text and extracts verification codes.
public actor EmlxParser {
    private let mailRootURL: URL
    private var pathCache: [Int64: URL] = [:]
    private var dataRoots: [URL] = []
    private var hasIndexedFiles = false

    public init(mailRootURL: URL) {
        self.mailRootURL = mailRootURL
    }

    public func loadBody(for rowID: Int64) -> ParsedMailBody {
        guard let fileURL = locateEmlx(rowID: rowID) else {
            return ParsedMailBody(
                plainText: "（该邮件正文尚未缓存在本地 .emlx 中，可点击右上角「在 Mail 中打开」触发系统加载。）"
            )
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            return ParsedMailBody(
                plainText: "（无法读取本地邮件文件：\(fileURL.lastPathComponent)）",
                sourcePath: fileURL.path
            )
        }

        var parsed = Self.parseEmlxData(data, sourcePath: fileURL.path)
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
                attachments: merged
            )
        }
        return parsed
    }

    public func invalidateCache() {
        pathCache.removeAll()
        hasIndexedFiles = false
    }

    private func locateEmlx(rowID: Int64) -> URL? {
        if let cached = pathCache[rowID], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        // Fast O(1) bucket lookup using Apple Mail's reversed-digit Data/ directory layout (< 2ms).
        if !dataRoots.isEmpty, let direct = fastBucketLookup(rowID: rowID) {
            pathCache[rowID] = direct
            return direct
        }
        if !hasIndexedFiles {
            rebuildIndex()
            if let cached = pathCache[rowID] {
                return cached
            }
            if let direct = fastBucketLookup(rowID: rowID) {
                pathCache[rowID] = direct
                return direct
            }
        }
        // Final fallback for newly created mailboxes not yet in `dataRoots`.
        rebuildIndex()
        return pathCache[rowID]
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

    private func fastBucketLookup(rowID: Int64) -> URL? {
        let fm = FileManager.default
        let relPaths = Self.bucketRelativePaths(for: rowID)
        for root in dataRoots {
            for rel in relPaths {
                let candidate = root.appendingPathComponent(rel)
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    private func rebuildIndex() {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: mailRootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var fresh: [Int64: URL] = [:]
        var discoveredDataRoots: Set<URL> = []
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            if name == "Data" {
                discoveredDataRoots.insert(fileURL)
                continue
            }
            guard name.hasSuffix(".emlx") else { continue }
            let prefix = name.split(separator: ".").first.map(String.init) ?? ""
            if let id = Int64(prefix) {
                // Prefer full `.emlx` over `.partial.emlx`.
                if fresh[id] == nil || !name.contains(".partial.") {
                    fresh[id] = fileURL
                }
            }
        }
        pathCache = fresh
        dataRoots = Array(discoveredDataRoots)
        hasIndexedFiles = true
    }

    // MARK: - Pure Parsing Helpers (Testable)

    public static func parseEmlxData(_ data: Data, sourcePath: String? = nil) -> ParsedMailBody {
        let messageData = stripEmlxHeader(from: data)
        let rawString = String(data: messageData, encoding: .utf8)
            ?? String(data: messageData, encoding: .isoLatin1)
            ?? ""

        let (headers, body) = splitHeadersAndBody(rawString)
        let contentType = headers["content-type"] ?? "text/plain"
        let transferEncoding = headers["content-transfer-encoding"] ?? ""
        let disposition = headers["content-disposition"] ?? ""

        var attachments: [MailAttachment] = []
        var cidImages: [String: String] = [:]
        let extracted = extractReadableBody(
            body: body,
            contentType: contentType,
            transferEncoding: transferEncoding,
            contentDisposition: disposition,
            contentID: headers["content-id"],
            attachments: &attachments,
            cidImages: &cidImages
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
            attachments: attachments
        )
    }

    /// `.emlx` starts with an ASCII byte count line followed by the RFC822 message and a trailing XML plist.
    static func stripEmlxHeader(from data: Data) -> Data {
        guard let newlineIndex = data.firstIndex(of: 0x0A) else {
            return data
        }
        let firstLineData = data.subdata(in: 0..<newlineIndex)
        let firstLine = String(data: firstLineData, encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard let declaredLength = Int(firstLine), declaredLength > 0 else {
            return data
        }

        let bodyStart = data.index(after: newlineIndex)
        let bodyEnd = min(data.count, bodyStart + declaredLength)
        guard bodyStart < bodyEnd else { return data }
        return data.subdata(in: bodyStart..<bodyEnd)
    }

    private static func splitHeadersAndBody(_ raw: String) -> ([String: String], String) {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let splitRange: Range<String.Index>?
        if let direct = normalized.range(of: "\n\n") {
            splitRange = direct
        } else if let regex = try? NSRegularExpression(pattern: "\n[ \t]*\n"),
                  let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)) {
            splitRange = Range(match.range, in: normalized)
        } else {
            splitRange = nil
        }
        guard let splitRange else {
            return ([:], normalized)
        }
        let headerBlock = String(normalized[..<splitRange.lowerBound])
        let body = String(normalized[splitRange.upperBound...])

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
        return (headers, body)
    }

    private static func extractReadableBody(
        body: String,
        contentType: String,
        transferEncoding: String,
        contentDisposition: String,
        contentID: String?,
        attachments: inout [MailAttachment],
        cidImages: inout [String: String]
    ) -> (plain: String, html: String?) {
        let lowerCT = contentType.lowercased()
        let lowerDisp = contentDisposition.lowercased()

        if lowerCT.contains("multipart/"), let boundary = extractParameter(named: "boundary", from: contentType) {
            let delimiter = "--" + boundary
            let parts = body.components(separatedBy: delimiter)
            var foundPlain: String?
            var foundHTML: String?

            for part in parts.dropFirst() {
                if part.hasPrefix("--") { break }
                let trimmedPart = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedPart.isEmpty { continue }

                let (partHeaders, partBody) = splitHeadersAndBody(trimmedPart)
                let partCT = partHeaders["content-type"] ?? "text/plain"
                let partTE = partHeaders["content-transfer-encoding"] ?? ""
                let partDisp = partHeaders["content-disposition"] ?? ""
                let sub = extractReadableBody(
                    body: partBody,
                    contentType: partCT,
                    transferEncoding: partTE,
                    contentDisposition: partDisp,
                    contentID: partHeaders["content-id"],
                    attachments: &attachments,
                    cidImages: &cidImages
                )

                if foundPlain == nil, !sub.plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !partCT.lowercased().contains("text/html") {
                    foundPlain = sub.plain
                }
                if foundHTML == nil, let h = sub.html {
                    foundHTML = h
                }
            }

            if let plain = foundPlain {
                return (plain, foundHTML)
            }
            if let html = foundHTML {
                return (stripHTML(html), html)
            }
            return ("", nil)
        }

        // Capture inline `cid:` images (common in Outlook / corporate / 163 emails) for HTML embedding.
        if lowerCT.contains("image/"),
           let rawCID = contentID?.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n")),
           !rawCID.isEmpty {
            let mime = contentType.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "image/png"
            let rawBytes = decodeBinaryData(body, encoding: transferEncoding)
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
            let decodedName = decodeMIMEFilename(rawFilename ?? "attachment")
            let mime = contentType.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "application/octet-stream"
            let rawBytes = decodeBinaryData(body, encoding: transferEncoding)
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
            return ("", nil)
        }

        let charset = extractParameter(named: "charset", from: contentType) ?? "utf-8"
        let decoded = decodeTransferEncoding(body, encoding: transferEncoding, charset: charset)

        if lowerCT.contains("text/html") {
            return (stripHTML(decoded), decoded)
        }
        if lowerCT.contains("text/plain") || lowerCT.isEmpty {
            return (decoded, nil)
        }
        return ("", nil)
    }

    /// Replaces `<img src="cid:...">` references in HTML with inline `data:image/...;base64,...` URIs.
    static func inlineCIDImages(in html: String, cidMap: [String: String]) -> String {
        guard !cidMap.isEmpty else { return html }
        guard let regex = try? NSRegularExpression(pattern: #"(?i)cid:([^"'\s>]+)"#) else {
            return html
        }
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

    private static func decodeBinaryData(_ text: String, encoding: String) -> Data {
        let lower = encoding.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower == "base64" {
            let cleaned = text.components(separatedBy: .whitespacesAndNewlines).joined()
            if let raw = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters) {
                return raw
            }
        } else if lower == "quoted-printable" {
            return decodeQuotedPrintable(text)
        }
        return Data(text.utf8)
    }

    /// Decodes RFC 2231 (`utf-8''...`) and RFC 2047 (`=?UTF-8?B?...?=` / `=?UTF-8?Q?...?=`) attachment filenames.
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
        let pattern = #"=\?([^?]+)\?([BbQq])\?([^?]+)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let nsString = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return result }

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

    private static func extractParameter(named name: String, from header: String) -> String? {
        let pattern = "(?i)\(name)\\s*=\\s*(?:\"([^\"]+)\"|'([^']+)'|([^;\\s]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(header.startIndex..<header.endIndex, in: header)
        guard let match = regex.firstMatch(in: header, range: range) else { return nil }
        for group in 1...3 {
            if let r = Range(match.range(at: group), in: header) {
                return String(header[r])
            }
        }
        return nil
    }

    private static func decodeTransferEncoding(_ text: String, encoding: String, charset: String) -> String {
        let lower = encoding.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let stringEncoding = resolveStringEncoding(charset)

        if lower == "base64" {
            let cleaned = text.components(separatedBy: .whitespacesAndNewlines).joined()
            if let raw = Data(base64Encoded: cleaned) {
                return String(data: raw, encoding: stringEncoding)
                    ?? String(data: raw, encoding: .utf8)
                    ?? text
            }
        } else if lower == "quoted-printable" {
            let decodedData = decodeQuotedPrintable(text)
            return String(data: decodedData, encoding: stringEncoding)
                ?? String(data: decodedData, encoding: .utf8)
                ?? text
        }
        return text
    }

    private static func decodeQuotedPrintable(_ input: String) -> Data {
        let unfolded = input.replacingOccurrences(of: "=\n", with: "")
        var bytes: [UInt8] = []
        let scalars = Array(unfolded.utf8)
        var i = 0
        while i < scalars.count {
            if scalars[i] == 0x3D, i + 2 < scalars.count {
                let hex = String(bytes: [scalars[i + 1], scalars[i + 2]], encoding: .ascii) ?? ""
                if let val = UInt8(hex, radix: 16) {
                    bytes.append(val)
                    i += 3
                    continue
                }
            }
            bytes.append(scalars[i])
            i += 1
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
        let blockPatterns = [
            "(?is)<style[^>]*>.*?</style>",
            "(?is)<script[^>]*>.*?</script>",
            "(?i)<br\\s*/?>",
            "(?i)</p>",
            "(?i)</div>",
            "(?i)</tr>",
            "(?i)</li>"
        ]
        for (idx, pattern) in blockPatterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let replacement = idx < 2 ? "" : "\n"
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
        }
        if let tagRegex = try? NSRegularExpression(pattern: "<[^>]+>") {
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
        guard let regex = try? NSRegularExpression(pattern: #"&#(?:x([0-9A-Fa-f]+)|(\d+));"#) else {
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
        let patterns = [
            #"(?:验证码|校验码|动态码|安全码|登录码)[^\dA-Za-z]{0,12}(\d{4,8})\b"#,
            #"(?i)(?:verification code|security code|sign-in code|login code|one-time password|OTP|passcode)[^\d]{0,20}(\d{4,8})\b"#,
            #"(?i)\bcode\s*(?:is|:)\s*(\d{4,8})\b"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, range: range),
               let codeRange = Range(match.range(at: 1), in: text) {
                return String(text[codeRange])
            }
        }
        return nil
    }
}
