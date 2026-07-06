import SwiftUI
import Supabase

struct MainTabView: View {
    @Environment(AppState.self) private var app
    @State private var selection = 4   // Comms

    var body: some View {
        TabView(selection: $selection) {
            ChatView()
                .tabItem { Label("Comms", systemImage: "bubble.left.and.bubble.right.fill") }.tag(4)
                .badge(app.chatUnread)

            CalendarView()
                .tabItem { Label("Ops", systemImage: "calendar") }.tag(5)

            TodayView()
                .tabItem { Label("Intel", systemImage: "target") }.tag(0)

            if app.currentMember?.isAdmin == true {
                AdminView()
                    .tabItem { Label("Soldiers", systemImage: "person.3.fill") }.tag(2)
            }

            ProfileView()
                .tabItem { Label("Me", systemImage: "person.crop.circle") }.tag(3)
        }
        .task { await app.refreshMember() }
        .task { await app.refreshChatUnread() }
        .task { await watchChatBadge() }
        #if DEBUG
        .onAppear {
            if let t = ProcessInfo.processInfo.environment["START_TAB"], let i = Int(t) { selection = i }
        }
        #endif
    }

    // Keep the unread badge live even when the Comms tab isn't open.
    private func watchChatBadge() async {
        let client = SupabaseManager.client
        let channel = client.channel("badge:messages")
        let inserts = channel.postgresChange(InsertAction.self, schema: "public", table: "messages")
        await channel.subscribe()
        for await change in inserts {
            guard let row = try? change.decodeRecord(as: RealtimeMessageRow.self, decoder: JSONDecoder())
            else { continue }
            // Ignore my own messages and anything while I'm reading the channel.
            if row.member_id != app.currentMember?.id && selection != 4 {
                app.chatUnread += 1
            }
        }
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
                                HStack(alignment: .top, spacing: 14) {
                                    LabeledAvatar(avatarId: m.avatar, size: 64, nameSize: 12)
                                    VStack(alignment: .leading, spacing: 6) {
                                        StencilTitle(m.displayName, size: 20, solid: true)
                                        Text(PhoneUtil.pretty(m.phone))
                                            .font(Theme.label(15))
                                            .foregroundStyle(.black)
                                    }
                                    Spacer()
                                    Button { showEdit = true } label: {
                                        Image(systemName: "pencil")
                                            .font(.system(size: 20, weight: .bold))
                                            .foregroundStyle(.black)
                                    }
                                    .accessibilityLabel("Edit profile")
                                }
                                HStack(spacing: 8) {
                                    if m.isAdmin { RoleTag(text: "ADMIN") }
                                    if m.isTriviaMaster { RoleTag(text: "TRIVIA") }
                                    if !m.isAdmin && !m.isTriviaMaster { RoleTag(text: "MEMBER") }
                                }
                            }
                        }
                    }

                    Spacer()
                    Button("SIGN OUT") { Task { await app.signOut() } }
                        .buttonStyle(JoeButtonStyle(tint: Theme.red, fg: Theme.onPrimary))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
            .sheet(isPresented: $showEdit) { EditProfileView().flyUpSheet() }
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
    @State private var showAvatar = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        FieldPanel {
                            VStack(alignment: .leading, spacing: 12) {
                                fieldLabel("NAME")
                                inputField($name)
                                fieldLabel("PHONE")
                                inputField($phoneText, keyboard: .phonePad)
                                    .onChange(of: phoneText) { _, v in
                                        let f = PhoneUtil.format(v); if f != v { phoneText = f }
                                    }
                                Divider().overlay(Theme.oliveDrab)
                                Button { showAvatar = true } label: {
                                    HStack(spacing: 14) {
                                        AvatarBadge(avatar: Avatars.find(app.currentMember?.avatar), size: 56)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(Avatars.find(app.currentMember?.avatar)?.name ?? "Choose Avatar")
                                                .font(Theme.label(16, weight: .bold))
                                                .foregroundStyle(.black)
                                            Text("Tap to change your G.I. Joe")
                                                .font(Theme.label(12))
                                                .foregroundStyle(Theme.textDim)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundStyle(.black)
                                    }
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
            }
            .onAppear {
                if let m = app.currentMember {
                    name = m.displayName
                    phoneText = PhoneUtil.pretty(m.phone)
                }
            }
            .sheet(isPresented: $showAvatar) { AvatarPickerView().flyUpSheet() }
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
