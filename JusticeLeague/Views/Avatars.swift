import SwiftUI

// The selectable G.I. Joe (1983) avatars — each a stylized glyph on the shared
// field-green badge.
struct JoeAvatar: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let hex: UInt32
    var color: Color { Color(hex: hex) }
}

enum Avatars {
    static let all: [JoeAvatar] = [
        JoeAvatar(id: "duke",        name: "Duke",         symbol: "star",                                     hex: 0xC79A3B),
        JoeAvatar(id: "snake_eyes",  name: "Snake Eyes",   symbol: "eye.slash",                                hex: 0x26262B),
        JoeAvatar(id: "roadblock",   name: "Roadblock",    symbol: "dumbbell",                                 hex: 0xC0651D),
        JoeAvatar(id: "gung_ho",     name: "Gung-Ho",      symbol: "megaphone",                                hex: 0xB03A2E),
        JoeAvatar(id: "stalker",     name: "Stalker",      symbol: "binoculars",                               hex: 0x4E6B2F),
        JoeAvatar(id: "doc",         name: "Doc",          symbol: "cross.case",                               hex: 0x2AA198),
        JoeAvatar(id: "wild_bill",   name: "Wild Bill",    symbol: "hat.widebrim",                             hex: 0x8E6B3A),
        JoeAvatar(id: "breaker",     name: "Breaker",      symbol: "antenna.radiowaves.left.and.right",        hex: 0x2E6DA4),
        JoeAvatar(id: "clutch",      name: "Clutch",       symbol: "steeringwheel",                            hex: 0x5D6D7E),
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
        ZStack {
            Circle().fill(background)
            Image(systemName: avatar?.symbol ?? "person")
                .font(.system(size: size * 0.44, weight: .regular))
                .foregroundStyle(avatar == nil ? .black : .white)
        }
        .frame(width: size, height: size)
        .overlay(
            Circle().strokeBorder(
                avatar == nil ? Color.black.opacity(0.18) : Avatars.badgeGreenEdge,
                lineWidth: 1
            )
        )
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

// Avatar badge with the chosen G.I. Joe's codename beneath it. Shows nothing
// under the badge when the member hasn't picked an avatar yet.
struct LabeledAvatar: View {
    let avatarId: String?
    var size: CGFloat = 56
    var nameSize: CGFloat = 11

    var body: some View {
        VStack(spacing: 4) {
            AvatarBadge(avatar: Avatars.find(avatarId), size: size)
            if let joe = Avatars.find(avatarId) {
                Text(joe.name)
                    .font(Theme.label(nameSize, weight: .bold))
                    .foregroundStyle(.black)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: size + 16)
            }
        }
    }
}

struct AvatarPickerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var takenByOthers: Set<String> = []
    @State private var savingId: String?
    @State private var errorText: String?
    @State private var gridWidth: CGFloat = 0

    private let columnGap: CGFloat = 14
    private var currentId: String? { app.currentMember?.avatar }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: columnGap), count: 3)
    }

    // One grid column's width, so the centered last row uses the same spacing as full rows.
    private var columnWidth: CGFloat? {
        gridWidth > 0 ? (gridWidth - columnGap * 2) / 3 : nil
    }

    // Full rows go in the grid; any trailing partial row is centered on its own.
    private var gridItems: [JoeAvatar] {
        Array(Avatars.all.prefix((Avatars.all.count / 3) * 3))
    }
    private var lastRowItems: [JoeAvatar] {
        Array(Avatars.all.suffix(Avatars.all.count % 3))
    }

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

                        VStack(spacing: 18) {
                            LazyVGrid(columns: columns, spacing: 18) {
                                ForEach(gridItems) { a in
                                    cell(a)
                                }
                            }
                            .background(GeometryReader { geo in
                                Color.clear
                                    .onAppear { gridWidth = geo.size.width }
                                    .onChange(of: geo.size.width) { _, w in gridWidth = w }
                            })
                            if !lastRowItems.isEmpty {
                                HStack(spacing: columnGap) {
                                    ForEach(lastRowItems) { a in
                                        cell(a).frame(width: columnWidth)
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { StencilTitle("Choose Avatar", size: 20) }
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
