import SwiftUI

struct MainTabView: View {
    @Environment(AppState.self) private var app
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            TodayView()
                .tabItem { Label("Trivia", systemImage: "target") }.tag(0)

            LeaderboardView()
                .tabItem { Label("Leaderboard", systemImage: "medal.fill") }.tag(1)

            if app.currentMember?.isAdmin == true {
                AdminView()
                    .tabItem { Label("Roster", systemImage: "person.3.fill") }.tag(2)
            }

            ProfileView()
                .tabItem { Label("Me", systemImage: "person.crop.circle") }.tag(3)
        }
        .task { await app.refreshMember() }
        #if DEBUG
        .onAppear {
            if let t = ProcessInfo.processInfo.environment["START_TAB"], let i = Int(t) { selection = i }
        }
        #endif
    }
}

struct ProfileView: View {
    @Environment(AppState.self) private var app
    @State private var showEdit = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 24) {
                    JoeWordmark(size: 34, tagline: "FOUNDING FATHER")
                        .padding(.top, 16)

                    if let m = app.currentMember {
                        FieldPanel {
                            VStack(alignment: .leading, spacing: 12) {
                                StencilTitle(m.displayName, size: 22, solid: true)
                                Text(PhoneUtil.pretty(m.phone))
                                    .font(Theme.label(15))
                                    .foregroundStyle(.black)
                                HStack(spacing: 8) {
                                    if m.isAdmin { RoleTag(text: "ADMIN") }
                                    if m.isTriviaMaster { RoleTag(text: "TRIVIA MASTER") }
                                    if !m.isAdmin && !m.isTriviaMaster { RoleTag(text: "MEMBER") }
                                }
                            }
                        }
                        Button("EDIT PROFILE") { showEdit = true }
                            .buttonStyle(JoeButtonStyle(tint: Theme.surfaceHi, fg: .black))
                    }

                    Spacer()
                    Button("SIGN OUT") { Task { await app.signOut() } }
                        .buttonStyle(JoeButtonStyle(tint: Theme.red, fg: Theme.onPrimary))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
            .sheet(isPresented: $showEdit) { EditProfileView() }
            .navigationTitle("")
        }
    }
}

// Lets a member edit their own name + phone.
struct EditProfileView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var phoneText = ""
    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        FieldPanel {
                            VStack(alignment: .leading, spacing: 12) {
                                fieldLabel("NAME")
                                inputField($name, placeholder: "John Smith")
                                fieldLabel("PHONE")
                                inputField($phoneText, placeholder: "(405) 555-0123", keyboard: .phonePad)
                                    .onChange(of: phoneText) { _, v in
                                        let f = PhoneUtil.format(v); if f != v { phoneText = f }
                                    }
                            }
                        }
                        if let e = errorText {
                            Text(e).font(Theme.label(13)).foregroundStyle(Theme.red)
                        }
                        Button {
                            errorText = nil
                            guard let e164 = PhoneUtil.normalize(phoneText) else {
                                errorText = "Enter a valid 10-digit phone number."; return
                            }
                            working = true
                            Task {
                                if await app.updateMyProfile(name: name.trimmed, phone: e164) { dismiss() }
                                else { errorText = "Couldn't save — is that phone number already used?" }
                                working = false
                            }
                        } label: {
                            if working { ProgressView().tint(.black) } else { Text("SAVE") }
                        }
                        .buttonStyle(JoeButtonStyle())
                        .disabled(working || name.trimmed.isEmpty || phoneText.trimmed.isEmpty)
                    }
                    .padding(20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { StencilTitle("Edit Profile", size: 20) }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(.black)
                }
            }
            .onAppear {
                if let m = app.currentMember {
                    name = m.displayName
                    phoneText = PhoneUtil.pretty(m.phone)
                }
            }
        }
    }
}

struct RoleTag: View {
    let text: String
    var color: Color = Theme.cyan   // kept for call-site compatibility; all pills are cyan
    var body: some View {
        Text(text)
            .font(Theme.label(11, weight: .bold))
            .tracking(1)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.cyan)
            .clipShape(Capsule())
    }
}
