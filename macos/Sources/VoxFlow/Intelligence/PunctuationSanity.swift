import Foundation

/// Final grammar-aware pass over the whole transcript. Every earlier layer
/// (whisper, segment-boundary breaks, the run-on splitter) is a guess about
/// where sentences end; this pass removes the guesses that cannot be right:
///  - a sentence never ends on a word that needs a continuation ("the",
///    "to", "whether", "and", "of", …) — that break is a hesitation, so join;
///  - a one-word "sentence" that is not an interjection ("Okay.", "Go!",
///    "Fine.") is a fragment — fold it into the previous sentence;
///  - a sentence never starts with "or"/"nor" — join.
/// Joining a false break that was a restart ("the. The goal") leaves a
/// doubled word, which the cleaner's repeat rule then collapses.
///
/// Same rules as the Windows build's `PunctuationSanity.cs`; keep the two in
/// step when tuning.
enum PunctuationSanity {
    /// Provisional sentence break written by the inference layers (segment
    /// join, run-on splitter). Unlike a period whisper wrote itself, it must
    /// pass the strict test below to become a '.'; otherwise it is removed.
    static let inferredBreak: Character = "§"

    /// Words an *inferred* sentence may not end on — far broader than the
    /// list for whisper's own periods. "I think so." and "Make sure." are real
    /// sentences when whisper heard them end; when a segment merely happened
    /// to split after "so" or "sure", they are almost always mid-sentence.
    private static let strictNonTerminal: Set<String> = [
        // Connectives and adverbs that lead into what follows.
        "so", "then", "like", "just", "still", "even", "well", "maybe", "also", "too", "again",
        "including", "especially", "basically", "actually", "literally", "honestly", "really",
        "very", "pretty", "quite", "kind", "sort", "sure",
        // Verbs that need a complement ("make sure", "I think", "you want").
        // ("just do it.", "that's all I have.", "what I got." are real ends,
        // so do/have/got/made stay off this list.)
        "mean", "think", "thought", "know", "guess", "make", "makes", "go", "goes", "went",
        "get", "gets", "say", "says", "said", "want", "wants", "wanted", "need", "needs",
        "needed", "let", "let's", "keep", "keeps", "kept", "put", "puts", "give", "gives", "gave",
        "seem", "seems", "seemed", "become", "became",
        // Auxiliaries, modals, negations.
        "is", "are", "was", "were", "be", "been", "being", "am",
        "will", "would", "could", "should", "can", "may", "might", "must", "shall", "not",
        "don't", "doesn't", "didn't", "isn't", "aren't", "wasn't", "weren't", "can't", "couldn't",
        "wouldn't", "shouldn't", "won't", "haven't", "hasn't", "hadn't",
        // Subjects and determiners that start a clause.
        "he", "she", "they", "we", "you", "who", "what", "where", "when", "how", "why", "each",
        "both", "either", "some", "any", "every", "no",
        // Prepositions.
        "in", "on", "at", "by", "about", "over", "into", "onto", "through", "under", "between",
    ]
    private static let strictMinWords = 4

    /// A connective at the end of an inferred sentence usually opens the next
    /// one: "…push to GitHub etc so§ Here's the take" → "…etc. So here's the take".
    private static let leadsNextSentence: Set<String> = [
        "so", "then", "also", "anyway", "anyways", "basically", "honestly", "otherwise", "again",
    ]

    /// Words a sentence cannot end on.
    private static let nonTerminal: Set<String> = [
        // Only words that genuinely need a continuation. "I like that.",
        // "I think so.", "Do this.", "I can't." are all real sentence ends
        // and must not be joined.
        "the", "a", "an", "to", "of", "and", "but", "or", "nor", "if", "whether", "with", "for",
        "from", "into", "onto", "than", "as", "because", "my", "your", "our", "their", "his",
        "its", "every", "which", "whose", "while", "until", "unless", "although", "though",
        "since", "per", "without", "within", "very", "really", "such", "versus", "via",
        "towards", "toward", "among", "between", "during", "through", "throughout", "upon",
        "despite", "regarding", "except", "besides", "i'm", "you're", "we're", "they're",
        "he's", "she's", "it's", "that's", "there's", "i've", "we've", "you've", "i'll", "we'll",
        "you'll", "i'd", "we'd", "you'd", "gonna", "wanna", "kind", "sort", "pretty", "quite",
    ]

    /// Very short sentences that are fine standing alone.
    private static let interjections: Set<String> = [
        "yes", "no", "okay", "ok", "fine", "go", "thanks", "thank you", "sure", "exactly", "right",
        "done", "great", "good", "perfect", "correct", "wrong", "stop", "wait", "please", "sorry",
        "hello", "hi", "hey", "bye", "goodbye", "cool", "nice", "wow", "alright", "all right",
        "yeah", "yep", "nope", "absolutely", "definitely", "maybe", "never", "always", "agreed",
        "seriously", "whatever", "unbelievable", "obviously", "clearly", "interesting", "weird",
        "amazing", "awesome", "terrible", "unacceptable", "enough", "next", "continue", "proceed",
        "cancel", "undo", "retry", "again", "why", "what", "how", "really", "true", "false",
        "impossible", "possibly", "probably", "certainly", "indeed", "period", "finally",
        "understood", "noted", "got it", "no way", "of course", "not really", "that's it",
        "that's all", "let's go", "go ahead", "well done", "good job", "same here", "me too",
    ]

