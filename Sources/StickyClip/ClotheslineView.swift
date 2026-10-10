import SwiftUI
import AppKit

/// How the picker is presented: notes hanging on a clothesline, or pinned to a board.
enum Presentation: String {
    case clothesline, board

    static let defaultsKey = "presentation"

    static var current: Presentation {
        Presentation(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .clothesline
    }
}

enum ClotheslineMetrics {
    /// Height of the strip under the menu bar (windows are pushed below this).
    static let height: CGFloat = 272
    static let ropeTop: CGFloat = 9
    static let spacing: CGFloat = 200
    /// Notes start to the right of the search tag.
    static let notesLeft: CGFloat = 178
    static let rightMargin: CGFloat = 26
    /// Distance from the rope down to the top edge of a hanging note.
    static let noteDrop: CGFloat = 12
}

// MARK: - Rope geometry

/// A sagging rope from one end of the menu bar to the other (parabola ≈ catenary for a shallow sag).
struct RopeGeometry {
    let x0: CGFloat
    let x1: CGFloat
    let top: CGFloat
    let sag: CGFloat

    init(width: CGFloat) {
        x0 = 10
        x1 = max(width - 10, 11)
        top = ClotheslineMetrics.ropeTop
        sag = min(64, width * 0.04)
    }

    private func u(_ x: CGFloat) -> CGFloat {
        max(-1, min(1, 2 * (x - x0) / (x1 - x0) - 1))
    }

    func y(at x: CGFloat) -> CGFloat {
        let v = u(x)
        return top + sag * (1 - v * v)
    }

    /// Slope of the rope at x, in degrees (positive = rope descending to the right).
    func angle(at x: CGFloat) -> Double {
        let slope = sag * (-2 * u(x)) * (2 / (x1 - x0))
        return Double(atan(slope)) * 180 / .pi
    }
}

struct RopeShape: Shape {
    let rope: RopeGeometry

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rope.x0, y: rope.y(at: rope.x0)))
        var x = rope.x0
        while x < rope.x1 {
            x = min(x + 6, rope.x1)
            p.addLine(to: CGPoint(x: x, y: rope.y(at: x)))
        }
        return p
    }
}

// MARK: - Props

/// Front view of a wooden clothespin with its metal spring.
struct ClothespinView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(colors: [Color(red: 0.93, green: 0.80, blue: 0.60),
                                              Color(red: 0.80, green: 0.64, blue: 0.42)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 14, height: 34)
            Rectangle() // seam between the two halves
                .fill(Color.black.opacity(0.22))
                .frame(width: 1, height: 34)
            Capsule() // spring
                .fill(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.55)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 18, height: 5)
                .offset(y: -2)
        }
        .shadow(color: .black.opacity(0.35), radius: 1.5, x: 1, y: 2)
    }
}

/// Little screw-eye hooks that hold the rope at each end of the menu bar.
private struct RopeHook: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(white: 0.55)).frame(width: 2.5, height: 4)
            Circle()
                .stroke(LinearGradient(colors: [Color(white: 0.9), Color(white: 0.45)],
                                       startPoint: .top, endPoint: .bottom), lineWidth: 2.5)
                .frame(width: 10, height: 10)
        }
        .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
    }
}

// MARK: - A note hanging on the line

