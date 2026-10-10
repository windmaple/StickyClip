import SwiftUI
import AppKit

/// State for the sticky-note board (search, selection) and the actions it can trigger.
@MainActor
final class NotesViewModel: ObservableObject {
    @Published var query: String = "" {
        didSet { if query != oldValue { selectedIndex = 0 } }
    }
    @Published var selectedIndex: Int = 0 {
        didSet { revealSelection() }
    }
    /// Changes every time the panel is shown, so the view can reset focus/scroll.
    @Published private(set) var sessionID = UUID()
    /// Clothesline or board — set by the panel controller each time it shows.
    @Published var presentation: Presentation = .board
    /// How far the notes have slid along the clothesline.
    @Published var lineOffset: CGFloat = 0

    /// Notes per row (↑/↓ jump by this much). 1 on the clothesline.
    var columns = 4
    /// Visible width of the clothesline's note area (set by the controller).
    var lineAreaWidth: CGFloat = 1000
    private let store = ClipboardStore.shared

    var onChoose: ((ClipItem, _ paste: Bool) -> Void)?
    var onOpenAccessibility: (() -> Void)?
    var onDismiss: (() -> Void)?

    var visibleItems: [ClipItem] {
        let all = store.orderedItems
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all }
        return all.filter { $0.searchableText.localizedCaseInsensitiveContains(q) }
    }

    var selectedItem: ClipItem? {
        let items = visibleItems
        return items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    func prepareForShow() {
        query = ""
        lineOffset = 0
        selectedIndex = 0
        sessionID = UUID()
    }

    // MARK: Clothesline scrolling

    private var maxLineOffset: CGFloat {
        let count = CGFloat(max(visibleItems.count, 1))
        return max(0, (count - 1) * ClotheslineMetrics.spacing + NoteMetrics.width - lineAreaWidth)
    }

    func scrollLine(by delta: CGFloat) {
        lineOffset = min(max(0, lineOffset + delta), maxLineOffset)
    }

    /// Slide the line so the selected note is fully visible.
    private func revealSelection() {
        guard presentation == .clothesline else { return }
        let start = CGFloat(selectedIndex) * ClotheslineMetrics.spacing
        if start < lineOffset {
            lineOffset = start
        } else if start + NoteMetrics.width > lineOffset + lineAreaWidth {
            lineOffset = start + NoteMetrics.width - lineAreaWidth
        }
    }

    /// Right-click menu for a note.
    func contextMenu(for item: ClipItem, at index: Int) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Paste") { [weak self] in self?.choose(at: index, paste: true) })
        menu.addItem(ClosureMenuItem("Copy to Clipboard") { [weak self] in self?.choose(at: index, paste: false) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(item.isPinned ? "Unpin" : "Pin") { [weak self] in self?.togglePin(item) })
        menu.addItem(ClosureMenuItem("Delete") { [weak self] in self?.delete(item) })
        return menu
    }

    func move(by delta: Int) {
        let count = visibleItems.count
        guard count > 0 else { return }
        selectedIndex = min(max(0, selectedIndex + delta), count - 1)
    }

    func choose(at index: Int, paste: Bool = true) {
        let items = visibleItems
        guard items.indices.contains(index) else { return }
        onChoose?(items[index], paste)
    }

    func deleteSelected() {
        guard let item = selectedItem else { return }
        store.remove(id: item.id)
        clampSelection()
    }

    func delete(_ item: ClipItem) {
        store.remove(id: item.id)
        clampSelection()
    }

    func togglePinSelected() {
        guard let item = selectedItem else { return }
        togglePin(item)
    }

    func togglePin(_ item: ClipItem) {
        store.togglePin(id: item.id)
        // Keep the same note selected after it jumps between the pinned / unpinned sections.
        if let idx = visibleItems.firstIndex(where: { $0.id == item.id }) {
            selectedIndex = idx
        }
    }

    private func clampSelection() {
        selectedIndex = min(selectedIndex, max(0, visibleItems.count - 1))
    }
}

