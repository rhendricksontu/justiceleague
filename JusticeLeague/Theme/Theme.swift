import SwiftUI

// G.I. Joe (1983) inspired LIGHT theme. Pulls straight from the classic logo:
// bold italic condensed wordmark in near-black ink, a cyan star, the red/white/cyan
// tricolor block, and Joe red for action. Set on a light "field ops" sand background.
enum Theme {
    static let background   = Color(hex: 0xECE7DA) // light sand field
    static let surface      = Color(hex: 0xFFFFFF) // white cards
    static let surfaceHi    = Color(hex: 0xF1ECDF) // subtle raised panel
    static let line         = Color(hex: 0xD6CFBE) // hairline borders

    static let ink          = Color(hex: 0x17181C) // logo/heading near-black
    static let red          = Color(hex: 0xE4002B) // Joe red — primary action
    static let cyan         = Color(hex: 0x009FCB) // Joe star blue
    static let gold         = Color(hex: 0xC1912E) // medals only
    static let oliveDrab    = Color(hex: 0x4E5C2A) // military green accent

    static let textPrimary  = Color(hex: 0x17181C)
    static let textDim      = Color(hex: 0x6F6A5C)
    static let tan          = Color(hex: 0x7C6F4E) // khaki secondary labels
    static let onPrimary    = Color(hex: 0xFFFFFF) // text/spinner on red buttons

    // Blocked display face (Anton, OFL) — the G.I. Joe logo lettering. Used for
    // every header, title and button label across the app.
    static func stencil(_ size: CGFloat) -> Font {
        .custom("Anton-Regular", size: size)
    }
    static func block(_ size: CGFloat) -> Font { stencil(size) }
    static func label(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255
        )
    }
}

// Section header / title in the logo style. Default is the wordmark treatment
// (white fill, black outline) for titles on the sand background; `solid: true`
// renders plain black for headers sitting on white cards.
struct StencilTitle: View {
    let text: String
    var size: CGFloat = 30
    var solid: Bool = false
    init(_ text: String, size: CGFloat = 30, solid: Bool = false) {
        self.text = text; self.size = size; self.solid = solid
    }
    var body: some View {
        let tracking = size * 0.10
        if solid {
            Text(text.uppercased())
                .font(Theme.block(size))
                .tracking(tracking)
                .foregroundStyle(Theme.ink)
        } else {
            OutlinedText(text: text.uppercased(), font: Theme.block(size),
                         width: max(1, size * 0.05), tracking: tracking)
        }
    }
}

// The red / white / cyan tricolor block from the logo.
struct TricolorBar: View {
    var width: CGFloat = 34
    var height: CGFloat = 8
    var body: some View {
        VStack(spacing: 2) {
            Capsule().fill(Theme.red)
            Capsule().fill(Color.white).overlay(Capsule().strokeBorder(Theme.line, lineWidth: 0.5))
            Capsule().fill(Theme.cyan)
        }
        .frame(width: width, height: height)
    }
}

// White text with a black outline (Text has no native stroke, so we layer
// offset black copies behind a white fill).
struct OutlinedText: View {
    let text: String
    let font: Font
    var fill: Color = .white
    var stroke: Color = .black
    var width: CGFloat = 2
    var tracking: CGFloat = 0

    private var offsets: [CGSize] {
        let w = width
        return [
            CGSize(width:  w, height: 0), CGSize(width: -w, height: 0),
            CGSize(width: 0, height:  w), CGSize(width: 0, height: -w),
            CGSize(width:  w, height:  w), CGSize(width: -w, height: -w),
            CGSize(width:  w, height: -w), CGSize(width: -w, height:  w),
        ]
    }

    var body: some View {
        ZStack {
            ForEach(Array(offsets.enumerated()), id: \.offset) { _, o in
                Text(text).font(font).tracking(tracking).foregroundStyle(stroke).offset(o)
            }
            Text(text).font(font).tracking(tracking).foregroundStyle(fill)
        }
    }
}

// A sharp 5-point star (miter joins keep the points crisp).
struct StarShape: Shape {
    var pointsCount: Int = 5
    var innerRatio: CGFloat = 0.40
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        let step = CGFloat.pi / CGFloat(pointsCount)
        var angle = -CGFloat.pi / 2 // first point straight up
        for i in 0 ..< pointsCount * 2 {
            let r = i.isMultiple(of: 2) ? outer : inner
            let p = CGPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r)
            i == 0 ? path.move(to: p) : path.addLine(to: p)
            angle += step
        }
        path.closeSubpath()
        return path
    }
}

// Cyan star with a solid black outline, matching the logo.
struct JoeStar: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            StarShape().fill(Theme.cyan)
            StarShape().stroke(.black, style: StrokeStyle(lineWidth: size * 0.09, lineJoin: .miter))
        }
        .frame(width: size, height: size)
    }
}

// Horizontal shear to slant the upright block face like the italic logo.
// Top of the glyphs shifts right relative to the baseline.
struct Skew: GeometryEffect {
    var k: CGFloat = 0.2
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(a: 1, b: 0, c: -k, d: 1, tx: k * size.height, ty: 0))
    }
}

// The big brand lockup used on login / splash: "JUSTICE ★ LEAGUE".
struct JoeWordmark: View {
    var size: CGFloat = 40
    var body: some View {
        VStack(spacing: 8) {
            // Star gaps equal the intra-word letter spacing. "JUSTICE" already
            // carries a trailing tracking unit; "LEAGUE" has no leading one, so we
            // add matching leading padding before it.
            HStack(spacing: 0) {
                OutlinedText(text: "JUSTICE", font: Theme.block(size),
                             width: size * 0.05, tracking: size * 0.10)
                JoeStar(size: size * 0.92)
                OutlinedText(text: "LEAGUE", font: Theme.block(size),
                             width: size * 0.05, tracking: size * 0.10)
                    .padding(.leading, size * 0.10)
            }
            .modifier(Skew(k: 0.18))
            HStack(spacing: 8) {
                Rectangle().fill(Theme.red).frame(width: 28, height: 3)
                Text("REAL AMERICAN MEN")
                    .font(Theme.label(11, weight: .heavy)).tracking(2).foregroundStyle(Theme.tan)
                    .modifier(Skew(k: 0.16))
                Rectangle().fill(Theme.cyan).frame(width: 28, height: 3)
            }
        }
    }
}

// White card with a hairline border and soft shadow on the light field.
struct FieldPanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line, lineWidth: 1)
            )
            .shadow(color: Theme.ink.opacity(0.06), radius: 8, x: 0, y: 3)
    }
}

// Primary action button — Joe blue, white italic type.
struct JoeButtonStyle: ButtonStyle {
    var tint: Color = Theme.cyan
    var fg: Color = Theme.onPrimary
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.stencil(19))
            .tracking(0.5)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(tint.opacity(configuration.isPressed ? 0.8 : 1))
            .foregroundStyle(fg)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

extension View {
    func joeBackground() -> some View {
        self.background(Theme.background.ignoresSafeArea())
    }
}