struct HangingNote: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool
    let isHovering: Bool
    /// Tilt that follows the rope at this spot.
    let restAngle: Double
    let delay: Double

    /// Initial swing when the line drops in; springs back to 0.
    @State private var swing: Double
    /// Bumped on select / hover to give the note a little nudge.
    @State private var nudges = 0

    /// Pivot = where the clothespin grips the rope (just above the note's top edge).
    nonisolated private static let pivot = UnitPoint(x: 0.5, y: -ClotheslineMetrics.noteDrop / NoteMetrics.height)

    init(item: ClipItem, index: Int, isSelected: Bool, isHovering: Bool, restAngle: Double, delay: Double) {
        self.item = item
        self.index = index
        self.isSelected = isSelected
        self.isHovering = isHovering
        self.restAngle = restAngle
        self.delay = delay
        _swing = State(initialValue: (index.isMultiple(of: 2) ? 1 : -1) * Double(10 + index % 5))
    }

    var body: some View {
        StickyNoteView(item: item, index: index, isSelected: isSelected, isHovering: isHovering)
            .environment(\.noteAttachment, .clothespin)
            .environment(\.colorScheme, .light)
            .rotationEffect(.degrees(restAngle + swing), anchor: Self.pivot)
            .keyframeAnimator(initialValue: 0.0, trigger: nudges) { content, angle in
                content.rotationEffect(.degrees(angle), anchor: Self.pivot)
            } keyframes: { _ in
                KeyframeTrack {
                    SpringKeyframe(5, duration: 0.14)
                    SpringKeyframe(-2.5, duration: 0.22)
                    SpringKeyframe(1, duration: 0.2)
                    SpringKeyframe(0, duration: 0.3)
                }
            }
            .onAppear {
                withAnimation(.interpolatingSpring(stiffness: 38, damping: 3.4).delay(delay)) {
                    swing = 0
                }
            }
            .onChange(of: isSelected) { _, selected in if selected { nudges += 1 } }
            .onChange(of: isHovering) { _, hovering in if hovering { nudges += 1 } }
    }
}

// MARK: - The clothesline strip

struct ClotheslineView: View {
    @ObservedObject var model: NotesViewModel

    var body: some View {
        // Rebuilt for every ⇧⌘V so the drop-in / swing animations replay.
        ClotheslineScene(model: model)
            .id(model.sessionID)
    }
}

private struct ClotheslineScene: View {
    @ObservedObject var model: NotesViewModel
    @ObservedObject var store = ClipboardStore.shared
    @AppStorage("autoPaste") private var autoPaste = true
    @FocusState private var searchFocused: Bool
    @State private var dropped = false
    @State private var hoveredID: UUID?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let rope = RopeGeometry(width: w)
            let items = model.visibleItems

