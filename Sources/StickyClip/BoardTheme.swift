import SwiftUI

// MARK: - Theme

/// What holds a sticky note onto the board.
enum NoteAttachment {
    case tape, pin, magnet, clothespin
}

private struct NoteAttachmentKey: EnvironmentKey {
    static let defaultValue: NoteAttachment = .tape
}

extension EnvironmentValues {
    var noteAttachment: NoteAttachment {
        get { self[NoteAttachmentKey.self] }
        set { self[NoteAttachmentKey.self] = newValue }
    }
}

enum BoardTheme: String, CaseIterable, Identifiable {
    case whiteboard, cork, chalkboard, glass

    static let defaultsKey = "boardTheme"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .whiteboard: return "Whiteboard"
        case .cork: return "Cork Board"
        case .chalkboard: return "Chalkboard"
        case .glass: return "Frosted Glass"
        }
    }

    var attachment: NoteAttachment {
        switch self {
        case .whiteboard, .chalkboard: return .magnet
        case .cork: return .pin
        case .glass: return .tape
        }
    }

    /// Colour of "written" things on the board surface (search text, counts, empty state).
    var ink: Color {
        switch self {
        case .whiteboard: return Color(red: 0.12, green: 0.20, blue: 0.42)
        case .cork: return Color(red: 0.24, green: 0.15, blue: 0.08)
        case .chalkboard: return Color.white.opacity(0.88)
        case .glass: return Color.primary
        }
    }

    func font(_ size: CGFloat) -> Font {
        switch self {
        case .whiteboard: return .custom("Noteworthy-Bold", size: size)
        case .cork: return .custom("MarkerFelt-Wide", size: size)
        case .chalkboard: return .custom("Chalkduster", size: size - 1)
        case .glass: return .system(size: size)
        }
    }

    /// Light/dark appearance for system controls drawn on the surface.
    var surfaceScheme: ColorScheme? {
        switch self {
        case .whiteboard, .cork: return .light
        case .chalkboard: return .dark
        case .glass: return nil
        }
    }

    /// Light/dark appearance for the hints on the bottom ledge.
    var ledgeScheme: ColorScheme {
        self == .whiteboard ? .light : .dark
    }

    static var current: BoardTheme {
        BoardTheme(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .whiteboard
    }
}

// MARK: - Deterministic randomness (so textures don't shimmer between redraws)

struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 { // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private extension SeededRNG {
    mutating func cg(_ range: ClosedRange<CGFloat>) -> CGFloat { CGFloat.random(in: range, using: &self) }
}

/// A shaky, hand-drawn path through the given points.
private func handDrawn(_ points: [CGPoint], jitter: CGFloat, closed: Bool = false,
                       rng: inout SeededRNG) -> Path {
    var path = Path()
    guard !points.isEmpty else { return path }
    let shaken = points.map { CGPoint(x: $0.x + rng.cg(-jitter...jitter), y: $0.y + rng.cg(-jitter...jitter)) }
    path.move(to: shaken[0])
    for i in 1..<shaken.count {
        let p0 = shaken[i - 1], p1 = shaken[i]
        let mid = CGPoint(x: (p0.x + p1.x) / 2 + rng.cg(-jitter...jitter),
                          y: (p0.y + p1.y) / 2 + rng.cg(-jitter...jitter))
        path.addQuadCurve(to: p1, control: mid)
    }
    if closed { path.addQuadCurve(to: shaken[0], control: shaken[0]) }
    return path
}

private func starPoints(center c: CGPoint, outer: CGFloat, inner: CGFloat) -> [CGPoint] {
    (0...10).map { i in
        let r = i % 2 == 0 ? outer : inner
        let a = Double(i) * .pi / 5 - .pi / 2
        return CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
    }
}

private func arrow(from a: CGPoint, to b: CGPoint, bend: CGFloat, rng: inout SeededRNG) -> Path {
    var p = Path()
    let ctrl = CGPoint(x: (a.x + b.x) / 2 + bend, y: (a.y + b.y) / 2 - bend)
    p.move(to: a)
    p.addQuadCurve(to: b, control: ctrl)
    let angle = atan2(b.y - ctrl.y, b.x - ctrl.x)
    for side in [-1.0, 1.0] {
        let ha = angle + .pi + side * 0.5
        p.move(to: b)
        p.addLine(to: CGPoint(x: b.x + 13 * cos(ha) + rng.cg(-1...1), y: b.y + 13 * sin(ha) + rng.cg(-1...1)))
    }
    return p
}

