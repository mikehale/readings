import Foundation

/// Normalizes PDFKit-extracted chapter text before preview / TTS.
///
/// PDF ornamental headings often arrive letter-spaced (`CH A P T ER 1`,
/// `I n t r o d u c ti o n`) plus stray single-glyph lines (`w`) that edge-tts
/// then spells out literally. Soft line-wrap newlines mid-paragraph also make
/// the voice pause; those are reflowed into spaces while blank lines stay as
/// paragraph breaks.
enum ChapterTextCleaner {
    static func clean(_ raw: String) -> String {
        let unified = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = unified.split(separator: "\n", omittingEmptySubsequences: false)
            .map { cleanLine(String($0)) }

        var paragraphs: [[String]] = [[]]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if let last = paragraphs.last, !last.isEmpty {
                    paragraphs.append([])
                }
                continue
            }
            if isJunkSingletonGlyph(trimmed) { continue }
            if isPageNumberMarker(trimmed) { continue }
            paragraphs[paragraphs.count - 1].append(trimmed)
        }

        let reflowed = paragraphs
            .filter { !$0.isEmpty }
            .map { reflowParagraph($0) }
            .joined(separator: "\n\n")

        return reflowed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Collapse letter-spaced ornamental lines; leave normal prose alone.
    static func cleanLine(_ line: String) -> String {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        // Drop leading running page markers: "( 2 ) National Security…" → "National Security…"
        trimmed = trimmed.replacingOccurrences(
            of: #"^\(\s*\d+\s*\)\s*"#,
            with: "",
            options: .regularExpression
        )
        guard !trimmed.isEmpty else { return "" }
        return collapseLetterSpacedHeading(trimmed)
    }

    /// Join wrapped PDF lines into one prose paragraph; keep hyphenated wraps seamless.
    static func reflowParagraph(_ lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        var result = lines[0]
        for next in lines.dropFirst() {
            if result.hasSuffix("-"),
               let last = result.last,
               last == "-",
               let before = result.dropLast().last,
               before.isLetter,
               let first = next.first,
               first.isLetter
            {
                // `admin-` + `istration` → `administration`
                result = String(result.dropLast()) + next
            } else {
                result += " " + next
            }
        }
        return result
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// True for a lone letter/glyph line such as `w` (common PDF extraction junk).
    static func isJunkSingletonGlyph(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.trimmingCharacters(in: .punctuationCharacters)
            .trimmingCharacters(in: .whitespaces)
        guard stripped.count == 1, let ch = stripped.first, ch.isLetter else {
            return false
        }
        // Keep meaningful one-letter words that can appear alone.
        let keep: Set<Character> = ["A", "a", "I", "O"]
        return !keep.contains(ch)
    }

    /// Running footer/header page markers like `( 1 )` or `(1)`.
    static func isPageNumberMarker(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(
            of: #"^\(\s*\d+\s*\)$"#,
            options: .regularExpression
        ) != nil
    }

    /// Detects lines whose alphabetic tokens are all ≤2 chars (e.g. `CH A P T ER 1`,
    /// `I n t r o d u c ti o n ( 3 )`) and joins them into normal words.
    static func collapseLetterSpacedHeading(_ line: String) -> String {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 3 else { return line }

        let letterTokens = tokens.filter { $0.unicodeScalars.allSatisfy(CharacterSet.letters.contains) }
        guard letterTokens.count >= 3,
              letterTokens.allSatisfy({ $0.count <= 2 })
        else {
            return line
        }

        var assembled = ""
        for token in tokens {
            if token.unicodeScalars.allSatisfy(CharacterSet.letters.contains) {
                assembled += token
            } else if token.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains) {
                if !assembled.isEmpty, assembled.last != " ", assembled.last != "(" {
                    assembled += " "
                }
                assembled += token
            } else if token == "(" {
                if !assembled.isEmpty, assembled.last != " " {
                    assembled += " "
                }
                assembled += "("
            } else if token == ")" {
                assembled += ")"
            } else {
                // Mixed punctuation token such as "(3)" or "1."
                if !assembled.isEmpty, assembled.last != " ", assembled.last != "(" {
                    assembled += " "
                }
                assembled += token
            }
        }

        assembled = assembled
            .replacingOccurrences(of: "\\(\\s+", with: "(", options: .regularExpression)
            .replacingOccurrences(of: "\\s+\\)", with: ")", options: .regularExpression)
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        return titleCaseIfShouting(assembled)
    }

    /// `CHAPTER 1` → `Chapter 1` when the alphabetic content is all caps.
    private static func titleCaseIfShouting(_ value: String) -> String {
        let letters = value.filter(\.isLetter)
        guard !letters.isEmpty, letters.allSatisfy(\.isUppercase) else {
            return value
        }
        return value.lowercased().capitalized
    }
}
