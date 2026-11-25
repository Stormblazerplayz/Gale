import GaleFormat
import GalePixel
import SwiftUI

/// Grid size, the color set and the paper color of a pixel story.
struct PixelSettingsView: View {
    @ObservedObject var document: ProjectDocument
    @Environment(\.dismiss) private var dismiss
    @State private var width = 32
    @State private var height = 32
    @State private var confirmPalette: PixelPalette?

    private var story: PixelStory { document.project.pixel ?? PixelStory(width: 16, height: 16) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Width: \(width)", value: $width, in: PixelStory.minSide...PixelStory.maxSide, step: 4)
                    Stepper("Height: \(height)", value: $height, in: PixelStory.minSide...PixelStory.maxSide, step: 4)
                    Button("Change grid size") {
                        editStory { $0.resize(width: width, height: height) }
                    }
                    .disabled(width == story.width && height == story.height)
                } header: {
                    Text("Grid")
                } footer: {
                    Text("Art stays in the top left corner. Anything outside a smaller grid is cut off (Undo brings it back).")
                }
                Section {
                    ForEach(PixelPalette.all) { p in
                        Button {
                            confirmPalette = p
                        } label: {
                            HStack {
                                Text(p.name).foregroundStyle(.primary)
                                Spacer()
                                HStack(spacing: 0) {
                                    ForEach(Array(p.colors.prefix(16).enumerated()), id: \.offset) { _, c in
                                        Rectangle().fill(c.color).frame(width: 10, height: 18)
                                    }
                                }
                                if story.paletteName == p.name { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                        }
                    }
                } header: {
                    Text("Colors")
                } footer: {
                    Text("Switching moves every pixel to the closest color in the new set.")
                }
                Section("Paper") {
                    ColorPicker("Paper color", selection: Binding(
                        get: { (document.project.pixel?.paper ?? .white).color },
                        set: { c in editStory(undoable: false) { $0.paper = RGBA(c) } }), supportsOpacity: true)
                }
            }
            .navigationTitle("Grid and colors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Switch to \(confirmPalette?.name ?? "")?", isPresented: Binding(
                get: { confirmPalette != nil }, set: { if !$0 { confirmPalette = nil } }), titleVisibility: .visible) {
                Button("Switch colors") {
                    if let p = confirmPalette { editStory { $0.switchPalette(to: p) } }
                    confirmPalette = nil
                }
                Button("Cancel", role: .cancel) { confirmPalette = nil }
            }
            .onAppear {
                width = story.width
                height = story.height
            }
        }
    }

    private func editStory(undoable: Bool = true, _ change: (inout PixelStory) -> Void) {
        document.edit(undoable: undoable) { p in
            guard var st = p.pixel else { return }
            change(&st)
            p.pixel = st
            p.canvas = GaleProject.pixelCanvas(st)
        }
    }
}
