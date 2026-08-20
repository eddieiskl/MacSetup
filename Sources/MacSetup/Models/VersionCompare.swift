import Foundation

/// Version comparison that refuses to guess.
///
/// Mac version strings are a zoo — `0.98`, `16.112.26081720`, `4.51.191`,
/// `2024.3-beta`, `v1.2.3`. Claiming an update that is not really newer is worse
/// than saying nothing, so anything ambiguous comes back as `.incomparable`.
enum VersionOrder {
    case older, same, newer, incomparable
}

enum VersionCompare {

    /// Pulls a comparable version out of a filename or tag.
    /// `Rectangle0.98.dmg` -> `0.98`, `v1.4.9` -> `1.4.9`.
    static func extract(from text: String) -> String? {
        let pattern = #"(\d+(?:\.\d+){1,4})"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        // Prefer the longest run of dotted numbers — filenames often carry a
        // build id too, and the longest match is the fuller version.
        var best: String?
        for m in re.matches(in: text, range: range) {
            guard let r = Range(m.range(at: 1), in: text) else { continue }
            let candidate = String(text[r])
            if best == nil || candidate.count > best!.count { best = candidate }
        }
        return best
    }

    /// Every run of digits, in order. `7.1.5 (84650)` and `7.1.5.84650` both
    /// become [7,1,5,84650] — the same release written two different ways, which
    /// a dotted-only parse would report as an upgrade.
    static func normalise(_ raw: String) -> [Int]? {
        var out: [Int] = []
        var digits = ""
        for ch in raw {
            if ch.isNumber {
                digits.append(ch)
            } else if !digits.isEmpty {
                if let n = Int(digits) { out.append(n) }
                digits = ""
            }
        }
        if !digits.isEmpty, let n = Int(digits) { out.append(n) }
        return out.isEmpty ? nil : out
    }

    static func compare(installed: String, latest: String) -> VersionOrder {
        guard let a = normalise(installed), let b = normalise(latest) else { return .incomparable }

        // Wildly different shapes are usually different versioning schemes
        // rather than a real upgrade.
        if abs(a.count - b.count) > 2 { return .incomparable }

        // One being a prefix of the other means every component they share is
        // equal, and the longer string simply carries more precision — a build
        // number the app bundle does not report. OneDrive installs as
        // 26.139.0720.0007 but reports 26.139.0720, so treating the extra
        // component as "newer" flagged an update that would never go away.
        let shared = min(a.count, b.count)
        if Array(a.prefix(shared)) == Array(b.prefix(shared)) { return .same }

        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x == y { continue }
            // A component of 1 against one of 26081720 is a build stamp meeting a
            // point release, not an upgrade. Refuse rather than invent one.
            if x != 0, y != 0, abs(String(x).count - String(y).count) >= 3 {
                return .incomparable
            }
            return x < y ? .newer : .older
        }
        return .same
    }
}
