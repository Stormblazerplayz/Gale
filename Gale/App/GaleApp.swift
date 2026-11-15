import SwiftUI

@main
struct GaleApp: App {
    @StateObject private var library = ProjectLibrary()
    @StateObject private var store = LibraryStore()
    @StateObject private var sync = SyncManager()

    init() {
        UITestMode.resetIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(library)
                .environmentObject(store)
                .environmentObject(sync)
                .tint(Theme.accent)
                .onOpenURL { url in sync.handle(url: url) }
                .task {
                    // UI tests skip computer sync so no "find devices on your network" question pops up.
                    if !UITestMode.on { sync.start(library: library) }
                }
        }
    }
}
