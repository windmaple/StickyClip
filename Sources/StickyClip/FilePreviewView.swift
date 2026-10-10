import SwiftUI
import AppKit
import QuickLookThumbnailing

/// Caches Quick Look content thumbnails for files (images, PDFs, videos, documents…).
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    /// Files Quick Look can't make a content thumbnail for (we fall back to the file icon).
    private var misses = Set<String>()

    private init() {
        cache.countLimit = 300
    }

    /// Key includes the modification date so an edited file gets a fresh thumbnail.
    private func key(for url: URL) -> String {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.path)#\(mtime)"
    }

    func cached(_ url: URL) -> NSImage? {
        cache.object(forKey: key(for: url) as NSString)
    }

    func thumbnail(for url: URL, size: CGSize) async -> NSImage? {
        let k = key(for: url)
        if let hit = cache.object(forKey: k as NSString) { return hit }
        if misses.contains(k) { return nil }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail // content only — not the generic file icon
        )
        do {
            let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            let image = rep.nsImage
            cache.setObject(image, forKey: k as NSString)
            return image
        } catch {
            misses.insert(k)
            return nil
        }
    }
}

/// An image with a white photo border and a soft shadow, so it pops on the coloured paper.
struct PhotoFrame: View {
    let image: NSImage
    /// true = crop to fill the given frame, false = fit inside it.
    var fill: Bool = false
    var border: CGFloat = 2.5

    var body: some View {
        if fill {
            Color.clear
                .overlay(
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                )
                .clipped()
                .padding(border)
                .background(Color.white)
                .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
        } else {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .scaledToFit()
                .padding(border)
                .background(Color.white)
                .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
        }
    }
}

/// Body of a "File" sticky note: real content thumbnails when available, file icon otherwise.
struct FilePreviewView: View {
    let urls: [URL]
    let ink: Color
    let softInk: Color

    @State private var thumbs: [URL: NSImage]

    private static let requestSize = CGSize(width: 300, height: 220)

    init(urls: [URL], ink: Color, softInk: Color) {
        self.urls = urls
        self.ink = ink
        self.softInk = softInk
        // Seed from cache synchronously so already-seen notes don't flicker.
        var seeded: [URL: NSImage] = [:]
        for url in urls.prefix(3) {
            if let img = ThumbnailCache.shared.cached(url) { seeded[url] = img }
        }
        _thumbs = State(initialValue: seeded)
    }

    var body: some View {
        Group {
            if urls.count == 1, let url = urls.first, let image = thumbs[url] {
                single(image: image, url: url)
            } else if urls.count > 1, !thumbs.isEmpty {
                fan
            } else {
                iconList
            }
        }
        .task(id: urls) {
            for url in urls.prefix(3) where thumbs[url] == nil {
                if let img = await ThumbnailCache.shared.thumbnail(for: url, size: Self.requestSize) {
                    thumbs[url] = img
                }
            }
        }
    }

    // One previewable file: just the picture (name is in the hover tooltip).
    private func single(image: NSImage, url: URL) -> some View {
        PhotoFrame(image: image, fill: false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Several files: a little fanned-out stack of up to 3 previews.
    private var fan: some View {
        let shown = Array(urls.prefix(3))
        let angles: [Double] = shown.count == 2 ? [-7, 7] : [-9, 0, 9]
        let offsets: [CGFloat] = shown.count == 2 ? [-24, 24] : [-40, 0, 40]

        return ZStack {
            ForEach(Array(shown.enumerated()), id: \.offset) { i, url in
                tile(for: url)
                    .frame(width: 68, height: 66)
                    .rotationEffect(.degrees(angles[i]))
                    .offset(x: offsets[i], y: i == 1 && shown.count == 3 ? -3 : 0)
                    .zIndex(i == 1 ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func tile(for url: URL) -> some View {
        if let img = thumbs[url] {
            PhotoFrame(image: img, fill: true, border: 2)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .scaledToFit()
                .padding(4)
                .background(Color.white.opacity(0.85))
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        }
    }

    // Non-previewable files (folders, archives, etc.): icon + names.
    private var iconList: some View {
        HStack(alignment: .top, spacing: 8) {
            if let first = urls.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: first.path))
                    .resizable()
                    .frame(width: 38, height: 38)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(urls.prefix(4).enumerated()), id: \.offset) { _, url in
                    Text(url.lastPathComponent)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if urls.count > 4 {
                    Text("+\(urls.count - 4) more")
                        .font(.system(size: 10))
                        .foregroundStyle(softInk)
                }
            }
        }
    }
}
