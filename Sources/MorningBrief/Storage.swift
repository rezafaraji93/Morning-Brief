import Foundation

/// Locations under ~/Library/Application Support/MorningBrief.
enum Paths {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MorningBrief", isDirectory: true)
    }
    static var briefs: URL { root.appendingPathComponent("briefs", isDirectory: true) }
    static var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    /// Empty working directory for agent runs, so no repo or project context leaks in.
    static var work: URL { root.appendingPathComponent("work", isDirectory: true) }

    static func ensure() {
        for dir in [root, briefs, logs, work] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

/// Bundled resources: Contents/Resources in the .app, or ./Resources when run with `swift run`.
enum Res {
    static func url(_ name: String, _ ext: String) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: ext) { return u }
        let repo = URL(fileURLWithPath: #filePath)   // .../Sources/MorningBrief/Storage.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let u = repo.appendingPathComponent("Resources").appendingPathComponent("\(name).\(ext)")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static func data(_ name: String, _ ext: String) throws -> Data {
        guard let u = url(name, ext) else { throw BriefError.missingResource("\(name).\(ext)") }
        return try Data(contentsOf: u)
    }

    static func string(_ name: String, _ ext: String) throws -> String {
        guard let s = String(data: try data(name, ext), encoding: .utf8) else {
            throw BriefError.missingResource("\(name).\(ext)")
        }
        return s
    }
}

struct StoredBrief: Identifiable, Hashable {
    let day: String      // yyyy-MM-dd
    let htmlURL: URL
    var id: String { day }

    var displayName: String {
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy-MM-dd"
        guard let date = parse.date(from: day) else { return day }
        let out = DateFormatter()
        out.dateFormat = "EEEE, MMM d"
        return out.string(from: date)
    }
}

enum BriefStore {
    static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func htmlURL(day: String) -> URL { Paths.briefs.appendingPathComponent("\(day).html") }
    static func jsonURL(day: String) -> URL { Paths.briefs.appendingPathComponent("\(day).json") }

    static func save(html: String, json: Data, day: String) throws -> URL {
        Paths.ensure()
        let h = htmlURL(day: day)
        try html.write(to: h, atomically: true, encoding: .utf8)
        try json.write(to: jsonURL(day: day), options: .atomic)
        return h
    }

    static func exists(day: String) -> Bool {
        FileManager.default.fileExists(atPath: htmlURL(day: day).path)
    }

    static func recent(limit: Int = 10) -> [StoredBrief] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.briefs, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "html" }
            .map { StoredBrief(day: $0.deletingPathExtension().lastPathComponent, htmlURL: $0) }
            .sorted { $0.day > $1.day }
            .prefix(limit)
            .map { $0 }
    }
}
