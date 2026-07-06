import SwiftUI

enum PhoneUtil {
    // Mirror of the edge function's normalizer so stored numbers match at login.
    static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("+") {
            let digits = trimmed.dropFirst().filter(\.isNumber)
            return digits.count >= 8 ? "+" + digits : nil
        }
        let digits = trimmed.filter(\.isNumber)
        if digits.count == 10 { return "+1" + digits }
        if digits.count == 11, digits.hasPrefix("1") { return "+" + digits }
        return nil
    }

    static func pretty(_ e164: String) -> String {
        let d = e164.filter(\.isNumber)
        if d.count == 11, d.hasPrefix("1") {
            let a = d.dropFirst()
            return "(\(a.prefix(3))) \(a.dropFirst(3).prefix(3))-\(a.suffix(4))"
        }
        return e164
    }

    // Progressive live formatting as (XXX) XXX-XXXX. Idempotent.
    static func format(_ raw: String) -> String {
        let digits = String(raw.filter(\.isNumber).prefix(10))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i == 0 { out += "(" } else if i == 3 { out += ") " } else if i == 6 { out += "-" }
            out.append(ch)
        }
        return out
    }
}

@MainActor
@Observable
final class AdminModel {
    var members: [Member] = []
    var loading = true
    var errorText: String?

    func load() async {
        loading = true
        do { members = try await TriviaService.allMembers() }
        catch { errorText = "Couldn't load the roster." }
        loading = false
    }

    func add(name: String, phone: String, admin: Bool, master: Bool) async -> Bool {
        errorText = nil
        guard let e164 = PhoneUtil.normalize(phone) else {
            errorText = "Enter a valid 10-digit phone number."; return false
        }
        do {
            try await TriviaService.addMember(phone: e164, name: name, admin: admin, master: master)
            await load()
            return true
        } catch {
            errorText = "Couldn't add member — is the number already on the roster?"
            return false
        }
    }

    @discardableResult
    func save(_ m: Member) async -> Bool {
        errorText = nil
        do { try await TriviaService.updateMember(m); await load(); return true }
        catch { errorText = "Couldn't save — is that phone number already used?"; return false }
    }

    @discardableResult
    func delete(_ m: Member) async -> Bool {
        errorText = nil
        do { try await TriviaService.deleteMember(id: m.id); await load(); return true }
        catch { errorText = "Couldn't delete this member."; return false }
    }
}

struct AdminView: View {
    @State private var model = AdminModel()
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.loading {
                            ProgressView().tint(Theme.cyan).frame(maxWidth: .infinity).padding(.top, 40)
                        } else {
                            ForEach(model.members) { m in
                                NavigationLink { EditMemberView(model: model, member: m) } label: {
                                    MemberRow(member: m)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if let e = model.errorText {
                            Text(e).font(Theme.label(13)).foregroundStyle(Theme.red)
                        }
                    }
                    .padding(20)
                }
                .refreshable { await model.load() }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { StencilTitle("Team Members", size: 20) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "person.badge.plus").foregroundStyle(.black) }
                }
            }
            .sheet(isPresented: $showAdd) { AddMemberView(model: model) }
            .task { await model.load() }
        }
    }
}

