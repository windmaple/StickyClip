import Cocoa
import CryptoKit

/// Raw content captured from the pasteboard, before it becomes a `ClipItem`.
enum CapturedContent {
    case text(String)
    case image(Data, NSSize) // PNG data
    case files([URL])
}

/// Owns the clipboard history: adding, de-duplicating, pinning, persisting.
@MainActor
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    @Published private(set) var items: [ClipItem] = []

    /// Maximum number of unpinned items kept in history.
    var maxItems: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: "maxItems")
            return v > 0 ? v : 50
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "maxItems")
            trim()
            scheduleSave()
        }
    }

    /// Pinned notes first, then most recent first.
    var orderedItems: [ClipItem] {
        items.filter { $0.isPinned } + items.filter { !$0.isPinned }
    }

    private var nextColorIndex: Int {
        get { UserDefaults.standard.integer(forKey: "nextColorIndex") }
        set { UserDefaults.standard.set(newValue, forKey: "nextColorIndex") }
    }

    private let fm = FileManager.default
    private var saveWorkItem: DispatchWorkItem?
    private let imageCache = NSCache<NSString, NSImage>()

    private lazy var supportDir: URL = {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("StickyClip", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private lazy var imagesDir: URL = {
        let dir = supportDir.appendingPathComponent("images", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var historyURL: URL { supportDir.appendingPathComponent("history.json") }

    private init() {
        load()
    }

    // MARK: - Mutations

    func add(_ content: CapturedContent, sourceApp: NSRunningApplication?) {
        let hash = Self.hash(for: content)

        // Same content copied again → bump it to the top instead of duplicating.
        if let idx = items.firstIndex(where: { $0.contentHash == hash }) {
            var existing = items.remove(at: idx)
            existing.date = Date()
            existing.sourceAppBundleID = sourceApp?.bundleIdentifier ?? existing.sourceAppBundleID
            existing.sourceAppName = sourceApp?.localizedName ?? existing.sourceAppName
            items.insert(existing, at: 0)
            scheduleSave()
            return
        }

        let id = UUID()
        var item = ClipItem(
            id: id,
            kind: .text,
            text: nil,
            filePaths: nil,
            imageFileName: nil,
            imageWidth: nil,
            imageHeight: nil,
            sourceAppBundleID: sourceApp?.bundleIdentifier,
            sourceAppName: sourceApp?.localizedName,
            date: Date(),
            colorIndex: nextColorIndex,
            isPinned: false,
            contentHash: hash
        )
        nextColorIndex += 1

        switch content {
        case .text(let string):
            item.text = string
            item.kind = Self.looksLikeLink(string) ? .link : .text
        case .image(let data, let size):
            let name = "\(id.uuidString).png"
            do {
                try data.write(to: imagesDir.appendingPathComponent(name), options: .atomic)
            } catch {
                NSLog("StickyClip: failed to save image: \(error)")
                return
            }
            item.kind = .image
            item.imageFileName = name
            item.imageWidth = Double(size.width)
            item.imageHeight = Double(size.height)
        case .files(let urls):
            item.kind = .file
            item.filePaths = urls.map { $0.path }
        }

        items.insert(item, at: 0)
        trim()
        scheduleSave()
    }

    func remove(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        deleteAssets(of: items[idx])
        items.remove(at: idx)
        scheduleSave()
    }

    func togglePin(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].isPinned.toggle()
        scheduleSave()
    }

    /// Moves an item to the top of the (unpinned) history, e.g. after it was pasted.
    func bump(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: idx)
        item.date = Date()
        items.insert(item, at: 0)
        scheduleSave()
    }

    /// Removes every unpinned item.
    func clearUnpinned() {
        for item in items where !item.isPinned { deleteAssets(of: item) }
        items.removeAll { !$0.isPinned }
        scheduleSave()
    }

    // MARK: - Pasteboard output

    /// Writes the item back onto the general pasteboard.
    func writeToPasteboard(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text, .link:
            pb.setString(item.text ?? "", forType: .string)
        case .image:
            if let url = imageURL(for: item), let data = try? Data(contentsOf: url) {
                pb.setData(data, forType: .png)
                if let image = NSImage(data: data), let tiff = image.tiffRepresentation {
                    pb.setData(tiff, forType: .tiff)
                }
            }
        case .file:
            pb.writeObjects(item.fileURLs as [NSURL])
        }
    }

    // MARK: - Images

    func imageURL(for item: ClipItem) -> URL? {
        guard let name = item.imageFileName else { return nil }
        return imagesDir.appendingPathComponent(name)
    }

    func image(for item: ClipItem) -> NSImage? {
        guard let name = item.imageFileName else { return nil }
        if let cached = imageCache.object(forKey: name as NSString) { return cached }
        guard let url = imageURL(for: item), let image = NSImage(contentsOf: url) else { return nil }
        imageCache.setObject(image, forKey: name as NSString)
        return image
    }

    // MARK: - Private

    private func trim() {
        var unpinnedCount = 0
        var keep: [ClipItem] = []
        for item in items {
            if item.isPinned {
                keep.append(item)
            } else if unpinnedCount < maxItems {
                keep.append(item)
                unpinnedCount += 1
            } else {
                deleteAssets(of: item)
            }
        }
        if keep.count != items.count { items = keep }
    }

    private func deleteAssets(of item: ClipItem) {
        if let url = imageURL(for: item) {
            try? fm.removeItem(at: url)
            imageCache.removeObject(forKey: (item.imageFileName ?? "") as NSString)
        }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            try data.write(to: historyURL, options: .atomic)
        } catch {
            NSLog("StickyClip: failed to save history: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: historyURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([ClipItem].self, from: data) {
            items = decoded
        }
    }

    private static func hash(for content: CapturedContent) -> String {
        let data: Data
        switch content {
        case .text(let s): data = Data(("t:" + s).utf8)
        case .image(let d, _): data = Data("i:".utf8) + d
        case .files(let urls): data = Data(("f:" + urls.map { $0.path }.joined(separator: "\n")).utf8)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func looksLikeLink(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: { $0.isWhitespace }), trimmed.count < 2048,
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "ftp", "mailto"].contains(scheme) && (url.host != nil || scheme == "mailto")
    }
}
