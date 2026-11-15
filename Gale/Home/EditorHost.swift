import SwiftUI
import GaleFormat

/// Opens a project folder and shows the editor for it.
struct EditorHost: View {
    let url: URL
    @State private var project: GaleProject?
    @State private var error: String?

    var body: some View {
        Group {
            if let project {
                Text(project.name)
            } else if let error {
                Text(error).foregroundStyle(.red).padding()
            } else {
                ProgressView()
            }
        }
        .task {
            do {
                project = try GaleIO.readProject(at: url)
            } catch {
                self.error = "Couldn't open this project: \(error.localizedDescription)"
            }
        }
    }
}
