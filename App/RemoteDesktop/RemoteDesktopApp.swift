import SwiftUI

@main
struct RemoteDesktopApp: App {
    @StateObject private var model = SessionModel()

    init() {
        setvbuf(stdout, nil, _IOLBF, 0)   // so diagnostics reach an attached console promptly
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if model.isSessionVisible {
                    // The session is always dark; the home screen follows the system.
                    #if targetEnvironment(macCatalyst)
                    // On the Mac only the content is dark, so the title bar and
                    // toolbar keep the system appearance.
                    SessionView(model: model)
                        .environment(\.colorScheme, .dark)
                    #else
                    SessionView(model: model)
                        .preferredColorScheme(.dark)
                    #endif
                } else {
                    ConnectView(model: model)
                }
            }
        }
    }
}
