import Foundation

public struct AppliedCorrection: Codable, Equatable, Sendable {
    public let original: String
    public let replacement: String
    public let entryCanonical: String
    public let rule: String

    public init(original: String, replacement: String, entryCanonical: String, rule: String) {
        self.original = original
        self.replacement = replacement
        self.entryCanonical = entryCanonical
        self.rule = rule
    }
}

public struct CorrectionResult: Codable, Equatable, Sendable {
    public let text: String
    public let corrections: [AppliedCorrection]

    public init(text: String, corrections: [AppliedCorrection]) {
        self.text = text
        self.corrections = corrections
    }
}

/// Applies exact and alias-based deterministic terminology corrections.
///
/// Matching is case-insensitive on Unicode word boundaries so a phrase is
/// never replaced inside a larger token. Longer phrases always win over
/// shorter overlapping phrases so multi-word canonical terms are corrected
/// as a whole. Fuzzy/phonetic matching is deferred to a later plan.
public struct CorrectionEngine: Sendable {
    private struct Rule {
        let phrase: String
        let canonical: String
        let regex: NSRegularExpression
    }

    private let rules: [Rule]

    public init(pack: TerminologyPack) {
        var seenPhrases: Set<String> = []
        var builtRules: [Rule] = []
        for entry in pack.entries {
            for phrase in [entry.canonical] + entry.aliases {
                let key = phrase.folding(options: .caseInsensitive, locale: nil)
                guard !seenPhrases.contains(key) else { continue }
                seenPhrases.insert(key)
                let escaped = NSRegularExpression.escapedPattern(for: phrase)
                guard
                    let regex = try? NSRegularExpression(
                        pattern: "\\b\(escaped)\\b", options: [.caseInsensitive]
                    )
                else { continue }
                builtRules.append(Rule(phrase: phrase, canonical: entry.canonical, regex: regex))
            }
        }
        // Longest phrase first; ties broken lexicographically for determinism.
        self.rules = builtRules.sorted { lhs, rhs in
            if lhs.phrase.count != rhs.phrase.count {
                return lhs.phrase.count > rhs.phrase.count
            }
            return lhs.phrase < rhs.phrase
        }
    }

    public func correct(_ text: String) -> CorrectionResult {
        let normalized = text.precomposedStringWithCanonicalMapping

        struct Match {
            let range: Range<String.Index>
            let canonical: String
        }

        var matches: [Match] = []
        let fullRange = NSRange(normalized.startIndex..., in: normalized)
        for rule in rules {
            rule.regex.enumerateMatches(in: normalized, options: [], range: fullRange) { result, _, _ in
                guard let result, let range = Range(result.range, in: normalized) else { return }
                matches.append(Match(range: range, canonical: rule.canonical))
            }
        }

        // Longest match wins; ties broken by earliest start for determinism.
        matches.sort { lhs, rhs in
            let lhsLength = normalized.distance(from: lhs.range.lowerBound, to: lhs.range.upperBound)
            let rhsLength = normalized.distance(from: rhs.range.lowerBound, to: rhs.range.upperBound)
            if lhsLength != rhsLength {
                return lhsLength > rhsLength
            }
            return lhs.range.lowerBound < rhs.range.lowerBound
        }

        var accepted: [Match] = []
        for match in matches where !accepted.contains(where: { $0.range.overlaps(match.range) }) {
            accepted.append(match)
        }

        // Apply right-to-left so earlier ranges remain valid indices into `result`.
        accepted.sort { $0.range.lowerBound > $1.range.lowerBound }

        var result = normalized
        var corrections: [AppliedCorrection] = []
        for match in accepted {
            let original = String(result[match.range])
            guard original != match.canonical else { continue }
            result.replaceSubrange(match.range, with: match.canonical)
            corrections.append(
                AppliedCorrection(
                    original: original,
                    replacement: match.canonical,
                    entryCanonical: match.canonical,
                    rule: "exactPhrase"
                )
            )
        }

        // Corrections were collected right-to-left; present them in reading order.
        corrections.reverse()

        return CorrectionResult(text: result, corrections: corrections)
    }
}
