import SwiftUI

/// Outline strokes for the top and left-side views, in model units. Each stroke
/// is a flat `[x0, y0, x1, y1, ...]` polyline. Generated from the bundled 3D mesh
/// (silhouette and crease edges, hidden lines removed, twins dropped, smoothed),
/// "Mouse - Razer DeathAdder" by gimora (Sketchfab), CC BY-NC-SA 4.0: personal use only.
struct MouseLineArt {
    var top: [[Double]] = []
    var side: [[Double]] = []

    static let bundled = MouseLineArt(url: Bundle.main.url(forResource: "MouseLineArt", withExtension: "json"))

    init(url: URL?) {
        guard let url, let data = try? Data(contentsOf: url),
              let views = try? JSONDecoder().decode([String: [[Double]]].self, from: data)
        else { return }
        top = views["top"] ?? []
        side = views["side"] ?? []
    }
}

/// A circled letter: the outline symbol (`a.circle`) at rest, the filled one
/// (`a.circle.fill`) when its button is the one being pointed at. The system
/// symbols are used because their glyph is centred by design; text laid out in
/// a circle sits off-centre by however much the font's ascent and descent differ.
struct LetterBadge: View {
    /// Nil draws a plain circle, for a button the guide has no letter for.
    let letter: String?
    var isFilled = false

    var body: some View {
        let name = letter.map { "\($0.lowercased()).circle" } ?? "circle"
        if isFilled {
            Image(systemName: name + ".fill")
                .resizable()
                .scaledToFit()
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.black, Color.adder)
        } else {
            Image(systemName: name)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.adder)
        }
    }
}

/// Line drawing of the mouse from above and from the left, in the style of
/// Razer's guide and with the same letters: A DPI up, B DPI down, C left,
/// D right, E scroll wheel, G mouse button 5, H mouse button 4. The guide's F
/// is the status light; it is drawn but gets no badge, because it is not a button.
struct MouseDiagram: View {
    /// Letter of the badge to emphasize, if any.
    let highlighted: String?
    var art = MouseLineArt.bundled

    // Model units. The mouse is about 0.56 wide and 0.96 long; x grows right,
    // y grows toward the rear of the mouse. The side view has its own x origin.
    private static let sideOrigin: CGFloat = 0.40
    private static let bounds = CGRect(x: -0.41, y: -0.49, width: 1.19, height: 1.04)
    private static let badgeRadius: CGFloat = 0.042

    private struct Badge {
        let letter: String
        let center: CGPoint
    }

    private static let badges = [
        Badge(letter: "A", center: CGPoint(x: -0.335, y: -0.335)),
        Badge(letter: "B", center: CGPoint(x: -0.320, y: -0.232)),
        Badge(letter: "C", center: CGPoint(x: -0.145, y: -0.325)),
        Badge(letter: "D", center: CGPoint(x: 0.135, y: -0.325)),
        Badge(letter: "E", center: CGPoint(x: -0.004, y: -0.270)),
        Badge(letter: "G", center: CGPoint(x: sideOrigin + 0.150, y: -0.105)),
        Badge(letter: "H", center: CGPoint(x: sideOrigin + 0.165, y: 0.050)),
    ]

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / Self.bounds.width, size.height / Self.bounds.height)
            let offset = CGPoint(
                x: (size.width - Self.bounds.width * scale) / 2 - Self.bounds.minX * scale,
                y: (size.height - Self.bounds.height * scale) / 2 - Self.bounds.minY * scale
            )
            // Text is drawn in screen space: a font sized in model units and then
            // scaled up by the context comes out garbled.
            let screen = context
            func onScreen(_ point: CGPoint) -> CGPoint {
                CGPoint(x: offset.x + point.x * scale, y: offset.y + point.y * scale)
            }

            context.translateBy(x: offset.x, y: offset.y)
            context.scaleBy(x: scale, y: scale)
            let line = StrokeStyle(lineWidth: 1.3 / scale, lineCap: .round, lineJoin: .round)
            context.stroke(path(art.top, originX: 0), with: .color(.primary), style: line)
            context.stroke(path(art.side, originX: Self.sideOrigin), with: .color(.primary), style: line)
            context.stroke(Self.details, with: .color(.primary), style: line)

            for badge in Self.badges {
                let isOn = highlighted == badge.letter
                let radius = Self.badgeRadius * (isOn ? 1.3 : 1)
                let center = badge.center
                if isOn {
                    context.fill(Self.circle(center, radius * 1.45), with: .color(.adder.opacity(0.3)))
                }
                if let symbol = context.resolveSymbol(id: isOn ? badge.letter + ".fill" : badge.letter) {
                    let middle = onScreen(center)
                    let side = radius * scale * 2
                    screen.draw(symbol, in: CGRect(x: middle.x - side / 2, y: middle.y - side / 2, width: side, height: side))
                }
            }
        } symbols: {
            ForEach(Self.badges, id: \.letter) { badge in
                // The outline badge gets a backing disc, or the drawing's own
                // lines would run straight through its letter.
                LetterBadge(letter: badge.letter)
                    .background(.background.opacity(0.9), in: .circle)
                    .frame(width: 64, height: 64)
                    .tag(badge.letter)
                LetterBadge(letter: badge.letter, isFilled: true)
                    .frame(width: 64, height: 64)
                    .tag(badge.letter + ".fill")
            }
        }
        .aspectRatio(Self.bounds.width / Self.bounds.height, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private static func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private func path(_ strokes: [[Double]], originX: CGFloat) -> Path {
        var path = Path()
        for stroke in strokes where stroke.count >= 4 {
            path.move(to: CGPoint(x: originX + stroke[0], y: stroke[1]))
            for index in stride(from: 2, to: stroke.count - 1, by: 2) {
                path.addLine(to: CGPoint(x: originX + stroke[index], y: stroke[index + 1]))
            }
        }
        return path
    }

    /// Features that exist only in the model's textures, not its geometry, so
    /// they are drawn by hand: wheel ridges, the status light, and the seams
    /// that split paired buttons.
    private static let details: Path = {
        var path = Path()
        func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
            path.move(to: CGPoint(x: x1, y: y1))
            path.addLine(to: CGPoint(x: x2, y: y2))
        }

        // Top view: wheel ridges, the seam between the two DPI buttons, the status light.
        for y in stride(from: -0.312, through: -0.228, by: 0.0168) { line(-0.030, y, 0.024, y) }
        line(-0.259, -0.274, -0.222, -0.300)
        path.addEllipse(in: CGRect(x: -0.014, y: -0.139, width: 0.016, height: 0.016))

        // Side view: seam between mouse button 5 (front) and mouse button 4 (rear).
        line(sideOrigin + 0.136, -0.036, sideOrigin + 0.216, -0.030)
        return path
    }()
}
