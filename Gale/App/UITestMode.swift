import Foundation

/// Switches used only when the UI tests run the app (they launch it with -uiTesting).
enum UITestMode {
    static let on = ProcessInfo.processInfo.arguments.contains("-uiTesting")
    /// Posted by the hidden test button: the canvas draws a shaky zigzag through the real drawing steps.
    static let scribble = Notification.Name("gale.uitest.scribble")

    /// Starts every test run with no projects and default settings, so results never depend on an old run.
    static func resetIfNeeded() {
        guard on else { return }
        let fm = FileManager.default
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
           let items = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            for item in items { try? fm.removeItem(at: item) }
        }
        UserDefaults.standard.removeObject(forKey: "gale.editor.settings")
    }
}
