import Cocoa
import SwiftUI

/// The kind of content captured from the pasteboard.
enum ClipKind: String, Codable {
    case text
    case link
    case image
    case file

    var label: String {
        switch self {
        case .text: return "Text"
        case .link: return "Link"
        case .image: return "Image"
        case .file: return "File"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        }
    }
}

/// A single clipboard history entry.
struct ClipItem: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: ClipKind
    /// Plain text for `.text` / `.link`.
    var text: String?
    /// Absolute file paths for `.file`.
    var filePaths: [String]?
    /// File name (inside the images directory) for `.image`.
    var imageFileName: String?
    var imageWidth: Double?
    var imageHeight: Double?
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var date: Date
    var colorIndex: Int
    var isPinned: Bool
    /// Used for de-duplication (same content copied again just moves to the top).
    var contentHash: String

    var fileURLs: [URL] {
        (filePaths ?? []).map { URL(fileURLWithPath: $0) }
    }

    var headerLabel: String {
        if kind == .file {
            let count = filePaths?.count ?? 0
            return count > 1 ? "\(count) Files" : "File"
        }
        return kind.label
    }

    /// A short, single-line description used in the menu bar "Recent" list.
    var menuTitle: String {
        switch kind {
        case .text, .link:
            let flat = (text ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return flat.count > 48 ? String(flat.prefix(48)) + "…" : flat
        case .image:
            if let w = imageWidth, let h = imageHeight {
                return "Image \(Int(w))×\(Int(h))"
            }
            return "Image"
        case .file:
            let names = fileURLs.map { $0.lastPathComponent }
            return names.count > 1 ? "\(names[0]) +\(names.count - 1)" : (names.first ?? "File")
        }
    }

    /// Text used for search filtering.
    var searchableText: String {
        switch kind {
        case .text, .link: return text ?? ""
        case .file: return (filePaths ?? []).joined(separator: " ")
        case .image: return "image \(sourceAppName ?? "")"
        }
    }
}

/// Sticky-note palette.
enum NotePalette {
    static let colors: [Color] = [
        Color(red: 1.00, green: 0.91, blue: 0.47), // yellow
        Color(red: 1.00, green: 0.72, blue: 0.80), // pink
        Color(red: 0.66, green: 0.85, blue: 1.00), // blue
        Color(red: 0.73, green: 0.94, blue: 0.65), // green
        Color(red: 1.00, green: 0.79, blue: 0.55), // orange
        Color(red: 0.84, green: 0.74, blue: 1.00)  // purple
    ]

    static func color(for index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}