/// Live, always-active blur behind the board (the app is never "active", so force `.active`).
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

enum BoardMetrics {
    static let spacing: CGFloat = 20
    static let horizontalPadding: CGFloat = 26
    /// Thickness of the wooden / aluminium frame around the board surface.
    static let frame: CGFloat = 14
    static let ledgeHeight: CGFloat = 40
    static let headerHeight: CGFloat = 50
    static let width: CGFloat =
        NoteMetrics.width * 4 + spacing * 3 + horizontalPadding * 2 + frame * 2
    static let height: CGFloat = 500
    static let cornerRadius: CGFloat = 14
}

/// A wobbly marker/chalk underline drawn under the search field.
struct HandDrawnUnderline: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY + 1))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.midY - 1),
                   control1: CGPoint(x: r.width * 0.3, y: r.minY),
                   control2: CGPoint(x: r.width * 0.7, y: r.maxY))
        return p
    }
}

/// The board of sticky notes shown when ⇧⌘V is pressed.
struct NotesBoardView: View {
    @ObservedObject var model: NotesViewModel
    @ObservedObject var store = ClipboardStore.shared
    @FocusState private var searchFocused: Bool
    @AppStorage("autoPaste") private var autoPaste = true
    @AppStorage(BoardTheme.defaultsKey) private var themeRaw = BoardTheme.whiteboard.rawValue
    @State private var hoveredID: UUID?

    private var theme: BoardTheme { BoardTheme(rawValue: themeRaw) ?? .whiteboard }

    var body: some View {
        let items = model.visibleItems

        Group {
            if theme == .glass {
                glassLayout(items)
            } else {
                boardLayout(items)
            }
        }
        .frame(width: BoardMetrics.width, height: BoardMetrics.height)
        .environment(\.noteAttachment, theme.attachment)
        .onAppear { searchFocused = true }
        .onChange(of: model.sessionID) { _, _ in searchFocused = true }
    }

    // MARK: - Layouts