// MARK: - Board surface

struct BoardSurface: View, Equatable {
    let theme: BoardTheme

    var body: some View {
        switch theme {
        case .whiteboard: whiteboard
        case .cork: cork
        case .chalkboard: chalkboard
        case .glass: Color.clear
        }
    }

    // Glossy off-white, faint ghosts of erased marker, a few doodles peeking between notes.
    private var whiteboard: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.995), Color(white: 0.935)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { ctx, size in
                var rng = SeededRNG(seed: 7)
                let w = size.width, h = size.height

                // Ghosts of erased writing.
                ctx.drawLayer { layer in
                    layer.addFilter(.blur(radius: 6))
                    for _ in 0..<7 {
                        let y = rng.cg(h * 0.15...h * 0.95)
                        let x = rng.cg(0...w * 0.7)
                        let pts = (0..<6).map { i in CGPoint(x: x + CGFloat(i) * rng.cg(25...55), y: y + rng.cg(-8...8)) }
                        layer.stroke(handDrawn(pts, jitter: 6, rng: &rng),
                                     with: .color(Color(white: 0.45).opacity(0.07)),
                                     style: StrokeStyle(lineWidth: rng.cg(8...16), lineCap: .round))
                    }
                }

                let marker = StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round)
                let blue = Color(red: 0.12, green: 0.32, blue: 0.78).opacity(0.55)
                let red = Color(red: 0.85, green: 0.18, blue: 0.16).opacity(0.5)
                let green = Color(red: 0.10, green: 0.55, blue: 0.30).opacity(0.5)

                ctx.stroke(handDrawn(starPoints(center: CGPoint(x: w * 0.93, y: h * 0.83), outer: 20, inner: 9),
                                     jitter: 1.5, rng: &rng), with: .color(blue), style: marker)
                ctx.stroke(arrow(from: CGPoint(x: w * 0.03, y: h * 0.965), to: CGPoint(x: w * 0.16, y: h * 0.95),
                                 bend: 18, rng: &rng), with: .color(red), style: marker)

                var c = ctx
                c.translateBy(x: w * 0.78, y: h * 0.93)
                c.rotate(by: .degrees(-7))
                c.draw(Text("ideas!").font(.custom("MarkerFelt-Wide", size: 22)).foregroundColor(green), at: .zero)
                c.stroke(handDrawn([CGPoint(x: -34, y: 14), CGPoint(x: 0, y: 17), CGPoint(x: 36, y: 13)],
                                   jitter: 1.5, rng: &rng), with: .color(green), style: marker)

                ctx.stroke(handDrawn([CGPoint(x: w * 0.42, y: h * 0.965), CGPoint(x: w * 0.46, y: h * 0.94),
                                      CGPoint(x: w * 0.50, y: h * 0.965), CGPoint(x: w * 0.54, y: h * 0.94),
                                      CGPoint(x: w * 0.58, y: h * 0.965)],
                                     jitter: 1, rng: &rng), with: .color(blue.opacity(0.7)), style: marker)
            }
            // Glare streak across the gloss.
            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)],
                           startPoint: .init(x: 0.15, y: 0), endPoint: .init(x: 0.45, y: 1))
                .blendMode(.screen)
                .opacity(0.6)
        }
    }

    // Speckled cork with a soft vignette and the odd old pin hole.
    private var cork: some View {
        ZStack {
            Color(red: 0.78, green: 0.60, blue: 0.41)
            Canvas { ctx, size in
                var rng = SeededRNG(seed: 11)
                let area = size.width * size.height
                let count = Int(area / 55)
                for _ in 0..<count {
                    let d = rng.cg(0.8...3.2)
                    let rect = CGRect(x: rng.cg(0...size.width), y: rng.cg(0...size.height),
                                      width: d, height: d * rng.cg(0.6...1.4))
                    let dark = rng.cg(0...1) < 0.6
                    let color = dark
                        ? Color(red: 0.45, green: 0.30, blue: 0.16).opacity(Double(rng.cg(0.25...0.6)))
                        : Color(red: 0.95, green: 0.82, blue: 0.62).opacity(Double(rng.cg(0.25...0.55)))
                    ctx.fill(Path(ellipseIn: rect), with: .color(color))
                }
                for _ in 0..<14 { // old pin holes
                    let p = CGPoint(x: rng.cg(0...size.width), y: rng.cg(0...size.height))
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x, y: p.y, width: 2.4, height: 2.4)),
                             with: .color(Color(red: 0.2, green: 0.12, blue: 0.05).opacity(0.7)))
                }
            }
            RadialGradient(colors: [.clear, Color(red: 0.3, green: 0.18, blue: 0.08).opacity(0.35)],
                           center: .center, startRadius: 200, endRadius: 560)
        }
    }

    // Deep green slate, chalk dust, eraser clouds and a few chalk doodles.
    private var chalkboard: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.17, green: 0.28, blue: 0.22),
                                    Color(red: 0.11, green: 0.19, blue: 0.15)],
                           startPoint: .top, endPoint: .bottom)
            Canvas { ctx, size in
                var rng = SeededRNG(seed: 23)
                let w = size.width, h = size.height

                ctx.drawLayer { layer in // eraser clouds
                    layer.addFilter(.blur(radius: 22))
                    for _ in 0..<9 {
                        let rect = CGRect(x: rng.cg(-40...w), y: rng.cg(-20...h),
                                          width: rng.cg(120...260), height: rng.cg(40...90))
                        layer.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.05)))
                    }
                }
                for _ in 0..<Int(w * h / 90) { // dust
                    let d = rng.cg(0.5...1.6)
                    ctx.fill(Path(ellipseIn: CGRect(x: rng.cg(0...w), y: rng.cg(0...h), width: d, height: d)),
                             with: .color(.white.opacity(Double(rng.cg(0.03...0.12)))))
                }

                let chalk = Color.white.opacity(0.42)
                let style = StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)
                var c = ctx
                c.translateBy(x: w * 0.80, y: h * 0.92)
                c.rotate(by: .degrees(-5))
                c.draw(Text("don't forget!").font(.custom("Chalkduster", size: 17)).foregroundColor(chalk), at: .zero)

                ctx.stroke(arrow(from: CGPoint(x: w * 0.03, y: h * 0.965), to: CGPoint(x: w * 0.16, y: h * 0.95),
                                 bend: 16, rng: &rng), with: .color(chalk), style: style)
                for i in 0..<4 { // tally marks
                    let x = w * 0.45 + CGFloat(i) * 9
                    ctx.stroke(handDrawn([CGPoint(x: x, y: h * 0.90), CGPoint(x: x + 2, y: h * 0.97)],
                                         jitter: 0.8, rng: &rng), with: .color(chalk), style: style)
                }
                ctx.stroke(handDrawn([CGPoint(x: w * 0.445, y: h * 0.96), CGPoint(x: w * 0.45 + 36, y: h * 0.91)],
                                     jitter: 0.8, rng: &rng), with: .color(chalk), style: style)
            }
        }
    }
}

