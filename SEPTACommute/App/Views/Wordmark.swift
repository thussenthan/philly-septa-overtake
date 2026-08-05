import SwiftUI

/// What the app is called.
///
/// Kept in one place because the wordmark is *drawn*, not typeset — it works for
/// any word, so changing the name here changes it on the launch screen, the
/// onboarding screen and the title bar at once.
enum AppIdentity {
    static let name = "OVERTAKE"

    /// One line, for the onboarding screen.
    static let tagline = "Local now, or the express in four minutes?"
}

/// The app name drawn the way SEPTA draws its map: coloured lines, white stops.
///
/// Every letter is a set of polylines stroked in a line colour, with a white circle
/// at each junction and terminus — the same vocabulary as the network diagram, so
/// the name reads as a piece of the map rather than as text sitting on top of one.
/// Strokes are held to 0°, 45° and 90° wherever the letterform allows, which is the
/// rule that makes a transit diagram look like a transit diagram.
struct Wordmark: View {
    var text: String = AppIdentity.name
    /// Cap height. Everything else scales from this.
    var height: CGFloat = 28

    /// SEPTA's own line colours, cycled across the letters.
    private static let palette = ["F26100", "0097D6", "5A960A", "5F249F", "DC2E6B", "FFD700"]

    private var letters: [TransitLetter] {
        text.uppercased().compactMap(TransitLetter.init(character:))
    }

    private var advance: CGFloat { (TransitLetter.width + TransitLetter.gap) * height }

    var body: some View {
        Canvas { context, _ in
            for (index, letter) in letters.enumerated() {
                let origin = CGPoint(x: CGFloat(index) * advance + inset, y: inset)
                draw(letter, at: origin, index: index, in: &context)
            }
        }
        .frame(width: CGFloat(letters.count) * advance - TransitLetter.gap * height + inset * 2,
               height: height + inset * 2)
        .accessibilityLabel(text.capitalized)
    }

    /// Room for the stroke and the stop circles to sit inside the frame rather than
    /// being clipped by it.
    private var inset: CGFloat { height * 0.14 }

    private func draw(_ letter: TransitLetter, at origin: CGPoint, index: Int, in context: inout GraphicsContext) {
        let hex = Self.palette[index % Self.palette.count]
        let color = Theme.adaptive(hex)
        let lineWidth = height * 0.17

        func place(_ point: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + point.x * height, y: origin.y + point.y * height)
        }

        for polyline in letter.polylines {
            guard let first = polyline.first else { continue }
            var path = Path()
            path.move(to: place(first))
            for point in polyline.dropFirst() { path.addLine(to: place(point)) }
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
        }

        // Stops last, so they sit on top of the lines they interrupt — which is what
        // makes a junction legible on a real map.
        let radius = height * 0.115
        for stop in letter.stops {
            let centre = place(stop)
            let circle = Path(ellipseIn: CGRect(
                x: centre.x - radius, y: centre.y - radius,
                width: radius * 2, height: radius * 2
            ))
            context.fill(circle, with: .color(.white))
            context.stroke(circle, with: .color(color), lineWidth: height * 0.035)
        }
    }
}

/// One letter, as lines on a diagram.
///
/// Normalised to a box `width` across and 1.0 tall, with the origin top-left, so a
/// letter scales by multiplying by the cap height.
struct TransitLetter {
    static let width: CGFloat = 0.62
    static let gap: CGFloat = 0.26

    var polylines: [[CGPoint]]

    /// Where the stops go, deduplicated — two polylines meeting at a corner is one
    /// stop, not two stacked on top of each other.
    ///
    /// Open strokes get a stop at each end, which is where a line on a diagram
    /// terminates. A *closed* stroke has no ends, so endpoints-only left the O with a
    /// single dot on an otherwise blank ring; it gets one at every vertex instead,
    /// which is both what the octagon wants and what the app icon draws.
    var stops: [CGPoint] {
        var seen = Set<String>()
        var result: [CGPoint] = []
        for polyline in polylines {
            for point in stopPoints(of: polyline) {
                let key = String(format: "%.2f,%.2f", point.x, point.y)
                if seen.insert(key).inserted { result.append(point) }
            }
        }
        return result
    }

    private func stopPoints(of polyline: [CGPoint]) -> [CGPoint] {
        guard let first = polyline.first, let last = polyline.last else { return [] }
        let isClosed = polyline.count > 3
            && abs(first.x - last.x) < 0.001
            && abs(first.y - last.y) < 0.001
        // Drop the repeated closing point; it is the same stop as the first.
        return isClosed ? Array(polyline.dropLast()) : [first, last]
    }