    /// Framed board: surface (whiteboard / cork / chalk) inside a frame, with a tray along the bottom.
    private func boardLayout(_ items: [ClipItem]) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header(count: items.count)
                content(items)
            }
            .background(BoardSurface(theme: theme).equatable())
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay( // recessed edge where the surface meets the frame
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.black.opacity(0.35), lineWidth: 2)
                    .blur(radius: 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            )
            .environment(\.colorScheme, theme.surfaceScheme ?? .light)
            .padding(.horizontal, BoardMetrics.frame)
            .padding(.top, BoardMetrics.frame)

            footer
                .frame(height: BoardMetrics.ledgeHeight)
                .background(LedgeView(theme: theme))
                .environment(\.colorScheme, theme.ledgeScheme)
        }
        .background(BoardFrame(theme: theme).equatable())
        .clipShape(RoundedRectangle(cornerRadius: BoardMetrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BoardMetrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
        )
    }

    /// The original frosted-glass panel.
    private func glassLayout(_ items: [ClipItem]) -> some View {
        VStack(spacing: 0) {
            header(count: items.count)
            Divider().opacity(0.4)
            content(items)
            Divider().opacity(0.4)
            footer
                .frame(height: 34)
        }
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func content(_ items: [ClipItem]) -> some View {
        if items.isEmpty {
            emptyState
        } else {
            grid(items)
        }
    }

    // MARK: - Header

    private func header(count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.ink.opacity(0.65))
            TextField("", text: $model.query,
                      prompt: Text("Search clipboard…").foregroundStyle(theme.ink.opacity(0.45)))
                .textFieldStyle(.plain)
                .font(theme.font(theme == .glass ? 15 : 18))
                .foregroundStyle(theme.ink)
                .focused($searchFocused)
                .frame(maxWidth: 340)
                .overlay(alignment: .bottom) {
                    if theme != .glass {
                        HandDrawnUnderline()
                            .stroke(theme.ink.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .frame(height: 5)
                            .offset(y: 7)
                    }
                }
            Spacer()
            Text("\(count) note\(count == 1 ? "" : "s")")
                .font(theme == .glass ? .system(size: 11, weight: .medium) : theme.font(14))
                .foregroundStyle(theme.ink.opacity(0.65))
            if theme == .glass {
                Image(systemName: "note.text").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, theme == .cork ? 14 : 18)
        .padding(.vertical, theme == .cork ? 6 : 0)
        .background {
            if theme == .cork { // a paper label pinned to the cork
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(red: 0.99, green: 0.97, blue: 0.90))
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 2)
                    .rotationEffect(.degrees(-0.4))
            }
        }
        .padding(.horizontal, theme == .cork ? 16 : 0)
        .padding(.top, theme == .cork ? 8 : 0)
        .frame(height: BoardMetrics.headerHeight)
    }

    // MARK: - Grid

    private func grid(_ items: [ClipItem]) -> some View {
        let columns = Array(
            repeating: GridItem(.fixed(NoteMetrics.width), spacing: BoardMetrics.spacing),
            count: model.columns
        )

        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: BoardMetrics.spacing + 4) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        StickyNoteView(item: item, index: index,
                                       isSelected: index == model.selectedIndex,
                                       isHovering: hoveredID == item.id)
                            .environment(\.colorScheme, .light) // notes are always paper
                            .overlay(
                                NoteInteractionOverlay(
                                    item: item,
                                    index: index,
                                    onClick: {
                                        model.selectedIndex = index
                                        model.choose(at: index)
                                    },
                                    onHover: { hovering in
                                        if hovering { hoveredID = item.id }
                                        else if hoveredID == item.id { hoveredID = nil }
                                    },
                                    menuProvider: { model.contextMenu(for: item, at: index) }
                                )
                            )
                            .id(item.id)
                    }
                }
                .padding(.horizontal, BoardMetrics.horizontalPadding)
                .padding(.top, 14)
                .padding(.bottom, 22)
            }
            .id(model.sessionID) // fresh scroll position every time the board opens
            .onChange(of: model.selectedIndex) { _, newValue in
                guard items.indices.contains(newValue) else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(items[newValue].id)
                }
            }
            .onChange(of: model.sessionID) { _, _ in hoveredID = nil }
        }
    }

    // MARK: - Empty / footer

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: model.query.isEmpty ? "note.text" : "magnifyingglass")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(theme.ink.opacity(0.5))
            Text(model.query.isEmpty ? "Nothing copied yet" : "No notes match “\(model.query)”")
                .font(theme == .glass ? .system(size: 14, weight: .medium) : theme.font(20))
                .foregroundStyle(theme.ink.opacity(0.7))
            if model.query.isEmpty {
                Text("Copy something with ⌘C and it will show up here as a sticky note.")
                    .font(theme == .glass ? .system(size: 12) : theme.font(14))
                    .foregroundStyle(theme.ink.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        let needsAccess = autoPaste && !PasteService.isTrusted

        return HStack(spacing: 14) {
            if needsAccess {
                Button {
                    model.onOpenAccessibility?()
                } label: {
                    Label("Grant Accessibility to auto-paste", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            } else if theme == .glass {
                hint("↩", autoPaste ? "Paste" : "Copy")
                hint("⇧↩", "Copy only")
            } else {
                LedgeDecor(theme: theme)
            }
            Spacer()
            if theme != .glass && !needsAccess {
                hint("↩", autoPaste ? "Paste" : "Copy")
            }
            hint("Drag", "Drop into any app")
            if !needsAccess {
                hint("⌘1–9", "Quick pick")
                hint("⌘P", "Pin")
                hint("⌘⌫", "Delete")
            }
            hint("esc", "Close")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 18)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.12)))
            Text(label)
                .foregroundStyle(.secondary)
        }
    }
}
