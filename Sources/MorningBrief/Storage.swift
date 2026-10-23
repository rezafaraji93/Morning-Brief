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

    /// Logs older than 14 days (a streamed brief log can run to megabytes) and agent scratch files
    /// older than a day go; briefs are kept.
    static func prune() {
        let fm = FileManager.default
        let limits: [(URL, Date)] = [
            (logs, Date().addingTimeInterval(-14 * 86_400)),
            (work, Date().addingTimeInterval(-86_400)),
        ]
        for (dir, cutoff) in limits {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in files {
                let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified < cutoff { try? fm.removeItem(at: f) }
            }
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
    var headline: String? = nil
    var usage: BriefUsage? = nil
    /// When the brief's data last changed; the panel reloads its view when this moves.
    var modified: Date = .distantPast
    var id: String { day }

    // DateFormatters are costly to make and safe to share, so one of each for all briefs.
    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        return f
    }
    private static let long = formatter("EEEE, MMM d")
    private static let short = formatter("EEE")
    private static let dayNumber = formatter("d")

    private var date: Date? { Self.parser.date(from: day) }

    var displayName: String { date.map { Self.long.string(from: $0) } ?? day }
    var weekdayShort: String { date.map { Self.short.string(from: $0).uppercased() } ?? "" }
    var dayOfMonth: String { date.map { Self.dayNumber.string(from: $0) } ?? "" }
}

enum BriefStore {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ date: Date = Date()) -> String { dayFormatter.string(from: date) }

    /// Just the headline, for the Earlier list; no need to decode the whole brief.
    private struct HeadlineOnly: Decodable { var headline: String? }

    static func htmlURL(day: String) -> URL { Paths.briefs.appendingPathComponent("\(day).html") }
    static func jsonURL(day: String) -> URL { Paths.briefs.appendingPathComponent("\(day).json") }
    static func metaURL(day: String) -> URL { Paths.briefs.appendingPathComponent("\(day).meta.json") }

    static func save(html: String, json: Data, usage: BriefUsage?, day: String) throws -> URL {
        Paths.ensure()
        let h = htmlURL(day: day)
        try html.write(to: h, atomically: true, encoding: .utf8)
        try json.write(to: jsonURL(day: day), options: .atomic)
        if let usage, let data = try? JSONEncoder().encode(usage) {
            try? data.write(to: metaURL(day: day), options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: metaURL(day: day))
        }
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
            .map { b in
                var b = b
                let json = jsonURL(day: b.day)
                if let data = try? Data(contentsOf: json),
                   let head = try? JSONDecoder().decode(HeadlineOnly.self, from: data) {
                    b.headline = head.headline
                }
                if let data = try? Data(contentsOf: metaURL(day: b.day)) {
                    b.usage = try? JSONDecoder().decode(BriefUsage.self, from: data)
                }
                let attrs = (try? FileManager.default.attributesOfItem(atPath: json.path))
                    ?? (try? FileManager.default.attributesOfItem(atPath: b.htmlURL.path))
                b.modified = attrs?[.modificationDate] as? Date ?? .distantPast
                return b
            }
    }

    /// Re-renders a stored brief with the current template, so older briefs pick up design changes.
    /// Falls back to the saved page when its JSON is missing or no longer decodes.
    static func rerender(_ b: StoredBrief) -> URL {
        if let data = try? Data(contentsOf: jsonURL(day: b.day)),
           let brief = try? Brief.decoder.decode(Brief.self, from: data),
           let rendered = try? BriefRenderer.render(brief, done: DoneStore.keys()),
           (try? String(contentsOf: b.htmlURL, encoding: .utf8)) != rendered.html {
            try? rendered.html.write(to: b.htmlURL, atomically: true, encoding: .utf8)
        }
        return b.htmlURL
    }
}

/// Items the user ticked off in a brief. A done item is struck through wherever it's shown, and
/// the next runs leave it out, for 30 days. Safe from any thread; writes are rare and tiny.
enum DoneStore {
    struct Entry: Codable, Equatable {
        let key: String      // the item's https link, or "t:" + its title when it has none
        let title: String
        let markedAt: Date
    }

    private static var url: URL { Paths.root.appendingPathComponent("done.json") }
    private static let keepFor: TimeInterval = 30 * 86_400

    private static let lock = NSLock()
    private static var changes = 0
    /// Bumped on every change, so a view showing a brief knows to redraw it.
    static var version: Int { lock.withLock { changes } }

    static func entries() -> [Entry] {
        guard let data = try? Data(contentsOf: url),
              let all = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        let cutoff = Date().addingTimeInterval(-keepFor)
        return all.filter { $0.markedAt > cutoff }
    }

    static func keys() -> [String] { entries().map(\.key) }

    /// Marked done within the last `days`, oldest first, for the prompt.
    static func handled(days: Int) -> [Entry] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        return entries().filter { $0.markedAt > cutoff }.sorted { $0.markedAt < $1.markedAt }
    }

    static func set(key: String, title: String, done: Bool) {
        var all = entries().filter { $0.key != key }
        if done { all.append(Entry(key: key, title: title, markedAt: Date())) }
        Paths.ensure()
        if let data = try? JSONEncoder().encode(all) {
            try? data.write(to: url, options: .atomic)
        }
        lock.withLock { changes += 1 }
    }

    /// Mirrors keyFor() in template.html.
    static func key(for item: Brief.Item) -> String {
        if let u = item.url, u.lowercased().hasPrefix("https://") { return u }
        return "t:" + (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The brief without the items that are already done; a section left with nothing is dropped.
    static func strip(_ brief: Brief) -> Brief {
        let done = Set(keys())
        guard !done.isEmpty else { return brief }
        func keep(_ items: [Brief.Item]?) -> [Brief.Item]? {
            items?.filter { !done.contains(key(for: $0)) }
        }
        var b = brief
        b.needsAttention = keep(b.needsAttention)
        b.resolved = keep(b.resolved)
        b.sections = b.sections?.compactMap { section in
            var s = section
            s.items = keep(s.items)
            let empty = (s.items ?? []).isEmpty && (s.prose ?? "").isEmpty
            return empty ? nil : s
        }
        return b
    }
}
