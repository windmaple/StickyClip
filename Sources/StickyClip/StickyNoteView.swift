import SwiftUI
import AppKit

/// Paper shape with the bottom-right corner folded away.
struct FoldedNoteShape: Shape {
    var fold: CGFloat = 18

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - fold))
        p.addLine(to: CGPoint(x: r.maxX - fold, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// The little dog-ear triangle drawn in the folded corner.
struct FoldTriangle: Shape {
    var fold: CGFloat = 18

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.maxX - fold, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - fold, y: r.maxY - fold))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - fold))
        p.closeSubpath()
        return p
    }
}

enum NoteMetrics {
    static let width: CGFloat = 170
    static let height: CGFloat = 150
    static let fold: CGFloat = 18
}

/// Cache for source-app icons.
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}

/// One clipboard item rendered as a coloured sticky note.
struct StickyNoteView: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool
    var isHovering: Bool = false

    private var ink: Color { Color.black.opacity(0.78) }
    private var softInk: Color { Color.black.opacity(0.5) }

    /// Small, stable tilt per note so the board looks hand-placed.
    private var tilt: Double {
        Double(Int(item.id.uuid.0) % 7 - 3) * 0.7
    }

    var body: some View {
        let color = NotePalette.color(for: item.colorIndex)

        VStack(alignment: .leading, spacing: 6) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .padding(EdgeInsets(top: 14, leading: 12, bottom: 9, trailing: 14))
        .frame(width: NoteMetrics.width, height: NoteMetrics.height)
        .background(
            ZStack {
                FoldedNoteShape(fold: NoteMetrics.fold)
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.92), color],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                FoldTriangle(fold: NoteMetrics.fold)
                    .fill(Color.black.opacity(0.14))
            }
        )
        .overlay(
            FoldedNoteShape(fold: NoteMetrics.fold)
                .stroke(Color.accentColor, lineWidth: isSelected ? 3 : 0)
        )
        .overlay(alignment: .top) { attachmentView }
        .contentShape(FoldedNoteShape(fold: NoteMetrics.fold))
        .rotationEffect(.degrees(isSelected ? 0 : tilt))
        .scaleEffect(isSelected ? 1.07 : (isHovering ? 1.03 : 1.0))
        .shadow(color: .black.opacity(isSelected ? 0.35 : 0.22),
                radius: isSelected ? 12 : 5,
                x: 0, y: isSelected ? 7 : 3)
        .zIndex(isSelected ? 1 : 0)
        .animation(.spring(response: 0.25, dampingFraction: 0.72), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(item.menuTitle)
    }

    // MARK: - Pieces

    @Environment(\.noteAttachment) private var attachment

    @ViewBuilder
    private var attachmentView: some View {
        switch attachment {
        case .tape:
            Rectangle()
                .fill(Color.white.opacity(0.5))
                .frame(width: 52, height: 15)
                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                .rotationEffect(.degrees(-3))
                .offset(y: -7)
        case .pin:
            PushPinHead(color: NotePalette.pinColors[abs(item.colorIndex * 3 + 1) % NotePalette.pinColors.count])
                .offset(y: 1)
        case .magnet:
            MagnetView(color: NotePalette.pinColors[abs(item.colorIndex * 2 + 3) % NotePalette.pinColors.count])
                .offset(y: -5)
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: item.symbol)
                .font(.system(size: 10, weight: .bold))
            Text(item.headerLabel.uppercased())
                .font(.system(size: 9, weight: .heavy))
                .kerning(0.6)
            Spacer(minLength: 2)
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(30))
            }
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.black.opacity(0.1)))
            }
        }
        .foregroundStyle(softInk)
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            Text(String((item.text ?? "").prefix(500)))
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(ink)
                .lineLimit(6)
                .multilineTextAlignment(.leading)

        case .link:
            let raw = item.text ?? ""
            VStack(alignment: .leading, spacing: 3) {
                Text(URL(string: raw)?.host ?? raw)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                Text(raw)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.1, green: 0.25, blue: 0.6))
                    .underline()
                    .lineLimit(4)
            }

        case .image:
            if let image = ClipboardStore.shared.image(for: item) {
                PhotoFrame(image: image, fill: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Label("Image missing", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(softInk)
            }

        case .file:
            FilePreviewView(urls: item.fileURLs, ink: ink, softInk: softInk)
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if let icon = AppIconCache.icon(for: item.sourceAppBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 13, height: 13)
            }
            Text(Self.relativeTime(item.date))
            Spacer(minLength: 2)
            Text(detail)
                .lineLimit(1)
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(softInk)
        .padding(.trailing, NoteMetrics.fold - 8)
    }

    private var detail: String {
        switch item.kind {
        case .text:
            let n = item.text?.count ?? 0
            return "\(n) char\(n == 1 ? "" : "s")"
        case .link, .image, .file:
            return ""
        }
    }

    static func relativeTime(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86_400 { return "\(Int(s / 3600))h ago" }
        if s < 7 * 86_400 { return "\(Int(s / 86_400))d ago" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}
