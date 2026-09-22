import Foundation

/// Last line of defence against the giant run-on: when whisper has produced a
/// long stretch with no sentence end at all (fast, breathless speech gives it
/// neither pauses nor prosody to go on), split at the words spoken English
/// starts sentences with. Only stretches of `minRunOnWords`+ words are
/// touched, so normally punctuated text passes through unchanged, and every
/// rule is guarded against its common false positive.
///
/// Breaks are written as `PunctuationSanity.inferredBreak`, never as periods:
/// the sanity pass decides which survive. Same rules as the Windows build's
/// `RunOnSplitter.cs`; keep the two in step when tuning.
enum RunOnSplitter {
    private static let minRunOnWords = 20
    private static let minWordsBetweenBreaks = 4

    // "…because I…", "…that I…", "…what I…": not a sentence boundary.
    private static let noBreakBeforeI: Set<String> = [
        "and", "but", "so", "that", "because", "if", "when", "what", "why", "which", "then",
        "or", "as", "than", "like", "think", "thought", "said", "say", "know", "knew", "mean",
        "guess", "hope", "wish", "sure", "since", "while", "where", "how", "whether", "until",
        "unless", "although", "though", "before", "after", "once", "now", "everything", "all",
        "something", "anything", "nothing", "thing", "things", "time", "way", "do", "did",
        "does", "can", "could", "should", "would", "will", "am", "is", "are", "was", "were",
        "have", "has", "had", "not", "maybe", "whatever", "whenever", "here", "there",
        "yes", "no", "to", "of", "for", "with", "on", "in", "at", "by", "from", "about",
    ]

    // "it's so slow", "so many": "so" as an intensifier, not a connective.
    private static let noBreakBeforeSo: Set<String> = [
        "is", "was", "are", "were", "be", "been", "being", "it's", "its", "that's", "he's", "she's",
        "not", "and", "or", "but", "feel", "feels", "felt", "look", "looks", "seem", "seems",
        "too", "very", "really", "just", "only", "even", "get", "gets", "got", "become", "became",
        "made", "make", "makes", "much", "am", "i'm", "you're", "they're", "we're", "ever", "if",
    ]
    private static let noBreakAfterSo: Set<String> = [
        "many", "much", "that", "far", "long", "good", "bad", "on", "forth", "be", "is", "as",
        "to", "what", "it", "do", "does", "did", "can", "could", "would", "should", "are", "am",
        "was", "were", "little", "few", "often", "slow", "fast", "hard", "easy", "well", "close",
    ]

    // "I know why…", "no matter what…": the question word is not opening a question.
    private static let noBreakBeforeQuestion: Set<String> = [
        "know", "knows", "knew", "understand", "understands", "wonder", "wondering", "see",
        "that's", "is", "was", "and", "or", "but", "of", "me", "you", "us", "them", "tell",
        "told", "ask", "asked", "sure", "about", "on", "matter", "no", "exactly", "guess",
        "explain", "figure", "out", "idea", "care", "remember", "forget", "decide",
        "show", "showed", "learn", "learned", "clear", "obvious", "question", "reason",
        "for", "to", "at", "in", "with", "not", "so", "like", "just", "the", "this", "that",
    ]

    private static let openers: Set<String> = [
        "also", "anyway", "anyways", "honestly", "secondly", "thirdly",
        "additionally", "furthermore", "however", "therefore", "otherwise", "meanwhile",
    ]
    // "I also think", "which also means", "it's honestly fine": mid-sentence.
    private static let noBreakBeforeOpener: Set<String> = [
        "and", "but", "or", "is", "was", "are", "were", "am", "be", "been", "being", "it's",
        "that's", "so", "then", "quite", "very", "not", "do", "did", "does", "can", "will",
        "would", "should", "could", "may", "might", "must", "has", "have", "had", "to", "of",
        "once", "over", "i", "you", "we", "they", "he", "she", "it", "that", "this", "which",
        "who", "there", "here", "what", "i'm", "you're", "we're", "they're", "i've", "we've",
        "i'll", "we'll", "i'd", "we'd", "he's", "she's", "there's",
    ]

    private static let questionWords: Set<String> = ["why", "what", "how", "where", "when", "who"]

