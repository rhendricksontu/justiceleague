import SwiftUI
import UIKit

// The selectable G.I. Joe (1983) avatars. Most are a stylized glyph on the shared
// field-green badge; an avatar may instead supply `image` (an asset-catalog name)
// to use real character art, which fills the badge.
struct JoeAvatar: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let hex: UInt32
    var image: String? = nil
    var color: Color { Color(hex: hex) }
}

enum Avatars {
    static let all: [JoeAvatar] = [
        JoeAvatar(id: "duke",        name: "Duke",         symbol: "star",                                     hex: 0xC79A3B, image: "AvatarDuke"),
        JoeAvatar(id: "snake_eyes",  name: "Snake Eyes",   symbol: "eye.slash",                                hex: 0x26262B),
        JoeAvatar(id: "roadblock",   name: "Roadblock",    symbol: "dumbbell",                                 hex: 0xC0651D),
        JoeAvatar(id: "gung_ho",     name: "Gung-Ho",      symbol: "megaphone",                                hex: 0xB03A2E),
        JoeAvatar(id: "stalker",     name: "Stalker",      symbol: "binoculars",                               hex: 0x4E6B2F),
        JoeAvatar(id: "doc",         name: "Doc",          symbol: "cross.case",                               hex: 0x2AA198),
        JoeAvatar(id: "wild_bill",   name: "Wild Bill",    symbol: "bird",                                     hex: 0x8E6B3A, image: "AvatarWildBill"),
        JoeAvatar(id: "breaker",     name: "Breaker",      symbol: "antenna.radiowaves.left.and.right",        hex: 0x2E6DA4),
        JoeAvatar(id: "clutch",      name: "Clutch",       symbol: "truck.pickup.side",                        hex: 0x5D6D7E),
        JoeAvatar(id: "rock_n_roll", name: "Rock 'n' Roll",symbol: "guitars",                                  hex: 0x7D3C98),
        JoeAvatar(id: "steeler",     name: "Steeler",      symbol: "shield",                                   hex: 0x34495E),
        JoeAvatar(id: "flash",       name: "Flash",        symbol: "bolt",                                     hex: 0xC79A00),
        JoeAvatar(id: "zap",         name: "Zap",          symbol: "flame",                                    hex: 0xD35400),
        JoeAvatar(id: "torpedo",     name: "Torpedo",      symbol: "water.waves",                              hex: 0x196F8C),
    ]
    static func find(_ id: String?) -> JoeAvatar? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    // Every avatar shares one field-drab green (Stalker's) for a cohesive look.
    static let badgeGreen     = Color(hex: 0x4E6B2F)
    static let badgeGreenTop  = Color(hex: 0x5E7F3A)   // slightly lit top for depth
    static let badgeGreenEdge = Color(hex: 0x374B20)   // thin darker rim
}

// Circular avatar badge — a modern military patch: unified drab-green field with
// a subtle top-lit gradient, a clean white glyph, and a thin rim (no heavy ring).
struct AvatarBadge: View {
    let avatar: JoeAvatar?
    var size: CGFloat = 56

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(ringColor, lineWidth: 1))
    }

    @ViewBuilder
    private var content: some View {
        if let art = imageAsset {
            Image(art).resizable().scaledToFill()
        } else {
            ZStack {
                Circle().fill(background)
                Image(systemName: avatar?.symbol ?? "person")
                    .font(.system(size: size * 0.44, weight: .regular))
                    .foregroundStyle(avatar == nil ? .black : .white)
            }
        }
    }

    // Use character art only if the asset actually exists; otherwise fall back to the glyph.
    private var imageAsset: String? {
        guard let name = avatar?.image, UIImage(named: name) != nil else { return nil }
        return name
    }

    private var ringColor: Color {
        if imageAsset != nil { return Color.black.opacity(0.2) }
        return avatar == nil ? Color.black.opacity(0.18) : Avatars.badgeGreenEdge
    }

    private var background: AnyShapeStyle {
        guard avatar != nil else { return AnyShapeStyle(Theme.surfaceHi) }
        return AnyShapeStyle(
            LinearGradient(
                colors: [Avatars.badgeGreenTop, Avatars.badgeGreen],
                startPoint: .top, endPoint: .bottom
            )
        )
    }
}

struct AvatarPickerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var takenByOthers: Set<String> = []
    @State private var savingId: String?
    @State private var errorText: String?

    private var currentId: String? { app.currentMember?.avatar }
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 14)]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 14) {
                        Text("Pick your G.I. Joe. Once you choose, no one else in the group can use it.")
                            .font(Theme.label(14, weight: .regular)).foregroundStyle(.black)
                            .multilineTextAlignment(.center).padding(.horizontal, 8)

                        if let e = errorText {
                            Text(e).font(Theme.label(13)).foregroundStyle(Theme.red)
                        }

                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(Avatars.all) { a in
                                cell(a)
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { StencilTitle("Choose Avatar", size: 20) }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(.black)
                }
            }
            .task { await loadTaken() }
        }
    }

    @ViewBuilder
    private func cell(_ a: JoeAvatar) -> some View {
        let taken = takenByOthers.contains(a.id)
        let selected = currentId == a.id
        Button {
            Task { await select(a) }
        } label: {
            VStack(spacing: 6) {
                AvatarBadge(avatar: a, size: 68)
                    .opacity(taken ? 0.3 : 1)
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(Theme.cyan)
                                .background(Circle().fill(.white))
                        }
                    }
                    .overlay {
                        if savingId == a.id { ProgressView().tint(.white) }
                    }
                Text(a.name)
                    .font(Theme.label(12, weight: .bold))
                    .foregroundStyle(.black)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(taken ? "Taken" : (selected ? "Yours" : " "))
                    .font(Theme.label(10, weight: .bold))
                    .foregroundStyle(taken ? Theme.red : Theme.cyan)
            }
        }
        .disabled(taken || savingId != nil)
    }

    private func loadTaken() async {
        let members = (try? await TriviaService.allMembers()) ?? []
        let mine = app.currentMember?.id
        takenByOthers = Set(members.filter { $0.id != mine }.compactMap { $0.avatar })
    }

    private func select(_ a: JoeAvatar) async {
        errorText = nil
        savingId = a.id
        if await app.setMyAvatar(a.id) {
            dismiss()
        } else {
            errorText = "\(a.name) was just taken. Pick another."
            await loadTaken()
        }
        savingId = nil
    }
}
