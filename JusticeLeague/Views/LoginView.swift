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

                VStack(spacing: 8) {
                    StencilTitle("Justice League", size: 36)
                    Text("OKLAHOMA  •  EST. 2026")
                        .font(Theme.label(11, weight: .bold))
                        .tracking(3)
                        .foregroundStyle(Theme.tan)
                }

                FieldPanel {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("REPORT FOR DUTY")
                            .font(Theme.stencil(18))
                            .tracking(1.5)
                            .foregroundStyle(Theme.gold)
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
                            .background(Theme.background)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.oliveDrab))

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
                                ProgressView().tint(Color(hex: 0x1C2118))
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
                Text("Not on the roster? Ask your admin to add your number.")
                    .font(Theme.label(12, weight: .regular))
                    .foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 20)
            }
        }
        .onAppear { focused = true }
    }
}
