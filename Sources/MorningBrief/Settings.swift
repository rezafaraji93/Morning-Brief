import Foundation

enum AgentKind: String, CaseIterable, Codable, Identifiable {
    case claude, codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// Executable name looked up on the user's PATH.
    var binaryName: String { rawValue }
}

struct AppSettings: Codable, Equatable {
    /// "auto" or an AgentKind raw value.
    var agent: String = "auto"
    /// Optional absolute path to the agent binary (overrides PATH lookup).
    var binaryOverride: String = ""
    /// Optional model name passed to the agent.
    var model: String = ""
    /// Extra command-line arguments appended to the agent invocation (shell-style quoting).
    var extraArgs: String = ""

    var hour: Int = 8
    var minute: Int = 0
    var weekdaysOnly: Bool = true

    var name: String = AppSettings.defaultFirstName()
    var language: String = AppSettings.defaultLanguage()
    /// Free text about the user's role and which tools matter ("I work in engineering; include Linear").
    var about: String = ""
    /// Optional extra sections, one per line ("#android-releases channel", "PRs waiting on my review").
    var sections: String = ""
    /// Slack channels the brief reads in full but reports only what concerns the user from.
    var watchChannels: String = ""
    /// Messages the user reacted to with `todoEmoji` are their to-do list for the brief.
    var todoEnabled: Bool = true
    /// Emoji name (no colons).
    var todoEmoji: String = "bookmark"
    var timeoutMinutes: Int = 15
    /// The user's own instructions for the brief, used in place of Resources/prompt.md when enabled.
    var customPromptEnabled: Bool = false
    var customPrompt: String = ""

    init() {}

    // Tolerant decoding: fields added in later versions fall back to their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? d.agent
        binaryOverride = try c.decodeIfPresent(String.self, forKey: .binaryOverride) ?? d.binaryOverride
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        extraArgs = try c.decodeIfPresent(String.self, forKey: .extraArgs) ?? d.extraArgs
        hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? d.hour
        minute = try c.decodeIfPresent(Int.self, forKey: .minute) ?? d.minute
        weekdaysOnly = try c.decodeIfPresent(Bool.self, forKey: .weekdaysOnly) ?? d.weekdaysOnly
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        about = try c.decodeIfPresent(String.self, forKey: .about) ?? d.about
        sections = try c.decodeIfPresent(String.self, forKey: .sections) ?? d.sections
        watchChannels = try c.decodeIfPresent(String.self, forKey: .watchChannels) ?? d.watchChannels
        todoEnabled = try c.decodeIfPresent(Bool.self, forKey: .todoEnabled) ?? d.todoEnabled
        todoEmoji = try c.decodeIfPresent(String.self, forKey: .todoEmoji) ?? d.todoEmoji
        timeoutMinutes = try c.decodeIfPresent(Int.self, forKey: .timeoutMinutes) ?? d.timeoutMinutes
        customPromptEnabled = try c.decodeIfPresent(Bool.self, forKey: .customPromptEnabled) ?? d.customPromptEnabled
        customPrompt = try c.decodeIfPresent(String.self, forKey: .customPrompt) ?? d.customPrompt
    }

    private static let key = "MorningBrief.settings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: AppSettings.key)
        }
    }

    /// "#a, b\n#c" → ["#a", "#b", "#c"]: commas, spaces or new lines between names, # optional.
    static func channelList(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "#" }
            .map { $0.hasPrefix("#") ? $0 : "#" + $0 }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// Emojis offered for the to-do mark, with the names Slack uses for them.
    struct TodoEmoji: Identifiable, Hashable {
        let name: String
        let glyph: String
        let title: String
        var id: String { name }

        static let catalog: [TodoEmoji] = [
            TodoEmoji(name: "bookmark", glyph: "🔖", title: "Bookmark"),
            TodoEmoji(name: "pushpin", glyph: "📌", title: "Pushpin"),
            TodoEmoji(name: "eyes", glyph: "👀", title: "Eyes"),
            TodoEmoji(name: "white_check_mark", glyph: "✅", title: "Check mark"),
            TodoEmoji(name: "memo", glyph: "📝", title: "Memo"),
            TodoEmoji(name: "star", glyph: "⭐", title: "Star"),
            TodoEmoji(name: "alarm_clock", glyph: "⏰", title: "Alarm clock"),
            TodoEmoji(name: "hourglass_flowing_sand", glyph: "⏳", title: "Hourglass"),
            TodoEmoji(name: "inbox_tray", glyph: "📥", title: "Inbox"),
            TodoEmoji(name: "bulb", glyph: "💡", title: "Bulb"),
            TodoEmoji(name: "dart", glyph: "🎯", title: "Dart"),
            TodoEmoji(name: "zap", glyph: "⚡", title: "Zap"),
            TodoEmoji(name: "bell", glyph: "🔔", title: "Bell"),
            TodoEmoji(name: "clipboard", glyph: "📋", title: "Clipboard"),
            TodoEmoji(name: "hammer_and_wrench", glyph: "🛠️", title: "Tools"),
            TodoEmoji(name: "bug", glyph: "🐛", title: "Bug"),
            TodoEmoji(name: "rocket", glyph: "🚀", title: "Rocket"),
            TodoEmoji(name: "point_up", glyph: "☝️", title: "Point up"),
            TodoEmoji(name: "exclamation", glyph: "❗", title: "Exclamation"),
            TodoEmoji(name: "question", glyph: "❓", title: "Question"),
        ]

        static func named(_ name: String) -> TodoEmoji? { catalog.first { $0.name == name } }
    }

    /// ":bookmark:" or " Bookmark " → "bookmark"; anything that isn't an emoji name → "".
    static func emojiName(_ raw: String) -> String {
        let n = raw.trimmingCharacters(in: CharacterSet(charactersIn: ": \t\n")).lowercased()
        return n.range(of: "^[a-z0-9_+-]+$", options: .regularExpression) != nil ? n : ""
    }

    static func defaultFirstName() -> String {
        let full = NSFullUserName()
        return full.split(separator: " ").first.map(String.init) ?? full
    }

    static func defaultLanguage() -> String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }
}
