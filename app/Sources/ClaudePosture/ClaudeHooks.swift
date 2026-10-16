import Foundation

/// Noodle's two Claude Code hooks in ~/.claude/settings.json, added and removed without jq.
/// Same rules as JQ_MERGE / JQ_UNMERGE in scripts/_hooks.sh: adding is a no-op when our command
/// is already anywhere under that event, removing takes out exactly our command and drops a group,
/// event, or `hooks` object only if that emptied it. Nothing else in the file changes, key order included.
/// scripts/test-hooks.sh checks the output against jq byte for byte.
struct ClaudeHooks {
    static let promptCommand = "open -g 'claudeposture://prompt' >/dev/null 2>&1 &"
    static let stopCommand = "open -g 'claudeposture://stop' >/dev/null 2>&1 &"
    private static let ours = [("UserPromptSubmit", promptCommand), ("Stop", stopCommand)]

    /// CLAUDE_SETTINGS overrides the path, like the scripts (handy for testing on a copy).
    static var defaultURL: URL {
        if let p = ProcessInfo.processInfo.environment["CLAUDE_SETTINGS"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    let url: URL
    init(url: URL = Self.defaultURL) { self.url = url }

    enum Failure: LocalizedError {
        case unreadable(String)
        case changedOnDisk
        var errorDescription: String? {
            switch self {
            case .unreadable(let why): return why
            case .changedOnDisk: return "settings.json changed while this was open. Here's the change again."
            }
        }
    }

    /// One proposed edit: the file as it is now and as it would be.
    struct Plan {
        let old: String
        let new: String
        let changed: Bool

        /// Unified-diff-style lines ["+", text], ["-", text], [" ", text], with "…" rows between hunks.
        func diff(context: Int = 3) -> [[String]] {
            let a = Self.lines(old), b = Self.lines(new)
            let d = b.difference(from: a)
            var removed = Set<Int>(), inserted = Set<Int>()
            for c in d {
                switch c {
                case .remove(let o, _, _): removed.insert(o)
                case .insert(let o, _, _): inserted.insert(o)
                }
            }
            var rows: [(String, String)] = []
            var i = 0, j = 0
            while i < a.count || j < b.count {
                if i < a.count, removed.contains(i) { rows.append(("-", a[i])); i += 1 }
                else if j < b.count, inserted.contains(j) { rows.append(("+", b[j])); j += 1 }
                else { rows.append((" ", a[i])); i += 1; j += 1 }
            }
            let near = rows.indices.map { k in
                rows[max(0, k - context)...min(rows.count - 1, k + context)].contains { $0.0 != " " }
            }
            var out: [[String]] = []
            for (k, r) in rows.enumerated() {
                if near[k] { out.append([r.0, r.1]) }
                else if out.last?[0] != "…" { out.append(["…", ""]) }
            }
            return out
        }

        private static func lines(_ s: String) -> [String] {
            var l = s.components(separatedBy: "\n")
            if l.last == "" { l.removeLast() }
            return l
        }
    }

    /// True when both hooks are already there. Throws when the file can't be read as a JSON object.
    func isConnected() throws -> Bool { try !plan(connect: true).changed }

    func plan(connect: Bool) throws -> Plan {
        var old = ""
        if FileManager.default.fileExists(atPath: url.path) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw Failure.unreadable("Couldn't read \(Self.tilde(url)).")
            }
            old = text
        }
        var root: JSON
        if old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            root = .object([])
        } else {
            guard let parsed = JSON.parse(old), case .object = parsed else {
                throw Failure.unreadable("\(Self.tilde(url)) isn't a JSON object, so Noodle left it alone.")
            }
            root = parsed
        }
        var changed = false
        for (event, command) in Self.ours {
            changed = try (connect ? Self.add(&root, event, command) : Self.remove(&root, event, command)) || changed
        }
        let new = changed ? root.pretty(indent: JSON.indent(of: old)) + "\n" : old
        return Plan(old: old, new: new, changed: changed)
    }

    /// Writes `plan`, after checking the file still matches what was previewed. Backs the old file up to
    /// settings.json.bak-<timestamp> (never overwriting a backup) and writes through a symlinked settings.json.
    /// Returns the backup, if there was a file to back up.
    @discardableResult
    func apply(_ plan: Plan) throws -> URL? {
        guard plan.changed else { return nil }
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard current == plan.old else { throw Failure.changedOnDisk }
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath()
        var backup: URL?
        var perms: Any?
        if fm.fileExists(atPath: target.path) {
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            let base = url.path + ".bak-" + stamp.string(from: Date())
            var bak = base, n = 1
            while fm.fileExists(atPath: bak) { bak = "\(base)-\(n)"; n += 1 }
            try fm.copyItem(at: target, to: URL(fileURLWithPath: bak))
            backup = URL(fileURLWithPath: bak)
            perms = try? fm.attributesOfItem(atPath: target.path)[.posixPermissions]
        } else {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data(plan.new.utf8).write(to: target, options: .atomic)
        if let perms { try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: target.path) }
        return backup
    }

    static func tilde(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }

    // MARK: The merge rules

    private static func runs(_ group: JSON, _ command: String) -> Bool {
        guard case .array(let hs)? = group["hooks"] else { return false }
        return hs.contains { $0["command"]?.string == command }
    }

    /// JQ_MERGE's add($ev; $cmd). Returns whether it changed anything.
    private static func add(_ root: inout JSON, _ event: String, _ command: String) throws -> Bool {
        let hooks = root["hooks"] ?? .null
        guard hooks.isNull || hooks.isObject else { throw shape("hooks") }
        let groups = hooks[event] ?? .null
        guard groups.isNull || groups.isArray else { throw shape("hooks.\(event)") }
        if case .array(let gs) = groups, gs.contains(where: { runs($0, command) }) { return false }
        let ours = JSON.object([("hooks", .array([.object([("type", .string("command")), ("command", .string(command))])]))])
        var list: [JSON] = []
        if case .array(let gs) = groups { list = gs }
        var h = hooks.isNull ? JSON.object([]) : hooks
        h[event] = .array(list + [ours])
        root["hooks"] = h
        return true
    }

    /// JQ_UNMERGE's rm($ev; $cmd). Returns whether it changed anything.
    private static func remove(_ root: inout JSON, _ event: String, _ command: String) throws -> Bool {
        guard var h = root["hooks"], h.isObject, case .array(let gs)? = h[event],
              gs.contains(where: { runs($0, command) }) else { return false }
        let kept: [JSON] = gs.compactMap { g in
            guard runs(g, command), case .array(let hs)? = g["hooks"] else { return g }
            let rest = hs.filter { $0["command"]?.string != command }
            if rest.isEmpty { return nil }
            var g = g
            g["hooks"] = .array(rest)
            return g
        }
        if kept.isEmpty { h[event] = nil } else { h[event] = .array(kept) }
        if case .object(let pairs) = h, pairs.isEmpty { root["hooks"] = nil } else { root["hooks"] = h }
        return true
    }

    private static func shape(_ key: String) -> Failure {
        .unreadable("settings.json has a \"\(key)\" Noodle doesn't recognize, so it left the file alone.")
    }
}

