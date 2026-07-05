import SwiftUI

// G.I. Joe (1983) inspired theme: olive drab, field tan, klaxon red and gold,
// stencil-style headers. Colors defined in code so no asset round-trips are needed
// (a few are also mirrored in Assets.xcassets for launch screen / accent).
enum Theme {
    static let background   = Color(hex: 0x1C2118) // dark olive field
    static let surface      = Color(hex: 0x2A3122) // raised panel
    static let surfaceHi    = Color(hex: 0x3A4230) // lighter panel
    static let oliveDrab    = Color(hex: 0x556B2F)
    static let tan          = Color(hex: 0xC9B27A) // field tan
    static let gold         = Color(hex: 0xE0A526) // Joe gold
    static let red          = Color(hex: 0xB4271F) // Cobra / klaxon red
    static let textPrimary  = Color(hex: 0xF2EFE4)
    static let textDim      = Color(hex: 0x9AA383)
    static let stencilStroke = Color(hex: 0x0F120B)

    // Condensed, heavy system font approximates a military stencil without shipping fonts.
    static func stencil(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy, design: .default).width(.condensed)
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

// Stencil-style screen title, e.g. "DAILY INTEL".
struct StencilTitle: View {
    let text: String
    var size: CGFloat = 30
    init(_ text: String, size: CGFloat = 30) { self.text = text; self.size = size }
    var body: some View {
        Text(text.uppercased())
            .font(Theme.stencil(size))
            .tracking(2)
            .foregroundStyle(Theme.gold)
            .shadow(color: Theme.stencilStroke, radius: 0, x: 1.5, y: 1.5)
    }
}

// Olive panel with a stitched border used across the app.
struct FieldPanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Theme.oliveDrab, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// Primary action button (gold, dog-tag styling).
struct JoeButtonStyle: ButtonStyle {
    var tint: Color = Theme.gold
    var fg: Color = Color(hex: 0x1C2118)
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.label(17, weight: .bold))
            .tracking(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(tint.opacity(configuration.isPressed ? 0.75 : 1))
            .foregroundStyle(fg)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

extension View {
    // Fills the screen with the field background.
    func joeBackground() -> some View {
        self.background(Theme.background.ignoresSafeArea())
    }
}
