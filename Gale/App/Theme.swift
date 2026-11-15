import SwiftUI
import GaleFormat

enum Theme {
    static let accent = Color(red: 0.486, green: 0.227, blue: 0.929)
    static let sky = Color(red: 0.133, green: 0.827, blue: 0.933)
    static let gradient = LinearGradient(colors: [sky, accent], startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    init(_ color: Color) {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if !ui.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var w: CGFloat = 0
            ui.getWhite(&w, alpha: &a)
            r = w; g = w; b = w
        }
        self.init(Double(r), Double(g), Double(b), Double(a))
    }
}