// MARK: - Frame & ledge

struct BoardFrame: View, Equatable {
    let theme: BoardTheme

    var body: some View {
        switch theme {
        case .whiteboard:
            LinearGradient(colors: [Color(white: 0.90), Color(white: 0.70), Color(white: 0.84), Color(white: 0.62)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        case .cork:
            WoodGrain(base: [Color(red: 0.60, green: 0.40, blue: 0.22), Color(red: 0.43, green: 0.27, blue: 0.14)])
        case .chalkboard:
            WoodGrain(base: [Color(red: 0.47, green: 0.30, blue: 0.16), Color(red: 0.31, green: 0.19, blue: 0.09)])
        case .glass:
            Color.clear
        }
    }
}

private struct WoodGrain: View {
    let base: [Color]

    var body: some View {
        ZStack {
            LinearGradient(colors: base, startPoint: .top, endPoint: .bottom)
            Canvas { ctx, size in
                var rng = SeededRNG(seed: 99)
                for _ in 0..<70 {
                    let y = rng.cg(0...size.height)
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: y))
                    var x: CGFloat = 0
                    while x < size.width {
                        let nx = x + rng.cg(60...140)
                        p.addQuadCurve(to: CGPoint(x: nx, y: y + rng.cg(-2...2)),
                                       control: CGPoint(x: (x + nx) / 2, y: y + rng.cg(-3...3)))
                        x = nx
                    }
                    ctx.stroke(p, with: .color(Color.black.opacity(Double(rng.cg(0.05...0.16)))),
                               lineWidth: rng.cg(0.5...1.6))
                }
            }
        }
    }
}