// MARK: Order-preserving JSON

/// Just enough JSON to edit settings.json without reshuffling it: objects keep their key order, and
/// numbers and strings keep their original spelling. Prints the way `jq .` does.
enum JSON: Equatable {
    case object([(String, JSON)])
    case array([JSON])
    case string(String, raw: String? = nil)
    case number(String)
    case bool(Bool)
    case null

    static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case (.object(let x), .object(let y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.array(let x), .array(let y)): return x == y
        case (.string(let x, _), .string(let y, _)): return x == y
        case (.number(let x), .number(let y)): return x == y
        case (.bool(let x), .bool(let y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    var isNull: Bool { if case .null = self { return true } else { return false } }
    var isObject: Bool { if case .object = self { return true } else { return false } }
    var isArray: Bool { if case .array = self { return true } else { return false } }
    var string: String? { if case .string(let s, _) = self { return s } else { return nil } }

    /// Object member, or nil. Setting nil deletes; setting a new key appends it, like jq.
    subscript(key: String) -> JSON? {
        get {
            guard case .object(let pairs) = self else { return nil }
            return pairs.first { $0.0 == key }?.1
        }
        set {
            guard case .object(var pairs) = self else { return }
            let i = pairs.firstIndex { $0.0 == key }
            switch (i, newValue) {
            case (let i?, let v?): pairs[i].1 = v
            case (let i?, nil): pairs.remove(at: i)
            case (nil, let v?): pairs.append((key, v))
            case (nil, nil): break
            }
            self = .object(pairs)
        }
    }

    // MARK: Printing

    func pretty(indent: String = "  ") -> String {
        var out = ""
        write(&out, indent: indent, depth: 0)
        return out
    }

    private func write(_ out: inout String, indent: String, depth: Int) {
        let pad = String(repeating: indent, count: depth + 1), end = String(repeating: indent, count: depth)
        switch self {
        case .object(let pairs):
            if pairs.isEmpty { out += "{}"; return }
            out += "{\n"
            for (k, (key, value)) in pairs.enumerated() {
                out += pad + Self.quote(key) + ": "
                value.write(&out, indent: indent, depth: depth + 1)
                out += k < pairs.count - 1 ? ",\n" : "\n"
            }
            out += end + "}"
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[\n"
            for (k, value) in items.enumerated() {
                out += pad
                value.write(&out, indent: indent, depth: depth + 1)
                out += k < items.count - 1 ? ",\n" : "\n"
            }
            out += end + "]"
        case .string(let s, let raw): out += raw ?? Self.quote(s)
        case .number(let n): out += n
        case .bool(let b): out += b ? "true" : "false"
        case .null: out += "null"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 || u.value == 0x7F { out += String(format: "\\u%04x", u.value) }
                else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    /// The file's own indent (first indented line), so a 4-space or tab file stays that way. jq's 2 otherwise.
    static func indent(of text: String) -> String {
        for line in text.split(separator: "\n").dropFirst() {
            let lead = line.prefix { $0 == " " || $0 == "\t" }
            if !lead.isEmpty { return lead.allSatisfy { $0 == "\t" } ? "\t" : String(lead) }
        }
        return "  "
    }

    // MARK: Parsing

    static func parse(_ text: String) -> JSON? {
        var p = Parser(bytes: Array(text.utf8))
        guard let v = p.value() else { return nil }
        p.skipSpace()
        return p.i == p.bytes.count ? v : nil
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0
        var depth = 0

        mutating func skipSpace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        mutating func value() -> JSON? {
            skipSpace()
            guard i < bytes.count, depth < 512 else { return nil }
            switch bytes[i] {
            case UInt8(ascii: "{"): return object()
            case UInt8(ascii: "["): return array()
            case UInt8(ascii: "\""):
                let start = i
                guard let s = string() else { return nil }
                return .string(s, raw: String(decoding: bytes[start..<i], as: UTF8.self))
            case UInt8(ascii: "t"): return word("true", .bool(true))
            case UInt8(ascii: "f"): return word("false", .bool(false))
            case UInt8(ascii: "n"): return word("null", .null)
            default: return number()
            }
        }

        mutating func word(_ w: String, _ v: JSON) -> JSON? {
            let u = Array(w.utf8)
            guard i + u.count <= bytes.count, Array(bytes[i..<i + u.count]) == u else { return nil }
            i += u.count
            return v
        }

        mutating func number() -> JSON? {
            let start = i
            func digits() -> Bool {
                let s = i
                while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
                return i > s
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard digits() else { return nil }
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") { i += 1; guard digits() else { return nil } }
            if i < bytes.count, bytes[i] | 0x20 == UInt8(ascii: "e") {
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
                guard digits() else { return nil }
            }
            return .number(String(decoding: bytes[start..<i], as: UTF8.self))
        }

        mutating func string() -> String? {
            i += 1   // opening quote
            var out = ""
            var units: [UInt16] = []   // from \u escapes, decoded together so surrogate pairs join up
            var run = i                // start of the current unescaped stretch
            while i < bytes.count {
                let c = bytes[i]
                if c < 0x20 { return nil }
                if c != UInt8(ascii: "\"") && c != UInt8(ascii: "\\") { i += 1; continue }
                if run < i || c == UInt8(ascii: "\"") {
                    if !units.isEmpty { out += String(decoding: units, as: UTF16.self); units = [] }
                    out += String(decoding: bytes[run..<i], as: UTF8.self)
                }
                i += 1
                if c == UInt8(ascii: "\"") { return out }
                guard i < bytes.count else { return nil }
                let e = bytes[i]
                i += 1
                if e == UInt8(ascii: "u") {
                    guard i + 4 <= bytes.count,
                          let u = UInt16(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16) else { return nil }
                    units.append(u)
                    i += 4
                } else {
                    if !units.isEmpty { out += String(decoding: units, as: UTF16.self); units = [] }
                    switch e {
                    case UInt8(ascii: "\""): out += "\""
                    case UInt8(ascii: "\\"): out += "\\"
                    case UInt8(ascii: "/"): out += "/"
                    case UInt8(ascii: "b"): out += "\u{08}"
                    case UInt8(ascii: "f"): out += "\u{0C}"
                    case UInt8(ascii: "n"): out += "\n"
                    case UInt8(ascii: "r"): out += "\r"
                    case UInt8(ascii: "t"): out += "\t"
                    default: return nil
                    }
                }
                run = i
            }
            return nil
        }

        mutating func array() -> JSON? {
            i += 1; depth += 1; defer { depth -= 1 }
            var items: [JSON] = []
            skipSpace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                guard let v = value() else { return nil }
                items.append(v)
                skipSpace()
                guard i < bytes.count else { return nil }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                return nil
            }
        }

        mutating func object() -> JSON? {
            i += 1; depth += 1; defer { depth -= 1 }
            var obj = JSON.object([])
            skipSpace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return obj }
            while true {
                skipSpace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\""), let key = string() else { return nil }
                skipSpace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return nil }
                i += 1
                guard let v = value() else { return nil }
                obj[key] = v   // a repeated key keeps its first spot and takes the last value, like jq
                skipSpace()
                guard i < bytes.count else { return nil }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return obj }
                return nil
            }
        }
    }
}
