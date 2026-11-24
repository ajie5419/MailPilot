import AppKit
import Foundation
#if canImport(MailPilotCore)
import MailPilotCore
#endif

/// Asynchronously fetches and caches sender brand favicons (memory + disk) with multi-source fallback.
@MainActor
final class SenderAvatarLoader: ObservableObject {
    static let shared = SenderAvatarLoader()

    @Published private(set) var images: [String: NSImage] = [:]
    private var customImages: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    func customIcon(at path: String?) -> NSImage? {
        guard let path, !path.isEmpty else { return nil }
        if let cached = customImages[path] {
            return cached
        }
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        customImages[path] = img
        return img
    }

    func invalidateCustomIcon(at path: String?) {
        guard let path else { return }
        customImages.removeValue(forKey: path)
        objectWillChange.send()
    }
    private var failedDomains: Set<String> = []
    private let cacheDirectory: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.cacheDirectory = caches.appendingPathComponent("MailPilot/BrandIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func image(for email: String) -> NSImage? {
        guard let domain = SenderDomainHelper.extractBrandDomain(from: email) else {
            return nil
        }
        return loadOrFetch(domain: domain)
    }

    /// Loads the provider/company logo for a user's own email account (including Gmail, iCloud, 163, QQ, corporate domains).
    func accountLogo(for email: String) -> NSImage? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let atIdx = trimmed.lastIndex(of: "@") else { return nil }
        let rawHost = String(trimmed[trimmed.index(after: atIdx)...])
        guard rawHost.contains(".") else { return nil }

        let targetDomain: String
        switch rawHost {
        case "gmail.com", "googlemail.com":
            targetDomain = "mail.google.com"
        case "icloud.com", "me.com", "mac.com":
            targetDomain = "icloud.com"
        case "outlook.com", "hotmail.com", "live.com":
            targetDomain = "outlook.live.com"
        default:
            targetDomain = rawHost
        }
        return loadOrFetch(domain: targetDomain)
    }

    private func loadOrFetch(domain: String) -> NSImage? {
        if let cached = images[domain] {
            return cached
        }
        if failedDomains.contains(domain) || inFlight.contains(domain) {
            return nil
        }

        // Fast disk cache hit
        let diskURL = cacheDirectory.appendingPathComponent("\(domain).png")
        if let diskImage = NSImage(contentsOf: diskURL), diskImage.size.width >= 16 {
            images[domain] = diskImage
            return diskImage
        }

        inFlight.insert(domain)
        let cacheDir = cacheDirectory
        Task.detached(priority: .utility) {
            let fetched = await Self.fetchBrandIcon(for: domain)
            if let fetched, let tiff = fetched.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let pngData = rep.representation(using: .png, properties: [:]) {
                let target = cacheDir.appendingPathComponent("\(domain).png")
                try? pngData.write(to: target, options: .atomic)
            }
            await MainActor.run {
                let loader = SenderAvatarLoader.shared
                loader.inFlight.remove(domain)
                if let fetched {
                    loader.images[domain] = fetched
                } else {
                    loader.failedDomains.insert(domain)
                }
            }
        }
        return nil
    }

    private static func fetchBrandIcon(for domain: String) async -> NSImage? {
        let encoded = domain.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? domain
        let candidates = [
            "https://www.google.com/s2/favicons?domain=\(encoded)&sz=128",
            "https://icons.duckduckgo.com/ip3/\(encoded).ico",
            "https://\(domain)/favicon.ico"
        ]

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 6
        sessionConfig.timeoutIntervalForResource = 8
        let session = URLSession(configuration: sessionConfig)
        defer { session.finishTasksAndInvalidate() }

        for urlString in candidates {
            guard let url = URL(string: urlString) else { continue }
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      data.count > 120,
                      let img = NSImage(data: data),
                      img.size.width >= 16,
                      img.size.height >= 16 else {
                    continue
                }
                return img
            } catch {
                continue
            }
        }
        return nil
    }
}
