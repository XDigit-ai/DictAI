import Foundation

/// Cleans transcript text without rewording it. The four rules and their
/// exceptions are defined in the call transcripts spec, section "TranscriptCleaner".
nonisolated enum TranscriptCleaner {

    static func clean(_ text: String, confidence: Double? = nil) -> String {
        var s = removeJunk(text, confidence: confidence)
        s = removeFillers(s)
        s = collapseStutters(s)
        s = tidy(s)
        return s.contains(where: { $0.isLetter || $0.isNumber }) ? s : ""
    }

    // MARK: - Rule 1: junk

    private static let tagPattern = try! NSRegularExpression(
        pattern: #"[\[\(]\s*(?:blank_audio|music|noise|silence|applause|laughter|inaudible|[a-z ]*music)\s*[\]\)]"#,
        options: [.caseInsensitive]
    )
    private static let hallucinations: Set<String> = [
        "thanks for watching", "thank you for watching", "please subscribe", "like and subscribe",
    ]
    private static let lowConfidenceOnly: Set<String> = ["thank you", "bye"]

    static func removeJunk(_ text: String, confidence: Double?) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var s = tagPattern.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        s = collapseRepeatedSentences(s)
        let key = normalized(s)
        if hallucinations.contains(key) || key.hasPrefix("subtitles by") { return "" }
        if lowConfidenceOnly.contains(key), let confidence, confidence < 0.5 { return "" }
        return s
    }

    /// Reduces a run of 3 or more identical sentences to one. Returns the input
    /// untouched when there is no such run, so sentence splitting never alters text.
    static func collapseRepeatedSentences(_ text: String) -> String {
        let sentences = splitSentences(text)
        var out: [String] = []
        var changed = false
        var i = 0
        while i < sentences.count {
            var j = i + 1
            while j < sentences.count, normalized(sentences[j]) == normalized(sentences[i]) { j += 1 }
            if j - i >= 3 {
                out.append(sentences[i])
                changed = true
            } else {
                out.append(contentsOf: sentences[i..<j])
            }
            i = j
        }
        return changed ? out.joined(separator: " ") : text
    }

    private static let sentencePattern = try! NSRegularExpression(pattern: #"[^.!?]+[.!?]*"#)

    static func splitSentences(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return sentencePattern.matches(in: text, range: range)
            .compactMap { Range($0.range, in: text).map { text[$0].trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty }
    }

    /// Lowercased words only, for comparisons.
    static func normalized(_ s: String) -> String {
        let keep = CharacterSet.letters.union(.decimalDigits)
        let mapped = s.lowercased().unicodeScalars.map { keep.contains($0) || $0 == "'" ? Character($0) : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    // MARK: - Rule 2: fillers

    private static let fillerPattern = try! NSRegularExpression(pattern: #"^(?:u+m+|u+h+|e+r+m*|a+h+|h+m+)$"#)

    static func isFiller(_ word: String) -> Bool {
        let lower = word.lowercased()
        return fillerPattern.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil
    }

    static func removeFillers(_ text: String) -> String {
        var kept: [String] = []
        for token in text.split(separator: " ").map(String.init) {
            let parts = splitPunctuation(token)
            guard isFiller(parts.core) else {
                kept.append(token)
                continue
            }
            // Keep a filler's sentence-ending punctuation by moving it onto the previous word.
            if let end = parts.trailing.last(where: { ".!?".contains($0) }),
               let last = kept.last,
               let lastChar = last.last,
               !".!?,;:".contains(lastChar) {
                kept[kept.count - 1] = last + String(end)
            }
        }
        return kept.joined(separator: " ")
    }

    static func splitPunctuation(_ token: String) -> (leading: String, core: String, trailing: String) {
        let chars = Array(token)
        var start = 0
        var end = chars.count
        while start < end, !(chars[start].isLetter || chars[start].isNumber) { start += 1 }
        while end > start, !(chars[end - 1].isLetter || chars[end - 1].isNumber) { end -= 1 }
        return (String(chars[..<start]), String(chars[start..<end]), String(chars[end...]))
    }

    // MARK: - Rule 3: stutters

    private static let keepDoubles: Set<String> = ["that", "had"]

    static func collapseStutters(_ text: String) -> String {
        var tokens = text.split(separator: " ").map(String.init)
        var i = 0
        while i < tokens.count {
            var removed = false
            for n in stride(from: 3, through: 1, by: -1) where i + 2 * n <= tokens.count {
                let first = tokens[i..<(i + n)]
                // A block that ends a sentence is emphasis, not a stutter ("No. No.").
                if first.contains(where: { $0.last.map { ".!?".contains($0) } ?? false }) { continue }
                let a = first.map { splitPunctuation($0).core.lowercased() }
                let b = tokens[(i + n)..<(i + 2 * n)].map { splitPunctuation($0).core.lowercased() }
                guard a == b, !a.contains("") else { continue }
                if n == 1, keepDoubles.contains(a[0]) { continue }
                tokens.removeSubrange(i..<(i + n))
                removed = true
                break
            }
            if !removed { i += 1 }
        }
        return tokens.joined(separator: " ")
    }

    // MARK: - Rule 4: layout

    private static let spaceBeforePunctuation = try! NSRegularExpression(pattern: #"\s+([,.?!;:])"#)
    private static let sentenceStart = try! NSRegularExpression(pattern: #"(?:^|[.?!]\s+)([a-z])"#)

    static func tidy(_ text: String) -> String {
        var s = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        s = spaceBeforePunctuation.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
        // Punctuation orphaned at the start by an earlier removal: ", so we" -> "so we".
        while let first = s.first, ",;:".contains(first) {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespaces)
        }
        return capitalizeSentenceStarts(s)
    }

    static func capitalizeSentenceStarts(_ text: String) -> String {
        var result = text
        let matches = sentenceStart.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let r = Range(match.range(at: 1), in: result),
                  let whole = Range(match.range, in: text) else { continue }
            if whole.lowerBound != text.startIndex, endsWithAbbreviation(text[..<whole.lowerBound] + ".") {
                continue
            }
            result.replaceSubrange(r, with: result[r].uppercased())
        }
        return result
    }

    /// "the U.S." or "e.g." or "a." end in an abbreviation, not a sentence.
    static func endsWithAbbreviation(_ text: String) -> Bool {
        guard let word = text.split(separator: " ").last else { return false }
        let core = word.dropLast()                        // drop the final period
        return core.contains(".") || core.filter(\.isLetter).count == 1
    }
}
