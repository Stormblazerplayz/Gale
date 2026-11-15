import SwiftUI

// Placeholders while these screens are being finished. Replaced in the next commit.
struct LearnHomeView: View {
    var body: some View { ContentUnavailableView("Courses", systemImage: "graduationcap", description: Text("Coming in the next build.")) }
}

struct ScanView: View {
    var onOpenProject: (URL) -> Void
    var body: some View { ContentUnavailableView("Body scan", systemImage: "figure.stand", description: Text("Coming in the next build.")) }
}