            ZStack(alignment: .topLeading) {
                // Soft shade so the notes read well over any wallpaper; click it to dismiss.
                LinearGradient(colors: [.black.opacity(0.42), .black.opacity(0.22), .black.opacity(0.0)],
                               startPoint: .top, endPoint: .bottom)
                    .contentShape(Rectangle())
                    .onTapGesture { model.onDismiss?() }
                    .opacity(dropped ? 1 : 0)

                ZStack(alignment: .topLeading) {
                    ropeLayer(rope, width: w)
                    notesLayer(items, rope: rope, width: w, height: h)
                    searchTag(count: items.count)
                        .position(x: 84, y: rope.y(at: 84) + ClotheslineMetrics.noteDrop + 34)
                    if items.isEmpty { emptyTag(rope: rope, width: w) }
                    hints
                        .padding(.trailing, 18)
                        .padding(.bottom, 8)
                        .frame(width: w, height: h, alignment: .bottomTrailing)
                }
                .offset(y: dropped ? 0 : -h) // the line drops in from the menu bar
            }
            .frame(width: w, height: h)
        }
        .onAppear {
            searchFocused = true
            withAnimation(.spring(response: 0.5, dampingFraction: 0.62)) { dropped = true }
        }
    }

    // MARK: Rope

    private func ropeLayer(_ rope: RopeGeometry, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RopeShape(rope: rope)
                .stroke(Color(red: 0.87, green: 0.79, blue: 0.62),
                        style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                .shadow(color: .black.opacity(0.45), radius: 2, y: 3)
            RopeShape(rope: rope) // twisted-strand texture
                .stroke(Color(red: 0.58, green: 0.47, blue: 0.31).opacity(0.85),
                        style: StrokeStyle(lineWidth: 4.5, lineCap: .butt, dash: [1.6, 3.2]))
            RopeHook().position(x: rope.x0, y: rope.top - 2)
            RopeHook().position(x: rope.x1, y: rope.top - 2)
        }
        .frame(width: width, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    // MARK: Notes

    private func notesLayer(_ items: [ClipItem], rope: RopeGeometry, width: CGFloat, height: CGFloat) -> some View {
        let spacing = ClotheslineMetrics.spacing
        let left = ClotheslineMetrics.notesLeft

        return ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let cx = left + CGFloat(index) * spacing - model.lineOffset + NoteMetrics.width / 2
                if cx > -NoteMetrics.width && cx < width + NoteMetrics.width {
                    HangingNote(item: item, index: index,
                                isSelected: index == model.selectedIndex,
                                isHovering: hoveredID == item.id,
                                restAngle: rope.angle(at: cx) * 0.6,
                                delay: Double(min(index, 10)) * 0.035)
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
                        .zIndex(index == model.selectedIndex ? 1 : 0)
                        .position(x: cx, y: rope.y(at: cx) + ClotheslineMetrics.noteDrop + NoteMetrics.height / 2)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: model.lineOffset)
        .mask( // notes slide out of view behind the search tag and off the right edge
            HStack(spacing: 0) {
                Color.clear.frame(width: left - 46)
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 34)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 20)
            }
        )
    }

    // MARK: Search tag / empty / hints

    private func searchTag(count: Int) -> some View {
        let ink = Color(red: 0.27, green: 0.19, blue: 0.10)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .bold))
                TextField("", text: $model.query,
                          prompt: Text("search…").foregroundStyle(ink.opacity(0.45)))
                    .textFieldStyle(.plain)
                    .font(.custom("Noteworthy-Bold", size: 15))
                    .focused($searchFocused)
            }
            Text("\(count) item\(count == 1 ? "" : "s")")
                .font(.custom("Noteworthy-Light", size: 12))
                .opacity(0.65)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 10)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .frame(width: 128, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(red: 0.97, green: 0.89, blue: 0.70))
                .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
        )
        .overlay(alignment: .top) { ClothespinView().offset(y: -22) }
        .environment(\.colorScheme, .light)
    }

    private func emptyTag(rope: RopeGeometry, width: CGFloat) -> some View {
        let x = width / 2
        return VStack(spacing: 4) {
            Text(model.query.isEmpty ? "Nothing copied yet" : "No matches")
                .font(.custom("Noteworthy-Bold", size: 18))
            Text(model.query.isEmpty ? "Copy something with ⌘C" : "Try another search")
                .font(.custom("Noteworthy-Light", size: 13))
                .opacity(0.7)
        }
        .foregroundStyle(Color(red: 0.27, green: 0.19, blue: 0.10))
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(red: 1.0, green: 0.94, blue: 0.62))
                .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
        )
        .overlay(alignment: .top) { ClothespinView().offset(y: -22) }
        .position(x: x, y: rope.y(at: x) + ClotheslineMetrics.noteDrop + 40)
    }

    private var hints: some View {
        HStack(spacing: 12) {
            if autoPaste && !PasteService.isTrusted {
                Button {
                    model.onOpenAccessibility?()
                } label: {
                    Label("Grant Accessibility to auto-paste & move windows",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            } else {
                chip("← →", "Browse")
                chip("↩", autoPaste ? "Paste" : "Copy")
                chip("Drag", "Drop into any window")
                chip("⌘P", "Pin")
                chip("⌘⌫", "Delete")
            }
            chip("esc", "Close")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.9))
        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
        .environment(\.colorScheme, .dark)
    }

    private func chip(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.2)))
            Text(label)
        }
    }
}

// MARK: - Root

/// Switches between the clothesline strip and the board, following the controller's chosen mode.
struct PanelRootView: View {
    @ObservedObject var model: NotesViewModel

    var body: some View {
        switch model.presentation {
        case .clothesline:
            ClotheslineView(model: model)
        case .board:
            NotesBoardView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
