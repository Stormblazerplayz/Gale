import SwiftUI

@main
struct GaleApp: App {
    @StateObject private var library = ProjectLibrary()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(library)
                .tint(Theme.accent)
        }
    }
}