/// The tray along the bottom of the board where the hints sit.
struct LedgeView: View {
    let theme: BoardTheme

    var body: some View {
        ZStack(alignment: .top) {
            switch theme {
            case .whiteboard:
                LinearGradient(colors: [Color(white: 0.93), Color(white: 0.74), Color(white: 0.64)],
                               startPoint: .top, endPoint: .bottom)
            case .cork, .chalkboard:
                LinearGradient(colors: [Color(red: 0.55, green: 0.36, blue: 0.19),
                                        Color(red: 0.36, green: 0.22, blue: 0.11)],
                               startPoint: .top, endPoint: .bottom)
            case .glass:
                Color.clear
            }
            // Lip of the tray: dark seam under the surface, then a highlight.
            VStack(spacing: 0) {
                Rectangle().fill(Color.black.opacity(0.35)).frame(height: 1)
                Rectangle().fill(Color.white.opacity(0.45)).frame(height: 1)
            }
        }
    }
}

/// Markers or chalk lying in the tray.
struct LedgeDecor: View {
    let theme: BoardTheme

    var body: some View {
        HStack(spacing: 6) {
            switch theme {
            case .whiteboard:
                marker(Color(red: 0.12, green: 0.32, blue: 0.78)).rotationEffect(.degrees(-2))
                marker(Color(red: 0.85, green: 0.18, blue: 0.16)).rotationEffect(.degrees(1.5))
                marker(Color(white: 0.12)).rotationEffect(.degrees(-1))
            case .chalkboard:
                chalk(.white, length: 30).rotationEffect(.degrees(-6))
                chalk(Color(red: 1, green: 0.93, blue: 0.6), length: 22).rotationEffect(.degrees(4))
                chalk(Color(red: 1, green: 0.75, blue: 0.82), length: 16).rotationEffect(.degrees(-3))
            case .cork:
                ForEach(0..<4, id: \.self) { i in
                    PushPinHead(color: NotePalette.pinColors[i], diameter: 11)
                }
            case .glass:
                EmptyView()
            }
        }
    }

    private func marker(_ color: Color) -> some View {
        HStack(spacing: 0) {
            Capsule().fill(color).frame(width: 14, height: 9)                 // cap
            Rectangle().fill(Color.white.opacity(0.95)).frame(width: 26, height: 8) // barrel
                .overlay(Rectangle().fill(color.opacity(0.85)).frame(width: 9, height: 8), alignment: .center)
            Capsule().fill(Color(white: 0.85)).frame(width: 8, height: 7)    // end
        }
        .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
    }

    private func chalk(_ color: Color, length: CGFloat) -> some View {
        Capsule()
            .fill(color.opacity(0.92))
            .frame(width: length, height: 7)
            .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
    }
}

// MARK: - Attachments (tape / pin / magnet)

extension NotePalette {
    static let pinColors: [Color] = [
        Color(red: 0.86, green: 0.16, blue: 0.16), // red
        Color(red: 0.13, green: 0.40, blue: 0.85), // blue
        Color(red: 0.12, green: 0.62, blue: 0.32), // green
        Color(red: 0.98, green: 0.72, blue: 0.10), // yellow
        Color(red: 0.55, green: 0.25, blue: 0.80)  // purple
    ]
}

struct PushPinHead: View {
    let color: Color
    var diameter: CGFloat = 14

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(0.75), color, color.opacity(0.85)],
                                 center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: diameter * 0.7))
            .overlay(
                Circle().fill(Color.white.opacity(0.75))
                    .frame(width: diameter * 0.28, height: diameter * 0.28)
                    .offset(x: -diameter * 0.17, y: -diameter * 0.17)
            )
            .frame(width: diameter, height: diameter)
            .shadow(color: .black.opacity(0.45), radius: 1.5, x: 2, y: 3)
    }
}

struct MagnetView: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [color.opacity(0.8), color], startPoint: .top, endPoint: .bottom))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1.2).padding(2))
            .overlay(
                Ellipse().fill(Color.white.opacity(0.5))
                    .frame(width: 7, height: 4)
                    .offset(y: -4)
            )
            .frame(width: 18, height: 18)
            .shadow(color: .black.opacity(0.4), radius: 2, y: 2)
    }
}
