import Foundation

/// Masks common PII and secret tokens locally before sending email text to a cloud LLM.
public enum PrivacyMasker {
    private static let rules: [(pattern: String, replacement: String)] = [
        // API keys / bearer-like secrets (sk-..., ghp_..., etc.)
        (#"\b(sk-[A-Za-z0-9_\-]{16,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})\b"#, "[API_KEY]"),
        // Chinese mainland mobile numbers
        (#"(?<!\d)1[3-9]\d{9}(?!\d)"#, "[PHONE]"),
        // International phone numbers (rough heuristic with separators)
        (#"(?<!\d)\+\d{1,3}[\s\-]?\(?\d{2,4}\)?[\s\-]?\d{3,4}[\s\-]?\d{3,4}(?!\d)"#, "[PHONE]"),
        // Long card / account numbers (13-19 digits, optionally grouped by spaces/dashes)
        (#"(?<!\d)(?:\d[ \-]?){13,19}(?!\d)"#, "[CARD_OR_ACCOUNT]"),
        // Email addresses
        (#"[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "[EMAIL]")
    ]

    public static func mask(_ text: String) -> String {
        var result = text
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: rule.replacement)
        }
        return result
    }
}