    private static let noSentenceStart: Set<String> = ["or", "nor"]

    private static let sentenceEnd = try! NSRegularExpression(pattern: #"(?<=[.!?§])\s+(?=\S)"#)
    private static let coreTrim = try! NSRegularExpression(pattern: #"^[^\w']+|[^\w']+$"#)

    static func apply(_ text: String) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        let paragraphs = text.components(separatedBy: "\n").map(applyParagraph)
        // Any inferred break still standing has earned its period.
        return paragraphs.joined(separator: "\n")
            .replacingOccurrences(of: String(inferredBreak), with: ".")
    }

    private static func applyParagraph(_ text: String) -> String {
        let sentences = splitSentences(text)
        guard sentences.count >= 2 else { return text }

        var joined = 0
        var result: [String] = [sentences[0]]
        for i in 1..<sentences.count {
            let prev = result[result.count - 1]
            let cur = sentences[i]

            // Inferred break right after a connective: move the break in
            // front of it, provided what is left still ends like a sentence.
            if prev.last == inferredBreak {
                let connective = lastWord(prev)
                if leadsNextSentence.contains(connective.lowercased()) {
                    var head = trimEnd(String(prev.dropLast()))
                    if head.lowercased().hasSuffix(connective.lowercased()) {
                        head = trimEnd(String(head.dropLast(connective.count)))
                        let headLast = lastWord(head).lowercased()
                        if wordCount(head) >= strictMinWords, !headLast.isEmpty,
                           !strictNonTerminal.contains(headLast), !nonTerminal.contains(headLast) {
                            result[result.count - 1] = head + "."
                            result.append(capitalize(connective) + " " + lower(cur))
                            joined += 1
                            continue
                        }
                    }
                }
            }

            if joinReason(prev, cur) == nil {
                result.append(cur)
                continue
            }
            joined += 1
            result[result.count - 1] = join(prev, cur)
        }
        if joined > 0 { Log.info("Punctuation sanity: \(joined) false sentence break(s) removed") }
        return result.joined(separator: " ")
    }

    private static func joinReason(_ prev: String, _ cur: String) -> String? {
        guard let prevEnd = prev.last else { return nil }
        if prevEnd == "?" || prevEnd == "!" { return nil } // questions and exclamations are deliberate
        let prevLast = lastWord(prev).lowercased()
        let curFirst = firstWord(cur).lowercased()
        let curWords = wordCount(cur)

        if nonTerminal.contains(prevLast) { return "ends on non-terminal word" }
        if noSentenceStart.contains(curFirst) { return "starts with conjunction" }
        if prevEnd == inferredBreak {
            // Inferred, not heard: must look like a sentence end on its own merits.
            if strictNonTerminal.contains(prevLast) { return "inferred break after connective/verb" }
            if wordCount(prev) < strictMinWords { return "inferred break after too few words" }
        }
        // A lone word is a fragment ("Afterwards.") unless it is a real
        // one-word sentence. Two-word sentences ("Do this.", "I can't.") are
        // left alone. A fragment ending on a continuation word ("Like the.")
        // belongs to the sentence AFTER it; the non-terminal rule joins it
        // forward on the next step, so do not pull it backward here.
        if curWords == 1, let curEnd = cur.last, curEnd == "." || curEnd == inferredBreak,
           !interjections.contains(core(cur).lowercased()), !nonTerminal.contains(curFirst) {
            return "fragment"
        }
        return nil
    }

    private static func join(_ prev: String, _ cur: String) -> String {
        // Drop the false terminal punctuation on prev.
        let head = trimEnd(String(trimEnd(prev).dropLast()))
        return head + " " + lower(cur)
    }

    /// The word after a false break is not a sentence start; lower-case it
    /// unless it is the pronoun I or an all-caps token (acronym).
    private static func lower(_ s: String) -> String {
        guard let firstLetter = s.firstIndex(where: { $0.isLetter }) else { return s }
        let w = firstWord(s)
        let keep = w == "I" || w.hasPrefix("I'") || (w.count > 1 && w.uppercased() == w)
        if keep { return s }
        var chars = Array(s)
        let idx = s.distance(from: s.startIndex, to: firstLetter)
        chars[idx] = Character(String(chars[idx]).lowercased())
        return String(chars)
    }

    private static func capitalize(_ w: String) -> String {
        guard let first = w.first else { return w }
        return String(first).uppercased() + w.dropFirst()
    }

    // MARK: - Word helpers (shared with RunOnSplitter)

    static func core(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        return coreTrim.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
    }

    static func lastWord(_ s: String) -> String {
        let t = core(s)
        guard let i = t.lastIndex(of: " ") else { return t }
        return String(t[t.index(after: i)...])
    }

    static func firstWord(_ s: String) -> String {
        let t = core(s)
        guard let i = t.firstIndex(of: " ") else { return t }
        return String(t[..<i])
    }

    static func wordCount(_ s: String) -> Int {
        core(s).split(separator: " ", omittingEmptySubsequences: true).count
    }

    static func trimEnd(_ s: String) -> String {
        var t = s
        while let last = t.last, last.isWhitespace { t.removeLast() }
        return t
    }

    private static func splitSentences(_ text: String) -> [String] {
        let ns = text as NSString
        var pieces: [String] = []
        var cursor = 0
        for match in sentenceEnd.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            pieces.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            cursor = match.range.location + match.range.length
        }
        pieces.append(ns.substring(from: cursor))
        return pieces
    }
}
