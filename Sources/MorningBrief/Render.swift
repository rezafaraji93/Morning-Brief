import Foundation

enum PromptBuilder {
    static let buttonsOn = """
    Include action buttons. For a needs_attention item an assistant could actually move forward (a reply to draft, \
    something to research, a doc to write together, options to think through), give {label, seed}. label: imperative, \
    5 words or fewer, naming what pressing it produces ("Draft the reply"); different items get different labels. \
    seed: a self-contained work order in prose for a fresh assistant. It names the situation by reference, never by \
    quotation (who asked, which tool their message lives in, roughly when, what kind of ask); what is owed and to whom; \
    which tools it can reach; and what done looks like (a draft, a decision, a doc). It carries no verbatim words from \
    anyone else. Emails can only be drafted, never sent. Use null for decisions only they can make, places they need to \
    be, anything touching money, health or credentials, and always on resolved items.
    """
    static let buttonsOff = "always null."

    static func build(settings: AppSettings, now: Date = Date()) throws -> String {
        let tpl = try Res.string("prompt", "md")
        let schema = try Res.string("brief.schema", "json")

        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "EEEE, MMMM d, yyyy ('ISO' yyyy-MM-dd)"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm"

        let name = settings.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let about = settings.about.trimmingCharacters(in: .whitespacesAndNewlines)
        let sectionLines = settings.sections
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var sections = ""
        if !sectionLines.isEmpty {
            sections = "\nSections requested (one targeted fetch each, returned in `sections` in this order):\n"
                + sectionLines.map { "- \($0)" }.joined(separator: "\n")
        }

        let replacements: [String: String] = [
            "{{NAME}}": name.isEmpty ? "the user" : name,
            "{{TODAY}}": day.string(from: now),
            "{{NOW}}": time.string(from: now),
            "{{TIMEZONE}}": TimeZone.current.identifier,
            "{{LANGUAGE}}": settings.language.isEmpty ? "English" : settings.language,
            "{{ABOUT}}": about.isEmpty ? "(nothing specific; use judgement)" : about,
            "{{SECTIONS}}": sections,
            "{{BUTTONS}}": settings.includeButtons ? buttonsOn : buttonsOff,
            "{{SCHEMA}}": schema,
        ]
        var out = tpl
        for (k, v) in replacements { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }

    static let probe = """
    Do not call any tools and do not fetch any data. From the tools available to you in this session, list which \
    ones would serve each role for a morning brief: calendar, chat (e.g. Slack), email, meeting notes (e.g. Granola), \
    task tracker or docs (e.g. Linear, Notion). Reply with exactly one short line per role in the form \
    "role: tool or server name" or "role: not connected". Nothing else.
    """
}

enum BriefRenderer {
    private struct Payload: Encodable {
        struct Options: Encodable { var buttons: Bool }
        var brief: Brief
        var options: Options
    }

    /// Fills Resources/template.html with the font and the brief as an inert JSON data island.
    /// The page's own script draws everything with textContent, so agent text can't become markup.
    static func render(_ brief: Brief, buttons: Bool) throws -> (html: String, json: Data) {
        let template = try Res.string("template", "html")
        let font = try Res.data("fraunces-latin-600-normal", "woff2").base64EncodedString()
        let json = try Brief.encoder.encode(Payload(brief: brief, options: .init(buttons: buttons)))
        guard var island = String(data: json, encoding: .utf8) else {
            throw BriefError.unparseable("Couldn't encode the brief.")
        }
        // Nothing inside the data island may close the <script> element or start a comment.
        island = island
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        let html = template
            .replacingOccurrences(of: "__FONT_B64__", with: font)
            .replacingOccurrences(of: "__BRIEF_JSON__", with: island)
        let raw = try Brief.encoder.encode(brief)
        return (html, raw)
    }
}
