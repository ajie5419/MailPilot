import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

public struct ExtractedAttachmentText: Sendable, Equatable {
    public let filename: String
    public let method: String
    public let text: String
    public let wasTruncated: Bool

    public init(filename: String, method: String, text: String, wasTruncated: Bool) {
        self.filename = filename
        self.method = method
        self.text = text
        self.wasTruncated = wasTruncated
    }
}

public enum AttachmentExtractionResult: Sendable, Equatable {
    case extracted(ExtractedAttachmentText)
    case skipped(filename: String, reason: String)
}

/// Extracts readable plain text from local email attachments strictly on-device using native macOS
/// frameworks (`PDFKit`, AppKit `NSAttributedString`, and offline `Vision` OCR) with strict memory
/// and character budgets so AI analysis stays fast and privacy-preserving.
public enum AttachmentTextExtractor {
    public static let maxSourceFileBytes = 20 * 1024 * 1024
    public static let maxCharsPerAttachment = 6_000
    public static let maxTotalChars = 12_000

    private static let plainTextExtensions: Set<String> = [
        "txt", "csv", "tsv", "md", "markdown", "json", "xml", "yml", "yaml",
        "log", "ini", "conf", "cfg", "sql", "swift", "py", "js", "ts", "css",
        "html", "htm", "eml", "ics", "vcf"
    ]
    private static let wordExtensions: Set<String> = ["docx", "rtf", "doc"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "gif", "bmp", "tif", "tiff"]

    public static func isSupportedForAI(_ attachment: MailAttachment) -> Bool {
        let ext = attachment.fileExtension
        if ext == "pdf" || attachment.mimeType.lowercased().contains("pdf") {
            return true
        }
        if plainTextExtensions.contains(ext) || attachment.mimeType.lowercased().hasPrefix("text/") {
            return true
        }
        if wordExtensions.contains(ext) {
            return true
        }
        if imageExtensions.contains(ext) || attachment.mimeType.lowercased().hasPrefix("image/") {
            return true
        }
        return false
    }

    /// Extracts text from a single `MailAttachment` (on-demand decoding from `.emlx` or reading local file).
    public static func extract(
        from attachment: MailAttachment,
        maxChars: Int = maxCharsPerAttachment
    ) -> AttachmentExtractionResult {
        if attachment.sizeBytes > maxSourceFileBytes {
            return .skipped(filename: attachment.filename, reason: "附件超过 20 MB，已跳过自动读取")
        }
        guard isSupportedForAI(attachment) else {
            return .skipped(filename: attachment.filename, reason: "暂不支持解析 .\(attachment.fileExtension.isEmpty ? "未知" : attachment.fileExtension) 格式")
        }
        guard let rawData = loadAttachmentBytes(attachment) else {
            return .skipped(filename: attachment.filename, reason: "附件尚未缓存在本地")
        }
        if rawData.count > maxSourceFileBytes {
            return .skipped(filename: attachment.filename, reason: "附件超过 20 MB，已跳过自动读取")
        }
        return extract(data: rawData, filename: attachment.filename, mimeType: attachment.mimeType, maxChars: maxChars)
    }

    /// Pure data-based extractor (also directly unit-testable).
    public static func extract(
        data: Data,
        filename: String,
        mimeType: String = "",
        maxChars: Int = maxCharsPerAttachment
    ) -> AttachmentExtractionResult {
        let ext = (filename as NSString).pathExtension.lowercased()
        let lowerMime = mimeType.lowercased()

        if ext == "pdf" || lowerMime.contains("pdf") {
            return extractPDF(data: data, filename: filename, maxChars: maxChars)
        }
        if plainTextExtensions.contains(ext) || lowerMime.hasPrefix("text/") {
            return extractPlainText(data: data, filename: filename, ext: ext, maxChars: maxChars)
        }
        if wordExtensions.contains(ext) {
            return extractOfficeDocument(data: data, filename: filename, ext: ext, maxChars: maxChars)
        }
        if imageExtensions.contains(ext) || lowerMime.hasPrefix("image/") {
            return extractImageOCR(data: data, filename: filename, maxChars: maxChars)
        }
        return .skipped(filename: filename, reason: "不支持的文件格式")
    }

    /// Extracts text across multiple attachments within a combined character budget.
    public static func extractBatch(
        from attachments: [MailAttachment],
        maxTotalChars: Int = maxTotalChars
    ) -> (extracted: [ExtractedAttachmentText], skipped: [(filename: String, reason: String)]) {
        var remaining = max(500, maxTotalChars)
        var extracted: [ExtractedAttachmentText] = []
        var skipped: [(String, String)] = []

        for att in attachments {
            if remaining < 200 {
                skipped.append((att.filename, "已达到本次附件文本读取上限"))
                continue
            }
            let budget = min(maxCharsPerAttachment, remaining)
            switch extract(from: att, maxChars: budget) {
            case .extracted(let item):
                extracted.append(item)
                remaining -= item.text.count
            case .skipped(let name, let reason):
                skipped.append((name, reason))
            }
        }
        return (extracted, skipped)
    }

    // MARK: - Format-Specific Extractors

    private static func loadAttachmentBytes(_ attachment: MailAttachment) -> Data? {
        if let local = attachment.localFileURL, FileManager.default.fileExists(atPath: local.path) {
            return try? Data(contentsOf: local, options: .mappedIfSafe)
        }
        return EmlxParser.decodeAttachmentData(attachment)
    }

