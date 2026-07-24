import Foundation

public enum OutputPolicy: String, Codable, Sendable {
    case preserveMixed, gujaratiScript, bapsRoman
}

/// Renders corrected text under a selectable output policy. `.preserveMixed`
/// is the default and returns text unchanged. The Roman/Gujarati-script
/// policies only replace text when the pack provides a reviewed output form
/// for the matched entry; otherwise the input is preserved untouched. This
/// is deliberately safe degradation, not a general transliteration engine.
public struct OutputRenderer: Sendable {
    private let pack: TerminologyPack

    public init(pack: TerminologyPack) {
        self.pack = pack
    }

    public func render(_ text: String, policy: OutputPolicy) throws -> String {
        switch policy {
        case .preserveMixed:
            return text
        case .gujaratiScript:
            return renderGujaratiScript(text)
        case .bapsRoman:
            return renderBapsRoman(text)
        }
    }

    /// Replaces recognised Roman pack terms with their reviewed Gujarati
    /// script form. Matching is whole-word and case-insensitive so partial
    /// token overlaps never fire, and the longest phrase always wins.
    private func renderGujaratiScript(_ text: String) -> String {
        struct Rule {
            let phrase: String
            let replacement: String
            let regex: NSRegularExpression
        }

        var rules: [Rule] = []
        for entry in pack.entries {
            guard let gujarati = entry.outputForms["gujaratiScript"] else { continue }
            for phrase in [entry.canonical] + entry.aliases {
                let escaped = NSRegularExpression.escapedPattern(for: phrase)
                guard
                    let regex = try? NSRegularExpression(
                        pattern: "\\b\(escaped)\\b", options: [.caseInsensitive]
                    )
                else { continue }
                rules.append(Rule(phrase: phrase, replacement: gujarati, regex: regex))
            }
        }
        rules.sort { $0.phrase.count > $1.phrase.count }

        struct Match {
            let range: Range<String.Index>
            let replacement: String
        }

        var matches: [Match] = []
        let fullRange = NSRange(text.startIndex..., in: text)
        for rule in rules {
            rule.regex.enumerateMatches(in: text, options: [], range: fullRange) { result, _, _ in
                guard let result, let range = Range(result.range, in: text) else { return }
                matches.append(Match(range: range, replacement: rule.replacement))
            }
        }
        matches.sort { lhs, rhs in
            let lhsLength = text.distance(from: lhs.range.lowerBound, to: lhs.range.upperBound)
            let rhsLength = text.distance(from: rhs.range.lowerBound, to: rhs.range.upperBound)
            if lhsLength != rhsLength { return lhsLength > rhsLength }
            return lhs.range.lowerBound < rhs.range.lowerBound
        }

        var accepted: [Match] = []
        for match in matches where !accepted.contains(where: { $0.range.overlaps(match.range) }) {
            accepted.append(match)
        }
        accepted.sort { $0.range.lowerBound > $1.range.lowerBound }

        var result = text
        for match in accepted {
            result.replaceSubrange(match.range, with: match.replacement)
        }
        return result
    }

    /// Replaces known Gujarati-script spans with their reviewed Roman form.
    /// Uses literal substring matching rather than word-boundary regex:
    /// Gujarati conjuncts and matras make boundary detection unreliable at
    /// this stage, so this is safe degradation, not a Unicode syllable
    /// walker. Longest phrase first avoids partial overlap between entries.
    private func renderBapsRoman(_ text: String) -> String {
        var rules: [(phrase: String, replacement: String)] = []
        for entry in pack.entries {
            guard let gujarati = entry.outputForms["gujaratiScript"],
                let bapsRoman = entry.outputForms["bapsRoman"]
            else { continue }
            rules.append((gujarati, bapsRoman))
        }
        rules.sort { $0.phrase.count > $1.phrase.count }

        var result = text
        for rule in rules {
            while let range = result.range(of: rule.phrase) {
                result.replaceSubrange(range, with: rule.replacement)
            }
        }
        return result
    }
}
