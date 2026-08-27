using System;
using System.Collections.Generic;
using System.Text;
using System.Text.RegularExpressions;

namespace VoxFlow;

/// <summary>
/// Last line of defence against the giant run-on: when whisper has produced a
/// long stretch with no sentence end at all (fast, breathless speech gives it
/// neither pauses nor prosody to go on), split at the words spoken English
/// starts sentences with. Only stretches of <see cref="MinRunOnWords"/>+
/// words are touched, so normally punctuated text passes through unchanged,
/// and every rule is guarded against its common false positive.
/// </summary>
public static class RunOnSplitter
{
    private const int MinRunOnWords = 20;
    private const int MinWordsBetweenBreaks = 4;

    // "…because I…", "…that I…", "…what I…": not a sentence boundary.
    private static readonly HashSet<string> NoBreakBeforeI = new(StringComparer.OrdinalIgnoreCase)
    {
        "and", "but", "so", "that", "because", "if", "when", "what", "why", "which", "then",
        "or", "as", "than", "like", "think", "thought", "said", "say", "know", "knew", "mean",
        "guess", "hope", "wish", "sure", "since", "while", "where", "how", "whether", "until",
        "unless", "although", "though", "before", "after", "once", "now", "everything", "all",
        "something", "anything", "nothing", "thing", "things", "time", "way", "do", "did",
        "does", "can", "could", "should", "would", "will", "am", "is", "are", "was", "were",
        "have", "has", "had", "not", "maybe", "where", "whatever", "whenever", "here", "there",
        "so", "yes", "no", "to", "of", "for", "with", "on", "in", "at", "by", "from", "about",
    };

    // "it's so slow", "so many": "so" as an intensifier, not a connective.
    private static readonly HashSet<string> NoBreakBeforeSo = new(StringComparer.OrdinalIgnoreCase)
    {
        "is", "was", "are", "were", "be", "been", "being", "it's", "its", "that's", "he's", "she's",
        "not", "and", "or", "but", "feel", "feels", "felt", "look", "looks", "seem", "seems",
        "too", "very", "really", "just", "only", "even", "get", "gets", "got", "become", "became",
        "made", "make", "makes", "much", "am", "i'm", "you're", "they're", "we're", "ever", "if",
    };
    private static readonly HashSet<string> NoBreakAfterSo = new(StringComparer.OrdinalIgnoreCase)
    {
        "many", "much", "that", "far", "long", "good", "bad", "on", "forth", "be", "is", "as",
        "to", "what", "it", "do", "does", "did", "can", "could", "would", "should", "are", "am",
        "was", "were", "little", "few", "often", "slow", "fast", "hard", "easy", "well", "close",
    };

    // "I know why…", "no matter what…": the question word is not opening a question.
    private static readonly HashSet<string> NoBreakBeforeQuestion = new(StringComparer.OrdinalIgnoreCase)
    {
        "know", "knows", "knew", "understand", "understands", "wonder", "wondering", "see",
        "that's", "is", "was", "and", "or", "but", "of", "me", "you", "us", "them", "tell",
        "told", "ask", "asked", "sure", "about", "on", "matter", "no", "exactly", "guess",
        "explain", "figure", "out", "idea", "care", "care", "remember", "forget", "decide",
        "show", "showed", "learn", "learned", "clear", "obvious", "question", "reason", "is",
        "for", "to", "at", "in", "with", "not", "so", "like", "just", "of", "the", "this", "that",
    };

    private static readonly HashSet<string> Openers = new(StringComparer.OrdinalIgnoreCase)
    {
        "also", "anyway", "anyways", "honestly", "basically", "again", "secondly", "thirdly",
        "additionally", "furthermore", "however", "therefore", "otherwise", "meanwhile",
    };
    private static readonly HashSet<string> NoBreakBeforeOpener = new(StringComparer.OrdinalIgnoreCase)
    {
        "and", "but", "or", "is", "was", "it's", "that's", "so", "then", "quite", "very", "not",
        "do", "did", "does", "can", "will", "would", "should", "could", "to", "of", "once", "over",
    };