    private static func extractPlainText(data: Data, filename: String, ext: String, maxChars: Int) -> AttachmentExtractionResult {
        guard var decoded = decodeTextBytes(data) else {
            return .skipped(filename: filename, reason: "无法识别文本编码")
        }
        if ext == "html" || ext == "htm" {
            decoded = stripSimpleHTML(decoded)
        }
        let cleaned = normalizeWhitespace(decoded)
        guard !cleaned.isEmpty else {
            return .skipped(filename: filename, reason: "文件内容为空")
        }
        let (clipped, truncated) = clip(cleaned, maxChars: maxChars)
        let label = (ext == "csv" || ext == "tsv") ? "表格文本" : "纯文本"
        return .extracted(ExtractedAttachmentText(filename: filename, method: label, text: clipped, wasTruncated: truncated))
    }

    private static func extractPDF(data: Data, filename: String, maxChars: Int) -> AttachmentExtractionResult {
        guard let pdf = PDFDocument(data: data) else {
            return .skipped(filename: filename, reason: "PDF 文件损坏或已加密")
        }
        if pdf.isLocked {
            return .skipped(filename: filename, reason: "PDF 已加密，无法提取正文")
        }
        let maxPages = min(pdf.pageCount, 30)
        var chunks: [String] = []
        var totalLength = 0
        for pageIndex in 0..<maxPages {
            guard let page = pdf.page(at: pageIndex), let pageText = page.string else { continue }
            let trimmed = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                chunks.append(trimmed)
                totalLength += trimmed.count
                if totalLength >= maxChars + 500 {
                    break
                }
            }
        }

        let combined = normalizeWhitespace(chunks.joined(separator: "\n\n"))
        if combined.count >= 24 {
            let (clipped, truncated) = clip(combined, maxChars: maxChars)
            return .extracted(
                ExtractedAttachmentText(
                    filename: filename,
                    method: "PDF 文本",
                    text: clipped,
                    wasTruncated: truncated || pdf.pageCount > maxPages
                )
            )
        }

        // Scanned PDF fallback: render first up to 3 pages and run offline Vision OCR.
        let ocrPages = min(pdf.pageCount, 3)
        var ocrTexts: [String] = []
        for pageIndex in 0..<ocrPages {
            guard let page = pdf.page(at: pageIndex),
                  let cgImage = renderPDFPageToCGImage(page, maxDimension: 1800) else {
                continue
            }
            if let text = recognizeText(in: cgImage), !text.isEmpty {
                ocrTexts.append(text)
            }
        }
        let ocrCombined = normalizeWhitespace(ocrTexts.joined(separator: "\n\n"))
        if !ocrCombined.isEmpty {
            let (clipped, truncated) = clip(ocrCombined, maxChars: maxChars)
            return .extracted(
                ExtractedAttachmentText(
                    filename: filename,
                    method: "PDF 离线 OCR",
                    text: clipped,
                    wasTruncated: truncated || pdf.pageCount > ocrPages
                )
            )
        }
        return .skipped(filename: filename, reason: "PDF 中未检测到可识别文字")
    }

    private static func extractOfficeDocument(data: Data, filename: String, ext: String, maxChars: Int) -> AttachmentExtractionResult {
        let docType: NSAttributedString.DocumentType
        switch ext {
        case "docx":
            docType = .officeOpenXML
        case "rtf":
            docType = .rtf
        case "doc":
            docType = .docFormat
        default:
            docType = .plain
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: docType]
        guard let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return .skipped(filename: filename, reason: "无法解析该文档格式")
        }
        let cleaned = normalizeWhitespace(attributed.string)
        guard !cleaned.isEmpty else {
            return .skipped(filename: filename, reason: "文档内容为空")
        }
        let (clipped, truncated) = clip(cleaned, maxChars: maxChars)
        return .extracted(ExtractedAttachmentText(filename: filename, method: "文档文本", text: clipped, wasTruncated: truncated))
    }

    private static func extractImageOCR(data: Data, filename: String, maxChars: Int) -> AttachmentExtractionResult {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return .skipped(filename: filename, reason: "无法解码图片")
        }
        guard let text = recognizeText(in: cgImage), !text.isEmpty else {
            return .skipped(filename: filename, reason: "图片中未识别到文字")
        }
        let cleaned = normalizeWhitespace(text)
        let (clipped, truncated) = clip(cleaned, maxChars: maxChars)
        return .extracted(ExtractedAttachmentText(filename: filename, method: "图片离线 OCR", text: clipped, wasTruncated: truncated))
    }

    private static func recognizeText(in cgImage: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        } catch {
            return nil
        }
    }

    private static func renderPDFPageToCGImage(_ page: PDFPage, maxDimension: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(2.0, maxDimension / max(bounds.width, bounds.height))
        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    // MARK: - Helpers

    private static func decodeTextBytes(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let utf16 = String(data: data, encoding: .utf16) {
            return utf16
        }
        let gbEncoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        )
        if let gb = String(data: data, encoding: gbEncoding) {
            return gb
        }
        return String(data: data, encoding: .isoLatin1)
    }

    private static func stripSimpleHTML(_ html: String) -> String {
        html
            .replacingOccurrences(of: #"(?is)<(script|style)[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clip(_ text: String, maxChars: Int) -> (String, Bool) {
        if text.count <= maxChars {
            return (text, false)
        }
        return (String(text.prefix(maxChars)), true)
    }
}
