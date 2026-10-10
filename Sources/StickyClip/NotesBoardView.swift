import SwiftUI
import AppKit

/// State for the sticky-note board (search, selection) and the actions it can trigger.
@MainActor
final class NotesViewModel: ObservableObject {
    @Published var query: String = "" {
        didSet { if query != oldValue { selectedIndex = 0 } }
    }
    @Published var selectedIndex: Int = 0
    /// Changes every time the panel is shown, so the view can reset focus/scroll.
    @Published private(set) var sessionID = UUID()

    let columns = 4
    private let store = ClipboardStore.shared

    var onChoose: ((ClipItem, _ paste: Bool) -> Void)?
    var onOpenAccessibility: (() -> Void)?

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
        selectedIndex = 0
        sessionID = UUID()
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
    static let width: CGFloat =
        NoteMetrics.width * 4 + spacing * 3 + horizontalPadding * 2
    static let height: CGFloat = 470
    static let cornerRadius: CGFloat = 18
}

/// The board of sticky notes shown when ⇧⌘V is pressed.
struct NotesBoardView: View {
    @ObservedObject var model: NotesViewModel
    @ObservedObject var store = ClipboardStore.shared
    @FocusState private var searchFocused: Bool
    @AppStorage("autoPaste") private var autoPaste = true

    var body: some View {
        let items = model.visibleItems

        VStack(spacing: 0) {
            header(count: items.count)
            Divider().opacity(0.4)
            if items.isEmpty {
                emptyState
            } else {
                grid(items)
            }
            Divider().opacity(0.4)
            footer
        }
        .frame(width: BoardMetrics.width, height: BoardMetrics.height)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: BoardMetrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BoardMetrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
        .onAppear { searchFocused = true }
        .onChange(of: model.sessionID) { _, _ in searchFocused = true }
    }

    // MARK: - Header

    private func header(count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search clipboard…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
            Spacer()
            Text("\(count) note\(count == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Image(systemName: "note.text")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
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
                        StickyNoteView(item: item, index: index, isSelected: index == model.selectedIndex)
                            .id(item.id)
                            .onTapGesture {
                                model.selectedIndex = index
                                model.choose(at: index)
                            }
                            .contextMenu { contextMenu(for: item, index: index) }
                    }
                }
                .padding(.horizontal, BoardMetrics.horizontalPadding)
                .padding(.vertical, 22)
            }
            .id(model.sessionID) // fresh scroll position every time the board opens
            .onChange(of: model.selectedIndex) { _, newValue in
                guard items.indices.contains(newValue) else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(items[newValue].id)
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for item: ClipItem, index: Int) -> some View {
        Button("Paste") { model.choose(at: index, paste: true) }
        Button("Copy to Clipboard") { model.choose(at: index, paste: false) }
        Divider()
        Button(item.isPinned ? "Unpin" : "Pin") { model.togglePin(item) }
        Button("Delete", role: .destructive) { model.delete(item) }
    }

    // MARK: - Empty / footer

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: model.query.isEmpty ? "note.text" : "magnifyingglass")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text(model.query.isEmpty ? "Nothing copied yet" : "No notes match “\(model.query)”")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            if model.query.isEmpty {
                Text("Copy something with ⌘C and it will show up here as a sticky note.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if autoPaste && !PasteService.isTrusted {
                Button {
                    model.onOpenAccessibility?()
                } label: {
                    Label("Copy-only — grant Accessibility to auto-paste", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            } else {
                hint("↩", autoPaste ? "Paste" : "Copy")
                hint("⇧↩", "Copy only")
            }
            Spacer()
            hint("←↑↓→", "Move")
            hint("⌘1–9", "Quick pick")
            hint("⌘P", "Pin")
            hint("⌘⌫", "Delete")
            hint("esc", "Close")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 18)
        .frame(height: 34)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.1)))
            Text(label)
                .foregroundStyle(.secondary)
        }
    }
}
