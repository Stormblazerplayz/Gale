import GaleFormat
import SwiftUI

/// Opens a project folder and shows the editor for it.
struct EditorHost: View {
    let url: URL
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var sync: SyncManager
    @State private var document: ProjectDocument?
    @State private var error: String?

    var body: some View {
        Group {
            if let document {
                EditorView(document: document, store: store)
            } else if let error {
                ContentUnavailableView("Couldn't open this project", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .task {
            guard document == nil else { return }
            do {
                let doc = try ProjectDocument(folder: url)
                sync.attach(doc)
                document = doc
            } catch {
                self.error = error.localizedDescription
            }
        }
        .onDisappear {
            if let document { sync.detach(document) }
        }
    }
}
