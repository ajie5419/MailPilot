import AppKit
import Foundation
#if canImport(MailPilotCore)
import MailPilotCore
#endif

/// Asynchronously fetches and caches sender brand favicons (memory + disk) with multi-source fallback.
@MainActor
final class SenderAvatarLoader: ObservableObject {
    static let shared = SenderAvatarLoader()
    private static let onlineAvatarsEnabledKey = "MailPilot.AllowOnlineBrandAvatars.v1"

    /// Privacy default: `false` so sender domains are never sent to external favicon services unless explicitly enabled.
    @Published var allowOnlineBrandAvatars: Bool {
        didSet {
            UserDefaults.standard.set(allowOnlineBrandAvatars, forKey: Self.onlineAvatarsEnabledKey)
            if !allowOnlineBrandAvatars {
                failedDomains.removeAll()
            }
            objectWillChange.send()
        }
    }
    @Published private(set) var images: [String: NSImage] = [:]
    private var customImages: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private var pendingImages: [String: NSImage] = [:]
    private var pendingFailed: [String] = []
    private var flushTask: Task<Void, Never>?

    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    func customIcon(at path: String?) -> NSImage? {
        guard let path, !path.isEmpty else { return nil }
        if let cached = customImages[path] {
            return cached
        }
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        if customImages.count >= 50 {
            customImages.removeAll(keepingCapacity: true)
        }
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
        self.allowOnlineBrandAvatars = UserDefaults.standard.bool(forKey: Self.onlineAvatarsEnabledKey)
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
        guard allowOnlineBrandAvatars else {
            return nil
        }
        if let cached = images[domain] {
            return cached
        }
        if failedDomains.contains(domain) || inFlight.contains(domain) {
            return nil
        }

        inFlight.insert(domain)
        let cacheDir = cacheDirectory
        let diskURL = cacheDir.appendingPathComponent("\(domain).png")
        Task.detached(priority: .utility) {
            // Fast disk cache hit off the main thread; validate dimensions locally so corrupt/tiny files fall back to network.
            if let diskData = try? Data(contentsOf: diskURL),
               diskData.count > 120,
               let probe = NSImage(data: diskData),
               probe.size.width >= 16,
               probe.size.height >= 16 {
                await MainActor.run {
                    SenderAvatarLoader.shared.enqueueLoaded(domain: domain, image: NSImage(data: diskData))
                }
                return
            }

            let fetchedPNG = await Self.fetchBrandIconPNGData(for: domain)
            if let fetchedPNG {
                try? fetchedPNG.write(to: diskURL, options: .atomic)
            }
            await MainActor.run {
                let image = fetchedPNG.flatMap { NSImage(data: $0) }
                SenderAvatarLoader.shared.enqueueLoaded(domain: domain, image: image)
            }
        }
        return nil
    }

    private func enqueueLoaded(domain: String, image: NSImage?) {
        inFlight.remove(domain)
        if let image {
            pendingImages[domain] = image
        } else {
            pendingFailed.append(domain)
        }
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self else { return }
            self.flushTask = nil
            if !self.pendingFailed.isEmpty {
                for d in self.pendingFailed {
                    self.failedDomains.insert(d)
                }
                self.pendingFailed.removeAll(keepingCapacity: true)
            }
            guard !self.pendingImages.isEmpty else { return }
            if self.images.count + self.pendingImages.count > 200 {
                self.images.removeAll(keepingCapacity: true)
            }
            for (d, img) in self.pendingImages {
                self.images[d] = img
            }
            self.pendingImages.removeAll(keepingCapacity: true)
        }
    }

    private static func fetchBrandIconPNGData(for domain: String) async -> Data? {
        let encoded = domain.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? domain
        let candidates = [
            "https://www.google.com/s2/favicons?domain=\(encoded)&sz=128",
            "https://icons.duckduckgo.com/ip3/\(encoded).ico",
            "https://\(domain)/favicon.ico"
        ]

        let session = sharedSession
        for urlString in candidates {
            guard let url = URL(string: urlString) else { continue }
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      data.count > 120,
                      let img = NSImage(data: data),
                      img.size.width >= 16,
                      img.size.height >= 16,
                      let tiff = img.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let pngData = rep.representation(using: .png, properties: [:]) else {
                    continue
                }
                return pngData
            } catch {
                continue
            }
        }
        return nil
    }
}
