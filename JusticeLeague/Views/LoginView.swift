import SwiftUI

struct LoginView: View {
    @Environment(AppState.self) private var app
    @State private var phone = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 22) {
                Spacer()

                JoeWordmark(size: 38)

                FieldPanel {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("REPORT FOR DUTY")
                            .font(Theme.stencil(20))
                            .tracking(0.5)
                            .foregroundStyle(Theme.red)
                        Text("Enter your phone number to sign in.")
                            .font(Theme.label(14, weight: .regular))
                            .foregroundStyle(Theme.textDim)

                        TextField("", text: $phone, prompt: Text("(405) 555-0123").foregroundColor(Theme.textDim))
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                            .focused($focused)
                            .font(Theme.label(20, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(12)
                            .background(Theme.surfaceHi)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))

                        if let err = app.loginError {
                            Text(err)
                                .font(Theme.label(13, weight: .medium))
                                .foregroundStyle(Theme.red)
                        }

                        Button {
                            focused = false
                            Task { await app.signIn(phone: phone) }
                        } label: {
                            if app.isWorkingOnLogin {
                                ProgressView().tint(Theme.onPrimary)
                            } else {
                                Text("SIGN IN")
                            }
                        }
                        .buttonStyle(JoeButtonStyle())
                        .disabled(app.isWorkingOnLogin || phone.filter(\.isNumber).count < 10)
                        .opacity(phone.filter(\.isNumber).count < 10 ? 0.5 : 1)
                    }
                }
                .padding(.horizontal, 20)

                Spacer()
            }
        }
        .onAppear { focused = true }
    }
}
