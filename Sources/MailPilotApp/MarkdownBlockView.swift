import SwiftUI

/// Clean native SwiftUI Markdown renderer for headings (`##`), bullet lists (`- `),
/// numbered lists, and inline bold/code formatting without exposing raw `##` or `-` markers.
struct MarkdownBlockView: View {
    let text: String

    private enum Block: Identifiable {
        case heading(level: Int, text: String)
        case bullet(text: String)
        case numbered(index: String, text: String)
        case paragraph(text: String)

        var id: String {
            switch self {
            case .heading(let l, let t): return "h\(l)-\(t)"
            case .bullet(let t): return "b-\(t)"
            case .numbered(let i, let t): return "n\(i)-\(t)"
            case .paragraph(let t): return "p-\(t)"
            }
        }
    }

    var body: some View {
        let blocks = parseBlocks(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let title):
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.accentColor)
                            .frame(width: 3, height: level <= 2 ? 13 : 11)
                        inlineMarkdown(title)
                            .font(level <= 2 ? .callout.weight(.semibold) : .subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .padding(.top, 4)

                case .bullet(let item):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle()
                            .fill(Color.accentColor.opacity(0.75))
                            .frame(width: 4.5, height: 4.5)
                            .offset(y: -1)
                        inlineMarkdown(item)
                            .font(.callout)
                            .foregroundStyle(.primary.opacity(0.92))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 4)

                case .numbered(let idx, let item):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(idx).")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        inlineMarkdown(item)
                            .font(.callout)
                            .foregroundStyle(.primary.opacity(0.92))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 2)

                case .paragraph(let content):
                    inlineMarkdown(content)
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inlineMarkdown(_ raw: String) -> Text {
        if let attr = try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attr)
        }
        return Text(raw)
    }

    private func parseBlocks(_ raw: String) -> [Block] {
        var result: [Block] = []
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("### ") {
                result.append(.heading(level: 3, text: String(trimmed.dropFirst(4))))
            } else if trimmed.hasPrefix("## ") {
                result.append(.heading(level: 2, text: String(trimmed.dropFirst(3))))
            } else if trimmed.hasPrefix("# ") {
                result.append(.heading(level: 1, text: String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                result.append(.bullet(text: String(trimmed.dropFirst(2))))
            } else if let dotRange = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                let prefix = String(trimmed[dotRange])
                let num = prefix.trimmingCharacters(in: CharacterSet.decimalDigits.inverted)
                let rest = String(trimmed[dotRange.upperBound...])
                result.append(.numbered(index: num, text: rest))
            } else {
                result.append(.paragraph(text: trimmed))
            }
        }
        return result
    }
}
