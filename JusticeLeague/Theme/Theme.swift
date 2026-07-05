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

    // Heavy italic condensed — the G.I. Joe wordmark treatment.
    static func stencil(_ size: CGFloat) -> Font {
        .system(size: size, weight: .black, design: .default).width(.condensed).italic()
    }
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

// Section header in the logo type (dark ink, italic, condensed).
struct StencilTitle: View {
    let text: String
    var size: CGFloat = 30
    var color: Color = Theme.ink
    init(_ text: String, size: CGFloat = 30, color: Color = Theme.ink) {
        self.text = text; self.size = size; self.color = color
    }
    var body: some View {
        Text(text.uppercased())
            .font(Theme.stencil(size))
            .tracking(0.5)
            .foregroundStyle(color)
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
                Text(text).font(font).foregroundStyle(stroke).offset(o)
            }
            Text(text).font(font).foregroundStyle(fill)
        }
    }
}

// The big brand lockup used on login / splash: "JUSTICE ★ LEAGUE".
struct JoeWordmark: View {
    var size: CGFloat = 40
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                OutlinedText(text: "JUSTICE", font: Theme.stencil(size), width: size * 0.055)
                Image(systemName: "star.fill")
                    .font(.system(size: size * 0.5, weight: .black))
                    .foregroundStyle(Theme.cyan)
                    .shadow(color: .black, radius: 0, x: size * 0.03, y: 0)
                OutlinedText(text: "LEAGUE", font: Theme.stencil(size), width: size * 0.055)
            }
            HStack(spacing: 8) {
                Rectangle().fill(Theme.red).frame(width: 28, height: 3)
                Text("REAL AMERICAN MEN")
                    .font(Theme.label(11, weight: .heavy)).tracking(2).foregroundStyle(Theme.tan)
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