    private static readonly HashSet<string> QuestionWords = new(StringComparer.OrdinalIgnoreCase)
    {
        "why", "what", "how", "where", "when", "who",
    };

    public static string Split(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return text;
        // Work paragraph by paragraph so explicit "new paragraph" breaks survive.
        var paragraphs = text.Split('\n');
        for (int p = 0; p < paragraphs.Length; p++)
            paragraphs[p] = SplitParagraph(paragraphs[p]);
        return string.Join("\n", paragraphs);
    }

    private static string SplitParagraph(string text)
    {
        var words = text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (words.Length < MinRunOnWords) return text;

        // Only stretches with no sentence end for MinRunOnWords+ words are eligible.
        var sb = new StringBuilder(text.Length + 16);
        int sinceBreak = 0;      // words since the last sentence end (real or inserted)
        int inserted = 0;
        for (int i = 0; i < words.Length; i++)
        {
            string w = words[i];
            if (i > 0)
            {
                bool runOn = RunOnAhead(words, i, sinceBreak);
                if (runOn && sinceBreak >= MinWordsBetweenBreaks && IsSentenceStart(words, i))
                {
                    sb.Append('.');
                    sinceBreak = 0;
                    inserted++;
                }
                sb.Append(' ');
            }
            sb.Append(w);
            if (EndsSentence(w)) sinceBreak = 0; else sinceBreak++;
        }
        if (inserted > 0) Log.Info($"Run-on split: {inserted} sentence break(s) inserted");
        return sb.ToString();
    }

    /// <summary>
    /// True when the current position sits inside a stretch of at least
    /// MinRunOnWords words with no sentence end — looking back at what has been
    /// emitted and forward through the original text.
    /// </summary>
    private static bool RunOnAhead(string[] words, int i, int sinceBreak)
    {
        int ahead = 0;
        for (int j = i; j < words.Length && !EndsSentence(words[j]); j++) ahead++;
        return sinceBreak + ahead >= MinRunOnWords;
    }

    private static bool EndsSentence(string w) =>
        w.Length > 0 && (w[^1] is '.' or '!' or '?' || (w.Length > 1 && w[^1] is '"' or '\'' && w[^2] is '.' or '!' or '?'));

    private static bool IsSentenceStart(string[] words, int i)
    {
        string w = Core(words[i]);
        string prev = Core(words[i - 1]);
        if (prev.Length == 0 || words[i - 1][^1] == ',') return false; // never after a comma

        if (w == "I" || (w.StartsWith("I'", StringComparison.Ordinal) && w.Length <= 4))
            return !NoBreakBeforeI.Contains(prev);

        if (string.Equals(w, "so", StringComparison.OrdinalIgnoreCase))
        {
            if (NoBreakBeforeSo.Contains(prev)) return false;
            if (i + 1 >= words.Length) return false;
            string next = Core(words[i + 1]);
            return !NoBreakAfterSo.Contains(next) && i + 3 < words.Length; // "so" must open a clause
        }

        if (QuestionWords.Contains(w))
        {
            if (NoBreakBeforeQuestion.Contains(prev)) return false;
            if (i + 1 >= words.Length) return false;
            string next = Core(words[i + 1]);
            // A question opener is followed by an auxiliary/verb: "why do", "what is", "how can".
            return next.ToLowerInvariant() is "do" or "does" or "did" or "is" or "are" or "was" or "were"
                or "can" or "could" or "would" or "should" or "will" or "have" or "has" or "had"
                or "am" or "don't" or "doesn't" or "didn't" or "isn't" or "aren't" or "can't"
                or "couldn't" or "wouldn't" or "shouldn't" or "won't" or "the" or "about";
        }

        if (Openers.Contains(w))
            return !NoBreakBeforeOpener.Contains(prev);

        return false;
    }

    private static string Core(string w) => Regex.Replace(w, @"^[^\w']+|[^\w']+$", "");
}
