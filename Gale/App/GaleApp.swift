import SwiftUI

@main
struct GaleApp: App {
    @StateObject private var library = ProjectLibrary()
    @StateObject private var store = LibraryStore()
    @StateObject private var sync = SyncManager()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(library)
                .environmentObject(store)
                .environmentObject(sync)
                .tint(Theme.accent)
                .onOpenURL { url in sync.handle(url: url) }
                .task { sync.start(library: library) }
        }
    }
}
