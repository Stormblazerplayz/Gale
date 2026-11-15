import Foundation

/// Reads and writes Gale files.
///
/// A project is a folder named "<something>.gale" holding:
///   project.json   the whole project (see spec/format.md)
///   media/         video, audio and picture files used by the movie tracks
///   cover.png      a small picture of the first frame (optional)
public enum GaleIO {
    public static let projectFile = "project.json"
    public static let mediaFolder = "media"
    public static let coverFile = "cover.png"
    public static let projectExtension = "gale"

    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self), let date = parseDate(s) { return date }
            if let n = try? c.decode(Double.self) { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a date")
        }
        return d
    }

    /// Reads ISO 8601 dates with or without fractions of a second (JavaScript writes fractions).
    public static func parseDate(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) { return d }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return frac.date(from: s)
    }

    public static func encode<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
        try encoder(pretty: pretty).encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }

    // MARK: Project folders

    public static func readProject(at folder: URL) throws -> GaleProject {
        let data = try Data(contentsOf: folder.appendingPathComponent(projectFile))
        return try decode(GaleProject.self, from: data)
    }

    /// Writes project.json safely: a half-written file can never replace a good one.
    public static func writeProject(_ project: GaleProject, to folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appendingPathComponent(mediaFolder), withIntermediateDirectories: true)
        let data = try encode(project)
        try data.write(to: folder.appendingPathComponent(projectFile), options: .atomic)
    }

    public static func mediaURL(_ item: MediaItem, in folder: URL) -> URL {
        folder.appendingPathComponent(mediaFolder).appendingPathComponent(item.file)
    }

    /// A folder name that's safe for files: letters, numbers, spaces, - and _.
    public static func safeName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(60))
    }
}
