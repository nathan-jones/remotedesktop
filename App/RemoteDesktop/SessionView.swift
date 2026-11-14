import SwiftUI

struct SessionView: View {
    @ObservedObject var model: SessionModel
    @State private var keyboardVisible = false
    @State private var composing = false
    @State private var draft = ""
    @AppStorage("composeSendsReturn") private var sendsReturn = false
    @FocusState private var draftFocused: Bool
    @State private var confirmingPassword = false

    var body: some View {
        Group {
            if RemoteScreenUIView.usesDirectPointer {
                // On the Mac the actions live in the window's toolbar, off the remote screen.
                screen(floatingControls: false)
                    #if targetEnvironment(macCatalyst)
                    .onAppear {
                        MacToolbar.shared.install(title: model.sessionHost, actions: [
                            .init(identifier: "write", title: "Write Text", symbol: "text.bubble") {
                                composing.toggle()
                                draftFocused = composing
                            },
                            .init(identifier: "password", title: "Type Password", symbol: "key.fill") {
                                confirmingPassword = true
                            },
                            .init(identifier: "disconnect", title: "Disconnect", symbol: "xmark") {
                                model.disconnect()
                            },
                        ])
                    }
                    .onDisappear { MacToolbar.shared.remove() }
                    #endif
            } else {
                screen(floatingControls: true)
                    .statusBarHidden()
                    .persistentSystemOverlays(.hidden)
            }
        }
        // Asked first, because the password goes wherever the Mac's keyboard focus is.
        .confirmationDialog(
            "Type the password for \(model.sessionUsername) on the Mac?",
            isPresented: $confirmingPassword, titleVisibility: .visible
        ) {
            Button("Type Password and Press Return") { model.typePassword(pressReturn: true) }
            Button("Type Password Only") { model.typePassword(pressReturn: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It is typed wherever the Mac's cursor is, so check a password field is selected.")
        }
    }

    private func screen(floatingControls: Bool) -> some View {
        GeometryReader { geometry in
            ZStack {
                // On the Mac the black stops at the title bar, which keeps the system's own background.
                Color.black.ignoresSafeArea(edges: floatingControls ? .all : [.horizontal, .bottom])

                RemoteScreenView(model: model, keyboardVisible: $keyboardVisible)
                    // Under a toolbar the picture stays below it rather than behind it.
                    .ignoresSafeArea(edges: floatingControls ? .all : [])

                if !model.hasVideo {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(statusText)
                            .foregroundStyle(.secondary)
                        Text(model.recentLog.joined(separator: "\n"))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if floatingControls {
                    controls
                        // In the laptop posture the controls sit on the lower half, clear of the Mac's screen
                        // and of the fold itself.
                        .padding(.top, model.laptopPosture ? Self.foldOffset(in: geometry) + 20 : 0)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if composing { composeBar }
        }
    }

    /// Distance from the top of the safe area to the fold, which runs across the middle of the whole screen.
    private static func foldOffset(in geometry: GeometryProxy) -> CGFloat {
        let insets = geometry.safeAreaInsets
        return (geometry.size.height + insets.top + insets.bottom) / 2 - insets.top
    }

    private var controls: some View {
        HStack(spacing: 6) { actionButtons }
            .font(.title2.weight(.semibold))
            .buttonStyle(ControlButtonStyle())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(12)
    }

    @ViewBuilder private var actionButtons: some View {
        Button {
            keyboardVisible = false
            composing.toggle()
            draftFocused = composing
        } label: {
            Label(composing ? "Close Text Entry" : "Write Text", systemImage: composing ? "text.bubble.fill" : "text.bubble")
        }
        .help("Write text to send to the Mac")

        Button {
            confirmingPassword = true
        } label: {
            Label("Type Password", systemImage: "key.fill")
        }
        .help("Type the account password on the Mac")

        if !RemoteScreenUIView.usesDirectPointer {
            Button {
                composing = false
                keyboardVisible.toggle()
            } label: {
                Label(keyboardVisible ? "Hide Keyboard" : "Show Keyboard",
                      systemImage: keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
            }
        }

        Button(role: .destructive) {
            model.disconnect()
        } label: {
            Label("Disconnect", systemImage: "xmark")
        }
        .help("Disconnect")
    }

    /// Text is written here with the phone's own autocorrect, dictation and
    /// editing, then typed on the Mac in one go.
    private var composeBar: some View {
        HStack(spacing: 10) {
            TextField("Write or dictate, then send", text: $draft)
                .focused($draftFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                sendsReturn.toggle()
            } label: {
                Image(systemName: "return")
                    .foregroundStyle(sendsReturn ? Color.accentColor : Color.secondary)
            }
            .accessibilityLabel("Press Return after sending")
            .accessibilityValue(sendsReturn ? "On" : "Off")

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(draft.isEmpty && !sendsReturn)
            .accessibilityLabel("Send to Mac")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func send() {
        model.typeText(draft)
        if sendsReturn { model.tapKey(Keysym.returnKey) }
        draft = ""
        draftFocused = true
    }

    private var statusText: String {
        switch model.phase {
        case .connecting(let message): return message
        case .streaming: return "Waiting for video…"
        case .disconnected: return ""
        }
    }
}

/// Gives each control a full-size touch target, not just the glyph.
private struct ControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .foregroundStyle(configuration.role == .destructive ? Color.red : Color.accentColor)
            .frame(width: 52, height: 52)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.45 : 1)
    }
}
