import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Cleans raw Whisper transcripts per `CleanupMode`. Never throws — the `ai`
/// mode always falls back to the `rules` output on any failure/timeout/
/// unavailability. See Contracts.swift for the frozen public shape.
final class TextCleaner {
    private let logger = Logger(subsystem: "com.voxflow.app", category: "TextCleaner")

    /// How long we allow the on-device model to respond before giving up and
    /// falling back to the rules-cleaned text.
    private static let aiTimeoutNanoseconds: UInt64 = 25_000_000_000

    func clean(_ raw: String, appBundleID: String?, mode: CleanupMode) async -> String {
        switch mode {
        case .off:
            return raw
        case .rules:
            return Self.applyRules(raw)
        case .ai:
            let rulesOutput = Self.applyRules(raw)
            guard !rulesOutput.isEmpty else { return rulesOutput }
            // Fast path: very short utterances gain nothing from the LLM pass —
            // rules output is already clean and this makes them feel instant.
            let wordCount = rulesOutput.split(whereSeparator: { $0.isWhitespace }).count
            if wordCount <= 4 { return rulesOutput }
            return await applyAI(rulesOutput, appBundleID: appBundleID)
        }
    }

    /// Eagerly loads the on-device model at app launch so the first real
    /// cleanup doesn't pay the cold-start cost. Safe no-op when Apple
    /// Intelligence is unavailable.
    func prewarmAI() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return }
            let session = LanguageModelSession(instructions: Self.buildInstructions(appBundleID: nil))
            session.prewarm()
            logger.info("FoundationModels prewarm requested")
        }
        #endif
    }

    // MARK: - AI pass (Apple Intelligence / FoundationModels)

    private func applyAI(_ rulesText: String, appBundleID: String?) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if let result = await Self.runFoundationModelCleanup(rulesText, appBundleID: appBundleID, logger: logger) {
                return result
            }
        }
        #endif
        return rulesText
    }

    // MARK: - Rules pass

    /// Ordered, conservative regex/text pipeline:
    /// 1. strip standalone filler words (um/uh/uhh/er/erm)
    /// 2. strip "you know" only when used as a comma-delimited interjection
    /// 3. collapse immediate word repeats ("the the" -> "the")
    /// 4. spoken commands "new line" / "new paragraph" -> line breaks
    /// 5. normalize whitespace
    /// 6. fix spacing around punctuation
    /// 7. sentence-break sanity → run-on splitter → sanity again (see
    ///    `PunctuationSanity` / `RunOnSplitter`; same order as Windows)
    /// 8. collapse the doubled word a joined restart leaves behind
    /// 9. capitalize sentence starts
    /// 10. ensure terminal punctuation for multi-word output
    static func applyRules(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        text = stripStandaloneFillers(text)
        text = stripYouKnowInterjection(text)
        text = collapseRepeatedWords(text)
        text = applySpokenCommands(text)
        text = normalizeWhitespace(text)
        text = fixSpaceBeforePunctuation(text)
        // Sanity first resolves whisper's provisional segment breaks, so the
        // splitter sees the true run-ons; sanity again vets the splitter.
        text = PunctuationSanity.apply(text)
        text = RunOnSplitter.split(text)
        text = PunctuationSanity.apply(text)
        // A joined restart ("the. The goal") leaves a doubled word.
        text = collapseRepeatedWords(text)
        text = replacing(text, pattern: #"[ \t]+"#, with: " ")
        text = capitalizeSentences(text)
        text = ensureTerminalPunctuation(text)
        return text
    }

    private static func stripStandaloneFillers(_ text: String) -> String {
        // Whole-word, case-insensitive. Swallow a trailing comma so
        // "um, so" doesn't leave a dangling comma behind.
        replacing(text, pattern: #"(?i)\b(um|uh|uhh|er|erm)\b,?"#, with: "")
    }

    private static func stripYouKnowInterjection(_ text: String) -> String {
        var t = text
        // ", you know," -> "," (interjection in the middle of a sentence).
        t = replacing(t, pattern: #"(?i),\s*you know\s*,"#, with: ",")
        // ", you know" at the end of a clause/sentence -> drop it entirely.
        t = replacing(t, pattern: #"(?i),\s*you know\b"#, with: "")
        return t
    }

    private static func collapseRepeatedWords(_ text: String) -> String {
        replacing(text, pattern: #"(?i)\b(\w+)\b(\s+\1\b)+"#, with: "$1")
    }

    private static func applySpokenCommands(_ text: String) -> String {
        var t = text
        // "new paragraph" before "new line" since it's the more specific phrase.
        t = replacing(t, pattern: #"(?i)[,.]?\s*\bnew paragraph\b[,.]?"#, with: "\n\n")
        t = replacing(t, pattern: #"(?i)[,.]?\s*\bnew line\b[,.]?"#, with: "\n")
        return t
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        var t = replacing(text, pattern: #"[ \t]+"#, with: " ")
        t = replacing(t, pattern: #" *\n *"#, with: "\n")
        t = replacing(t, pattern: #"\n{3,}"#, with: "\n\n")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fixSpaceBeforePunctuation(_ text: String) -> String {
        var t = replacing(text, pattern: #"[ \t]+([,.!?;:])"#, with: "$1")
        // Ensure a single space follows punctuation when immediately glued to a
        // letter/digit. Periods are handled separately so decimals ("3.5") and
        // abbreviations ("e.g.", "U.S.") survive untouched.
        t = replacing(t, pattern: #"([,!?;:])(?=[A-Za-z0-9])"#, with: "$1 ")
        t = replacing(t, pattern: #"(?<=[A-Za-z]{2})\.(?=[A-Za-z])"#, with: ". ")
        return t
    }

    private static func capitalizeSentences(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = String()
        result.reserveCapacity(text.count)
        var capitalizeNext = true
        for ch in text {
            if capitalizeNext, ch.isLetter {
                result.append(contentsOf: ch.uppercased())
                capitalizeNext = false
                continue
            }
            result.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                capitalizeNext = true
            } else if !ch.isWhitespace {
                capitalizeNext = false
            }
        }
        return result
    }

    private static func ensureTerminalPunctuation(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let wordCount = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        guard wordCount >= 3 else { return trimmed }
        if let last = trimmed.last, ".!?".contains(last) {
            return trimmed
        }
        return trimmed + "."
    }

    private static func replacing(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
private enum TextCleanerAIError: Error {
    case timeout
}

@available(macOS 26.0, *)
extension TextCleaner {
    fileprivate static func runFoundationModelCleanup(
        _ text: String,
        appBundleID: String?,
        logger: Logger
    ) async -> String? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            logger.notice("FoundationModels unavailable, falling back to rules output.")
            return nil
        }

        let instructions = buildInstructions(appBundleID: appBundleID)

        do {
            let response: String = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    // Use the plain-String `instructions:`/`respond(to:)`
                    // overloads rather than the result-builder forms — both are
                    // documented on LanguageModelSession and unambiguous here.
                    let session = LanguageModelSession(instructions: instructions)
                    let result = try await session.respond(to: text)
                    return result.content
                }
                group.addTask { () async throws -> String in
                    try await Task.sleep(nanoseconds: aiTimeoutNanoseconds)
                    throw TextCleanerAIError.timeout
                }
                guard let first = try await group.next() else {
                    throw TextCleanerAIError.timeout
                }
                group.cancelAll()
                return first
            }
            let cleaned = stripSurroundingQuotes(response)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            logger.notice("FoundationModels cleanup failed/timed out, falling back to rules output: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    fileprivate static func buildInstructions(appBundleID: String?) -> String {
        var lines = [
            "You are a dictation cleanup engine.",
            "Fix grammar, punctuation, and capitalization in the user's spoken text.",
            "Remove filler words and false starts.",
            "NEVER add new information, invent content, or change the meaning of the text.",
            "Output ONLY the cleaned text with no preamble, labels, explanations, or surrounding quotes."
        ]

        if let bundleID = appBundleID?.lowercased() {
            if bundleID.contains("mail") {
                lines.append("The destination app is an email client: write in complete, well-formed sentences.")
            } else if bundleID.contains("slack") || bundleID.contains("messages") || bundleID.contains("discord") {
                lines.append("The destination app is a casual chat app: keep the tone casual and conversational.")
            } else if bundleID.contains("com.microsoft.vscode")
                || bundleID.contains("com.apple.dt.xcode")
                || bundleID.contains("terminal")
                || bundleID.contains("iterm") {
                lines.append("The destination app is a code editor or terminal: do not add a trailing period, and preserve technical terms, identifiers, and code verbatim.")
            }
        }

        return lines.joined(separator: " ")
    }

    fileprivate static func stripSurroundingQuotes(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}"), ("'", "'")]
        for (open, close) in quotePairs {
            if t.count > 1, t.first == open, t.last == close {
                t.removeFirst()
                t.removeLast()
                t = t.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return t
    }
}
#endif
