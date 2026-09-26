import Foundation

/// Whether one tweak's `defaults write` statements match what's actually set.
public struct TweakComplianceResult {
    public let tweakID: String
    public let status: ComplianceStatus
    public let detail: String

    public init(tweakID: String, status: ComplianceStatus, detail: String) {
        self.tweakID = tweakID
        self.status = status
        self.detail = detail
    }
}

/// Every catalogue tweak today is one or more `defaults write <domain> <key>
/// -<type> <value>` statements, joined with `;` (confirmed against the
/// current catalogue: 17 of 18 are exactly that, and the 18th differs only by
/// an extra `mkdir -p` line ahead of its `defaults write`). That shape is
/// generic and mechanical enough to read back with `defaults read` and
/// compare — something the catalogue has never needed before because tweaks
/// were apply-only.
///
/// Anything that doesn't parse as pure `defaults write` statements, or that
/// `defaults read` can't answer cleanly, comes back `.unknown` — never a
/// guessed compliant/different.
public enum TweakComplianceProbe {

    public struct Assignment {
        let domain: String
        let key: String
        let type: String
        let expected: String
    }

    public static func check(_ tweak: DefaultTweak) -> TweakComplianceResult {
        guard let assignments = parse(tweak.command), !assignments.isEmpty else {
            return TweakComplianceResult(tweakID: tweak.id, status: .unknown,
                                         detail: "This tweak isn't a plain defaults-write statement, so its current value can't be read back safely.")
        }

        var mismatches: [String] = []
        for a in assignments {
            guard let actual = readDefault(domain: a.domain, key: a.key) else {
                return TweakComplianceResult(tweakID: tweak.id, status: .unknown,
                                             detail: "Could not read \(a.domain) \(a.key).")
            }
            if !matches(actual: actual, expected: a.expected, type: a.type) {
                mismatches.append("\(a.key) is \(actual), expected \(a.expected)")
            }
        }

        if mismatches.isEmpty {
            return TweakComplianceResult(tweakID: tweak.id, status: .compliant, detail: "Matches the desired state.")
        }
        return TweakComplianceResult(tweakID: tweak.id, status: .different,
                                     detail: mismatches.joined(separator: "; "))
    }

    // MARK: - Parsing

    /// Splits `command` on `;` and matches each non-empty segment against
    /// `defaults write <domain> <key> -<type> <value>`. A single non-matching
    /// segment (e.g. the `mkdir -p` prefix some tweaks carry) fails the whole
    /// parse — this only ever handles tweaks that are *purely* defaults writes.
    public static func parse(_ command: String) -> [Assignment]? {
        let segments = command.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !segments.isEmpty else { return nil }

        var out: [Assignment] = []
        for segment in segments {
            guard let a = parseSingle(segment) else { return nil }
            out.append(a)
        }
        return out
    }

    private static func parseSingle(_ segment: String) -> Assignment? {
        // defaults write <domain> <key> -<type> <value...>
        // <domain>/<key> are single tokens; <value> is everything after the
        // type flag, so a quoted string with spaces still works.
        let pattern = #"^defaults write (\S+) (\S+) -(\w+) (.+)$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(segment.startIndex..., in: segment)
        guard let m = re.firstMatch(in: segment, range: range), m.numberOfRanges == 5 else { return nil }
        func group(_ i: Int) -> String {
            guard let r = Range(m.range(at: i), in: segment) else { return "" }
            return String(segment[r])
        }
        var value = group(4).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return Assignment(domain: group(1), key: group(2), type: group(3), expected: value)
    }

    // MARK: - Reading

    private static func readDefault(domain: String, key: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = ["read", domain, key]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(actual: String, expected: String, type: String) -> Bool {
        switch type {
        case "bool", "boolean":
            let a = normaliseBool(actual)
            let e = normaliseBool(expected)
            return a != nil && a == e
        case "int", "integer", "float":
            return Double(actual) == Double(expected)
        default:
            return actual == expected
        }
    }

    private static func normaliseBool(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: return nil
        }
    }
}