struct MemberRow: View {
    let member: Member
    var body: some View {
        FieldPanel {
            HStack(spacing: 12) {
                LabeledAvatar(avatarId: member.avatar, size: 44, nameSize: 10)
                VStack(alignment: .leading, spacing: 4) {
                    Text(member.displayName).font(Theme.label(17, weight: .bold))
                        .foregroundStyle(.black)
                    Text(PhoneUtil.pretty(member.phone)).font(Theme.label(13)).foregroundStyle(.black)
                    HStack(spacing: 6) {
                        if member.isAdmin { RoleTag(text: "ADMIN", color: Theme.red) }
                        if member.isTriviaMaster { RoleTag(text: "MASTER", color: Theme.cyan) }
                        if !member.isActive { RoleTag(text: "INACTIVE", color: Theme.surfaceHi) }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.black)
            }
        }
    }
}

struct AddMemberView: View {
    let model: AdminModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var phone = ""
    @State private var admin = false
    @State private var master = false
    @State private var working = false

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
                                inputField($phone, placeholder: "(405) 555-0123", keyboard: .phonePad)
                                    .onChange(of: phone) { _, v in
                                        let f = PhoneUtil.format(v); if f != v { phone = f }
                                    }
                                Toggle("Admin (manages roster)", isOn: $admin).tint(Theme.cyan)
                                    .font(Theme.label(15)).foregroundStyle(Theme.textPrimary)
                                Toggle("Trivia Master", isOn: $master).tint(Theme.cyan)
                                    .font(Theme.label(15)).foregroundStyle(Theme.textPrimary)
                            }
                        }
                        if let e = model.errorText {
                            Text(e).font(Theme.label(13)).foregroundStyle(Theme.red)
                        }
                        Button {
                            working = true
                            Task {
                                if await model.add(name: name.trimmed, phone: phone, admin: admin, master: master) {
                                    dismiss()
                                }
                                working = false
                            }
                        } label: {
                            if working { ProgressView().tint(.black) } else { Text("ADD TO ROSTER") }
                        }
                        .buttonStyle(JoeButtonStyle())
                        .disabled(working || name.trimmed.isEmpty || phone.trimmed.isEmpty)
                        .opacity(name.trimmed.isEmpty || phone.trimmed.isEmpty ? 0.5 : 1)

                        Button("CANCEL") { dismiss() }
                            .buttonStyle(JoeButtonStyle(tint: Theme.red, fg: Theme.onPrimary))
                    }
                    .padding(20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { StencilTitle("New Recruit", size: 20) }
            }
        }
    }
}

struct EditMemberView: View {
    let model: AdminModel
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @State var member: Member
    @State private var phoneText = ""
    @State private var working = false
    @State private var errorText: String?
    @State private var confirmDelete = false

    private var isSelf: Bool { member.id == app.currentMember?.id }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    FieldPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            fieldLabel("NAME")
                            inputField($member.displayName, placeholder: "Name")
                            fieldLabel("PHONE")
                            inputField($phoneText, placeholder: "(405) 555-0123", keyboard: .phonePad)
                                .onChange(of: phoneText) { _, v in
                                    let f = PhoneUtil.format(v); if f != v { phoneText = f }
                                }
                            Divider().overlay(Theme.oliveDrab)
                            Toggle("Admin", isOn: $member.isAdmin).tint(Theme.cyan)
                                .font(Theme.label(15)).foregroundStyle(Theme.textPrimary)
                            Toggle("Trivia Master", isOn: $member.isTriviaMaster).tint(Theme.cyan)
                                .font(Theme.label(15)).foregroundStyle(Theme.textPrimary)
                            Toggle("Active (can sign in)", isOn: $member.isActive).tint(Theme.cyan)
                                .font(Theme.label(15)).foregroundStyle(Theme.textPrimary)
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
                        member.phone = e164
                        working = true
                        Task {
                            if await model.save(member) { dismiss() }
                            else { errorText = model.errorText }
                            working = false
                        }
                    } label: {
                        if working { ProgressView().tint(.black) } else { Text("SAVE CHANGES") }
                    }
                    .buttonStyle(JoeButtonStyle())
                    .disabled(working || member.displayName.trimmed.isEmpty || phoneText.trimmed.isEmpty)

                    if !isSelf {
                        Button("DELETE MEMBER") { confirmDelete = true }
                            .buttonStyle(JoeButtonStyle(tint: Theme.red, fg: Theme.onPrimary))
                            .disabled(working)
                    }
                }
                .padding(20)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { StencilTitle("Edit Member", size: 20) } }
        .onAppear { phoneText = PhoneUtil.pretty(member.phone) }
        .alert("Delete \(member.displayName)?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                working = true
                Task {
                    if await model.delete(member) { dismiss() }
                    else { errorText = model.errorText }
                    working = false
                }
            }
        } message: {
            Text("This removes them from the roster and deletes their trivia answers. This can't be undone.")
        }
    }
}

// Shared styled text field.
func inputField(_ text: Binding<String>, placeholder: String, keyboard: UIKeyboardType = .default) -> some View {
    TextField("", text: text, prompt: Text(placeholder).foregroundColor(.black))
        .keyboardType(keyboard)
        .padding(12).background(Theme.surfaceHi)
        .foregroundStyle(Theme.textPrimary)
        .font(Theme.label(17, weight: .medium))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
}