    // Columns and rows the letterforms are built from.
    private static let l: CGFloat = 0
    private static let c: CGFloat = 0.31
    private static let r: CGFloat = 0.62
    private static let t: CGFloat = 0
    private static let m: CGFloat = 0.5
    private static let b: CGFloat = 1

    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    init?(character: Character) {
        guard let polylines = Self.shapes[character] else { return nil }
        self.polylines = polylines
    }

    /// The alphabet. Complete, so the app can be renamed without drawing anything.
    private static let shapes: [Character: [[CGPoint]]] = [
        "A": [[p(l, b), p(c, t), p(r, b)], [p(0.155, m), p(0.465, m)]],
        "B": [[p(l, t), p(l, b)],
              [p(l, t), p(0.40, t), p(r, 0.16), p(0.40, m), p(l, m)],
              [p(0.40, m), p(r, 0.66), p(0.40, b), p(l, b)]],
        "C": [[p(r, 0.18), p(0.44, t), p(0.18, t), p(l, 0.22), p(l, 0.78), p(0.18, b), p(0.44, b), p(r, 0.82)]],
        "D": [[p(l, t), p(0.36, t), p(r, 0.30), p(r, 0.70), p(0.36, b), p(l, b), p(l, t)]],
        "E": [[p(r, t), p(l, t), p(l, b), p(r, b)], [p(l, m), p(0.50, m)]],
        "F": [[p(r, t), p(l, t), p(l, b)], [p(l, m), p(0.50, m)]],
        "G": [[p(r, 0.18), p(0.44, t), p(0.18, t), p(l, 0.22), p(l, 0.78), p(0.18, b), p(0.44, b),
               p(r, 0.82), p(r, 0.55), p(0.36, 0.55)]],
        "H": [[p(l, t), p(l, b)], [p(r, t), p(r, b)], [p(l, m), p(r, m)]],
        "I": [[p(c, t), p(c, b)]],
        "J": [[p(r, t), p(r, 0.75), p(0.44, b), p(0.18, b), p(l, 0.78)]],
        "K": [[p(l, t), p(l, b)], [p(r, t), p(l, 0.52)], [p(0.20, 0.44), p(r, b)]],
        "L": [[p(l, t), p(l, b), p(r, b)]],
        "M": [[p(l, b), p(l, t), p(c, m), p(r, t), p(r, b)]],
        "N": [[p(l, b), p(l, t), p(r, b), p(r, t)]],
        "O": [[p(0.18, t), p(0.44, t), p(r, 0.25), p(r, 0.75), p(0.44, b), p(0.18, b),
               p(l, 0.75), p(l, 0.25), p(0.18, t)]],
        "P": [[p(l, b), p(l, t), p(0.40, t), p(r, 0.25), p(0.40, m), p(l, m)]],
        "Q": [[p(0.18, t), p(0.44, t), p(r, 0.25), p(r, 0.75), p(0.44, b), p(0.18, b),
               p(l, 0.75), p(l, 0.25), p(0.18, t)],
              [p(0.40, 0.68), p(r, b)]],
        "R": [[p(l, b), p(l, t), p(0.40, t), p(r, 0.25), p(0.40, m), p(l, m)], [p(0.30, m), p(r, b)]],
        "S": [[p(r, 0.18), p(0.44, t), p(0.18, t), p(l, 0.20), p(0.18, 0.44), p(0.44, 0.56),
               p(r, 0.80), p(0.44, b), p(0.18, b), p(l, 0.82)]],
        "T": [[p(l, t), p(r, t)], [p(c, t), p(c, b)]],
        "U": [[p(l, t), p(l, 0.75), p(0.18, b), p(0.44, b), p(r, 0.75), p(r, t)]],
        "V": [[p(l, t), p(c, b), p(r, t)]],
        "W": [[p(l, t), p(0.155, b), p(c, 0.40), p(0.465, b), p(r, t)]],
        "X": [[p(l, t), p(r, b)], [p(r, t), p(l, b)]],
        "Y": [[p(l, t), p(c, m), p(r, t)], [p(c, m), p(c, b)]],
        "Z": [[p(l, t), p(r, t), p(l, b), p(r, b)]],
    ]

    /// Every letter the alphabet can draw, for the test that keeps the name
    /// drawable — a name with a missing glyph would silently lose a letter.
    static var supportedCharacters: Set<Character> { Set(shapes.keys) }
}