    // A question opener is followed by an auxiliary/verb: "why do", "what is", "how can".
    private static let questionFollowers: Set<String> = [
        "do", "does", "did", "is", "are", "was", "were", "can", "could", "would", "should", "will",
        "have", "has", "had", "am", "don't", "doesn't", "didn't", "isn't", "aren't", "can't",
        "couldn't", "wouldn't", "shouldn't", "won't", "the", "about",
    ]

    static func split(_ text: String) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        // Work paragraph by paragraph so explicit "new paragraph" breaks survive.
        return text.components(separatedBy: "\n").map(splitParagraph).joined(separator: "\n")
    }

    private static func splitParagraph(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count >= minRunOnWords else { return text }

        // Only stretches with no sentence end for minRunOnWords+ words are eligible.
        var out = ""
        out.reserveCapacity(text.count + 16)
        var sinceBreak = 0      // words since the last sentence end (real or inserted)
        var inserted = 0
        for i in 0..<words.count {
            let w = words[i]
            if i > 0 {
                let runOn = runOnAhead(words, i, sinceBreak)
                if runOn, sinceBreak >= minWordsBetweenBreaks, isSentenceStart(words, i) {
                    out.append(PunctuationSanity.inferredBreak) // provisional; sanity pass confirms
                    sinceBreak = 0
                    inserted += 1
                }
                out.append(" ")
            }
            out.append(w)
            if endsSentence(w) { sinceBreak = 0 } else { sinceBreak += 1 }
        }
        if inserted > 0 { Log.info("Run-on split: \(inserted) sentence break(s) inserted") }
        return out
    }

    /// True when the current position sits inside a stretch of at least
    /// minRunOnWords words with no sentence end — looking back at what has
    /// been emitted and forward through the original text.
    private static func runOnAhead(_ words: [String], _ i: Int, _ sinceBreak: Int) -> Bool {
        var ahead = 0
        var j = i
        while j < words.count, !endsSentence(words[j]) { ahead += 1; j += 1 }
        return sinceBreak + ahead >= minRunOnWords
    }

    private static func endsSentence(_ w: String) -> Bool {
        let chars = Array(w)
        guard let last = chars.last else { return false }
        if last == "." || last == "!" || last == "?" || last == PunctuationSanity.inferredBreak { return true }
        if chars.count > 1, last == "\"" || last == "'" {
            let before = chars[chars.count - 2]
            return before == "." || before == "!" || before == "?"
        }
        return false
    }

    private static let purposePronouns: Set<String> = [
        "i", "we", "you", "they", "he", "she", "it", "people", "users", "players",
    ]
    private static let purposeModals: Set<String> = [
        "can", "could", "would", "will", "won't", "don't", "doesn't", "didn't", "can't", "couldn't",
        "wouldn't", "may", "might", "have", "has", "get", "gets", "know", "knows", "see", "sees",
    ]

    private static func isSentenceStart(_ words: [String], _ i: Int) -> Bool {
        let w = PunctuationSanity.core(words[i])
        let prev = PunctuationSanity.core(words[i - 1]).lowercased()
        if prev.isEmpty || words[i - 1].last == "," { return false } // never after a comma

        if w == "I" || (w.hasPrefix("I'") && w.count <= 4) {
            return !noBreakBeforeI.contains(prev)
        }

        let lw = w.lowercased()
        if lw == "so" {
            if noBreakBeforeSo.contains(prev) { return false }
            if i + 1 >= words.count { return false }
            let next = PunctuationSanity.core(words[i + 1]).lowercased()
            if noBreakAfterSo.contains(next) || i + 3 >= words.count { return false } // "so" must open a clause
            // "…as quickly as possible so they can file it": a purpose clause
            // (so + pronoun + modal), not a new sentence.
            if purposePronouns.contains(next),
               purposeModals.contains(PunctuationSanity.core(words[i + 2]).lowercased()) {
                return false
            }
            return true
        }

        if questionWords.contains(lw) {
            if noBreakBeforeQuestion.contains(prev) { return false }
            if i + 1 >= words.count { return false }
            let next = PunctuationSanity.core(words[i + 1]).lowercased()
            return questionFollowers.contains(next)
        }

        if openers.contains(lw) {
            return !noBreakBeforeOpener.contains(prev)
        }

        return false
    }
}
