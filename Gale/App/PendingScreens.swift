import SwiftUI

// Placeholders while these screens are being finished. Replaced in the next commit.
struct StudioView: View {
    @ObservedObject var document: ProjectDocument
    var body: some View { ContentUnavailableView("Video studio", systemImage: "film.stack", description: Text("Coming in the next build.")) }
}

struct LearnHomeView: View {
    var body: some View { ContentUnavailableView("Courses", systemImage: "graduationcap", description: Text("Coming in the next build.")) }
}

struct ScanView: View {
    var onOpenProject: (URL) -> Void
    var body: some View { ContentUnavailableView("Body scan", systemImage: "figure.stand", description: Text("Coming in the next build.")) }
}
